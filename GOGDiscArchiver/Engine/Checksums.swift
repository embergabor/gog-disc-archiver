import CryptoKit
import Foundation

enum Checksums {
    /// SHA-256 of a file, read in 4 MB chunks. `progress` gets the bytes read since the last call.
    static func sha256(of url: URL, progress: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 4 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            progress(Int64(chunk.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `sha256sum` / `shasum -a 256 -c` format: "<hash>  <path>" per line, paths relative to the disc root.
    static func render(_ files: [FileRecord]) -> String {
        files.map { "\($0.sha256)  \($0.path)" }.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 64 else { continue }
            var path = String(parts[1])
            if path.hasPrefix(" ") || path.hasPrefix("*") { path.removeFirst() }
            result[path] = String(parts[0])
        }
        return result
    }
}
