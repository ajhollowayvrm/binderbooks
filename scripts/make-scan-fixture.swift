// Builds the fixture that `ScanAccuracyBenchmark` measures the scanner against.
//
//     cd <a working directory>
//     sqlite3 -noheader -tabs scripts/catalog.sqlite "<the sample query, see the README>" > sample.tsv
//     mkdir cards && <download each product's _in_1000x1000.jpg into cards/<productId>.jpg>
//     swiftc -O scripts/make-scan-fixture.swift -o makefixture && ./makefixture
//
// Runs on the Mac, never on the phone and never in the simulator: a feature
// print needs the neural engine, which the simulator does not have. What it
// writes is the *output of the camera* — the text Vision read off a degraded
// look at each card, and the signature of that same look — so the benchmark
// can run the real matcher on real readings inside the simulator, where the
// catalog and GRDB live.

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision
import AppKit

let ciContext = CIContext(options: [.useSoftwareRenderer: false])

struct SplitMix64 { var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
let dimensions = 128, sourceDimensions = 768
let matrix: [Float] = {
    var rng = SplitMix64(state: 0x8AC7_2304_89E8_0000)
    var v = [Float](repeating: 0, count: sourceDimensions * dimensions)
    let scale = 1 / Float(dimensions).squareRoot()
    for i in v.indices { v[i] = (rng.next() & 1) == 0 ? scale : -scale }
    return v
}()
func project(_ v: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: dimensions)
    matrix.withUnsafeBufferPointer { m in
        for j in 0..<dimensions {
            var sum: Float = 0
            for i in 0..<sourceDimensions { sum += v[i] * m[i * dimensions + j] }
            out[j] = sum
        }
    }
    return out
}
func quantise(_ v: [Float]) -> [Int8] {
    var norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    if norm == 0 { norm = 1 }
    return v.map { Int8(max(-127, min(127, ($0 / norm * 127).rounded()))) }
}
func featurePrint(of image: CGImage) -> [Float]? {
    let r = VNGenerateImageFeaturePrintRequest()
    r.revision = VNGenerateImageFeaturePrintRequestRevision2
    guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([r])) != nil,
          let p = r.results?.first as? VNFeaturePrintObservation,
          p.elementCount == sourceDimensions, p.elementType == .float else { return nil }
    return p.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func load(_ p: String) -> CGImage? {
    guard let d = NSData(contentsOfFile: p), let s = CGImageSourceCreateWithData(d, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}
func resized(_ image: CGImage, height: CGFloat) -> CGImage {
    let scale = height / CGFloat(image.height)
    let w = max(1, Int((CGFloat(image.width) * scale).rounded())), h = max(1, Int(height.rounded()))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}
func degraded(_ card: CGImage, height: CGFloat, blur: CGFloat, dim: CGFloat) -> CGImage {
    var image = CIImage(cgImage: resized(card, height: height))
    if blur > 0 {
        let f = CIFilter(name: "CIGaussianBlur")!
        f.setValue(image, forKey: kCIInputImageKey); f.setValue(blur, forKey: "inputRadius")
        image = f.outputImage!.cropped(to: image.extent)
    }
    if dim != 0 {
        let f = CIFilter(name: "CIColorControls")!
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(dim, forKey: "inputBrightness")
        f.setValue(1.0 + Double(dim), forKey: "inputContrast")
        image = f.outputImage!.cropped(to: image.extent)
    }
    return ciContext.createCGImage(image, from: image.extent)!
}
struct Item: Codable { var transcript: String; var top: Double; var height: Double }
struct Row: Codable { var productId: Int; var condition: String; var items: [Item]; var art: [Int8] }

func readText(_ image: CGImage) -> [Item] {
    let r = VNRecognizeTextRequest()
    r.recognitionLevel = .accurate
    r.recognitionLanguages = ["en"]
    r.usesLanguageCorrection = true
    r.customWords = []
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([r])
    return (r.results ?? []).compactMap { o in
        guard let c = o.topCandidates(1).first else { return nil }
        return Item(transcript: c.string, top: 1 - o.boundingBox.maxY, height: o.boundingBox.height)
    }
}

let scratch = FileManager.default.currentDirectoryPath
let lines = try! String(contentsOfFile: "sample.tsv", encoding: .utf8).split(separator: "\n")
var rows: [Row] = []
let conditions: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("good", 1300, 1, 0),
    ("chute", 900, 2, -0.15),
]
for (n, line) in lines.enumerated() {
    let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
    let id = Int(parts[0])!
    guard let card = load("cards/\(id).jpg") else { continue }
    for (label, height, blur, dim) in conditions {
        let look = degraded(card, height: height, blur: blur, dim: dim)
        let items = readText(look)
        guard let raw = featurePrint(of: resized(look, height: 627)) else { continue }
        rows.append(Row(productId: id, condition: label, items: items, art: quantise(project(raw))))
    }
    if n % 25 == 0 { FileHandle.standardError.write("\(n)\n".data(using: .utf8)!) }
}
let data = try! JSONEncoder().encode(rows)
try! data.write(to: URL(fileURLWithPath: "\(scratch)/scanfixture.json"))
print("wrote \(rows.count) rows")
