// Measures how well the artwork signatures actually identify a card.
//
// The signatures are built from TCGplayer's flat scans. The phone compares a
// photograph taken across a desk under a lamp. This job asks whether that
// survives: it takes each reference, beats it up until it looks like a photo —
// perspective, glare, a warm bulb, camera blur, JPEG — signs the result, and
// checks which card in the whole index comes back nearest.
//
// It is a floor, not a promise. A degraded scan is still kinder than a real
// photograph of a sleeved card, so treat a poor number here as fatal and a good
// number here as permission to test on the phone.
//
//   swiftc -O catalog/eval_descriptors.swift ios/Sources/Scan/CardArtDescriptor.swift \
//     ios/Sources/Scan/CardRectifier.swift -o /tmp/eval-descriptors
//   /tmp/eval-descriptors --catalog scripts/catalog.sqlite --sample 150

import CoreImage
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

struct Options {
    var catalog = "scripts/catalog.sqlite"
    var sample = 150
    var groupId: Int?
    var seed: UInt64 = 20_260_911
    /// How hard to beat the reference up. Each level adds one transform, so a
    /// sweep says which one costs the accuracy rather than only that it went.
    var degrade = Degrade.all
}

enum Degrade: String, CaseIterable {
    case none, jpeg, perspective, colour, glare, blur, all

    var level: Int { Degrade.allCases.firstIndex(of: self)! }
    func includes(_ step: Degrade) -> Bool { self == .all || level >= step.level }
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let flag = arguments.first {
        arguments.removeFirst()
        func value() -> String {
            guard let next = arguments.first else { exit(2) }
            arguments.removeFirst()
            return next
        }
        switch flag {
        case "--catalog": options.catalog = value()
        case "--sample": options.sample = Int(value()) ?? 150
        case "--group": options.groupId = Int(value())
        case "--seed": options.seed = UInt64(value()) ?? 1
        case "--degrade": options.degrade = Degrade(rawValue: value()) ?? .all
        default: FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8)); exit(2)
        }
    }
    return options
}

// MARK: - The index

struct Entry {
    var productId: Int
    var name: String
    var groupId: Int
    var numberNum: Int
    var imageUrl: String
    var descriptor: [Int8]
}

func loadIndex(_ path: String) -> [Entry] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        FileHandle.standardError.write(Data("cannot open \(path)\n".utf8))
        exit(1)
    }
    defer { sqlite3_close(handle) }

    let sql = """
    SELECT p.productId, p.name, p.groupId, COALESCE(p.numberNum, -1), p.imageUrl, a.descriptor
    FROM productArt a JOIN product p ON p.productId = a.productId
    """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { exit(1) }
    defer { sqlite3_finalize(statement) }

    var entries: [Entry] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let blob = sqlite3_column_blob(statement, 5) else { continue }
        let count = Int(sqlite3_column_bytes(statement, 5))
        let data = Data(bytes: blob, count: count)
        guard let descriptor = CardArtDescriptor.descriptor(from: data) else { continue }
        entries.append(Entry(
            productId: Int(sqlite3_column_int64(statement, 0)),
            name: String(cString: sqlite3_column_text(statement, 1)),
            groupId: Int(sqlite3_column_int64(statement, 2)),
            numberNum: Int(sqlite3_column_int64(statement, 3)),
            imageUrl: String(cString: sqlite3_column_text(statement, 4)),
            descriptor: descriptor
        ))
    }
    return entries
}

// MARK: - Making a reference look like a photograph

let ciContext = CIContext()

/// Perspective, a warm off-centre light, blur, and JPEG. Roughly what a phone
/// does to a card held in one hand.
func photograph(_ image: CGImage, rng: inout SplitMix64, degrade: Degrade) -> CGImage? {
    func jitter(_ amount: CGFloat) -> CGFloat {
        (CGFloat(rng.next() % 2000) / 1000 - 1) * amount
    }
    var ci = CIImage(cgImage: image)
    let extent = ci.extent
    let lean = extent.width * 0.06

    if degrade.includes(.perspective), let perspective = CIFilter(name: "CIPerspectiveTransform") {
        perspective.setValue(ci, forKey: kCIInputImageKey)
        perspective.setValue(CIVector(x: extent.minX + jitter(lean), y: extent.maxY + jitter(lean)), forKey: "inputTopLeft")
        perspective.setValue(CIVector(x: extent.maxX + jitter(lean), y: extent.maxY + jitter(lean)), forKey: "inputTopRight")
        perspective.setValue(CIVector(x: extent.minX + jitter(lean), y: extent.minY + jitter(lean)), forKey: "inputBottomLeft")
        perspective.setValue(CIVector(x: extent.maxX + jitter(lean), y: extent.minY + jitter(lean)), forKey: "inputBottomRight")
        if let leaned = perspective.outputImage { ci = leaned }
    }

    if degrade.includes(.colour), let colour = CIFilter(name: "CIColorControls") {
        colour.setValue(ci, forKey: kCIInputImageKey)
        colour.setValue(0.06 + jitter(0.07), forKey: "inputBrightness")
        colour.setValue(1.0 + jitter(0.18), forKey: "inputContrast")
        colour.setValue(0.9 + jitter(0.15), forKey: "inputSaturation")
        if let adjusted = colour.outputImage { ci = adjusted }
    }

    // A specular highlight: a bright band across part of the card, which is
    // what a lamp on a sleeve actually does. A wash over the whole card is not
    // glare, it is a colour cast, and it was costing far more than the real
    // thing ever would.
    if degrade.includes(.glare), let gradient = CIFilter(name: "CILinearGradient") {
        let band = ci.extent
        gradient.setValue(CIVector(x: band.minX, y: band.midY + band.height * 0.18), forKey: "inputPoint0")
        gradient.setValue(CIVector(x: band.maxX * 0.55, y: band.midY - band.height * 0.10), forKey: "inputPoint1")
        gradient.setValue(CIColor(red: 1, green: 1, blue: 0.95, alpha: 0.30), forKey: "inputColor0")
        gradient.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0), forKey: "inputColor1")
        if let light = gradient.outputImage?.cropped(to: ci.extent) {
            ci = light.composited(over: ci)
        }
    }

    if degrade.includes(.blur), let blur = CIFilter(name: "CIGaussianBlur") {
        blur.setValue(ci, forKey: kCIInputImageKey)
        blur.setValue(0.7, forKey: "inputRadius")
        if let blurred = blur.outputImage { ci = blurred.cropped(to: extent) }
    }

    guard let rendered = ciContext.createCGImage(ci, from: extent) else { return nil }
    guard degrade.includes(.jpeg) else { return rendered }

    // Through JPEG, the way a camera frame arrives.
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
    guard CGImageDestinationFinalize(destination),
          let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Cached on disk, because a sweep over the degradation levels asks for the
/// same hundred images once per level.
let cacheDirectory: URL = {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("card-art-eval")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}()

func fetch(_ urlString: String, productId: Int) async -> CGImage? {
    let cached = cacheDirectory.appendingPathComponent("\(productId).jpg")
    if let data = try? Data(contentsOf: cached),
       let source = CGImageSourceCreateWithData(data as CFData, nil) {
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.setValue("card-tracker-catalog-builder/1.0", forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    try? data.write(to: cached)
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: - Run

@main
struct Eval {
    static func main() async {
        let options = parseOptions()
        let index = loadIndex(options.catalog)
        guard !index.isEmpty else {
            print("no signatures in the catalog. Run build_descriptors first.")
            exit(1)
        }
        print("index holds \(index.count) signed cards")

        var rng = SplitMix64(state: options.seed)
        var pool = options.groupId.map { id in index.filter { $0.groupId == id } } ?? index
        pool.shuffle(using: &rng)
        let sample = Array(pool.prefix(options.sample))
        print("testing \(sample.count) of them as photographs, degradation: \(options.degrade.rawValue)\n")

        var top1 = 0
        var top3 = 0
        var tested = 0
        var rightCardWrongPrinting = 0
        var failures: [(Entry, Entry, Float, Float)] = []

        for entry in sample {
            guard let reference = await fetch(entry.imageUrl, productId: entry.productId) else { continue }
            var localRng = SplitMix64(state: rng.next())
            guard let photo = photograph(reference, rng: &localRng, degrade: options.degrade),
                  let raw = try? CardArtDescriptor.featurePrint(of: photo),
                  let signature = CardArtDescriptor.make(fromRaw: raw)
            else { continue }
            tested += 1

            let ranked = index
                .map { ($0, CardArtDescriptor.distance(signature, $0.descriptor)) }
                .sorted { $0.1 < $1.1 }

            if ranked[0].0.productId == entry.productId {
                top1 += 1
            } else {
                // The pattern printings share a name and a number. Landing on a
                // sibling is a different mistake from landing on another card,
                // and a far cheaper one — the review screen asks about those.
                let winner = ranked[0].0
                if winner.groupId == entry.groupId, winner.numberNum == entry.numberNum, entry.numberNum >= 0 {
                    rightCardWrongPrinting += 1
                }
                failures.append((entry, winner, ranked[0].1, ranked.first { $0.0.productId == entry.productId }?.1 ?? -1))
            }
            if ranked.prefix(3).contains(where: { $0.0.productId == entry.productId }) { top3 += 1 }
        }

        func percent(_ n: Int) -> String { String(format: "%.1f%%", Double(n) / Double(max(1, tested)) * 100) }
        print("""

        tested              \(tested)
        exact card, top 1   \(top1)  \(percent(top1))
        exact card, top 3   \(top3)  \(percent(top3))
        right card, wrong printing  \(rightCardWrongPrinting)  \(percent(rightCardWrongPrinting))
        wrong card          \(tested - top1 - rightCardWrongPrinting)  \(percent(tested - top1 - rightCardWrongPrinting))
        """)

        if !failures.isEmpty {
            print("\nthe first misses:")
            for (wanted, got, gotDistance, wantedDistance) in failures.prefix(12) {
                print(String(format: "  %-34@ -> %-34@ (%.3f vs %.3f)",
                             wanted.name as NSString, got.name as NSString, gotDistance, wantedDistance))
            }
        }
    }
}

extension Array {
    mutating func shuffle(using rng: inout SplitMix64) {
        guard count > 1 else { return }
        for i in stride(from: count - 1, to: 0, by: -1) {
            swapAt(i, Int(rng.next() % UInt64(i + 1)))
        }
    }
}
