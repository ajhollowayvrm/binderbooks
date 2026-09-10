import Foundation
import zlib

/// Streams a gzip file through zlib into a plain file. No third-party dependency.
enum Gunzip {
    static func decompress(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CatalogError.gunzip("could not create \(destination.lastPathComponent)")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var stream = z_stream()
        // 15 + 32 tells zlib to detect the gzip header on its own.
        let initStatus = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw CatalogError.gunzip("inflateInit2 returned \(initStatus)")
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 1 << 18
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        var finished = false

        while !finished {
            let chunk = input.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                throw CatalogError.gunzip("the file ended before the gzip stream did")
            }
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: Bytef.self).baseAddress
                stream.next_in = UnsafeMutablePointer(mutating: base)
                stream.avail_in = uInt(chunk.count)

                repeat {
                    try outBuffer.withUnsafeMutableBufferPointer { out in
                        stream.next_out = out.baseAddress
                        stream.avail_out = uInt(chunkSize)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        switch status {
                        case Z_OK, Z_BUF_ERROR:
                            break
                        case Z_STREAM_END:
                            finished = true
                        default:
                            let message = stream.msg.map { String(cString: $0) } ?? "zlib error \(status)"
                            throw CatalogError.gunzip(message)
                        }
                        let produced = chunkSize - Int(stream.avail_out)
                        if produced > 0, let start = out.baseAddress {
                            output.write(Data(bytes: start, count: produced))
                        }
                    }
                } while stream.avail_in > 0 && !finished
            }
        }
    }
}
