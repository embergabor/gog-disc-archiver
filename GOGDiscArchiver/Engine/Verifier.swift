import Foundation

/// Reads every file back from a disc and compares it with the checksum recorded at burn time.
enum Verifier {
    static func check(root: URL, files: [FileRecord], progress: @escaping @Sendable (Double) -> Void) throws -> CheckRecord {
        let total = max(1, files.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        var bad: [String] = []
        for file in files {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(file.path)
            let start = done
            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    bad.append(file.path)
                    done += file.size
                    continue
                }
                let hash = try Checksums.sha256(of: url) { n in
                    done += n
                    progress(Double(done) / Double(total))
                }
                if hash != file.sha256 { bad.append(file.path) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                bad.append(file.path)
            }
            done = start + file.size
            progress(Double(done) / Double(total))
        }
        return CheckRecord(date: Date(), filesTotal: files.count, bad: bad)
    }

    /// The mounted volume with this name, if any.
    static func mountedVolume(named name: String) -> URL? {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.first { url in
            (try? url.resourceValues(forKeys: Set(keys)).volumeName) == name
        }
    }
}
