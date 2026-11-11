import Foundation

/// One file inside a game folder, path relative to that folder.
struct SourceFile: Hashable, Codable, Sendable {
    var relativePath: String
    var size: Int64
}

/// A folder the user dropped in: one game's installers and extras.
struct GameFolder: Identifiable, Hashable, Sendable {
    var id: URL { url }
    var url: URL
    var files: [SourceFile]

    /// Name on the disc and in the catalogue: the folder's own name.
    var name: String { url.lastPathComponent }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Windows / Mac / Linux, guessed from installer file types.
    var platforms: [String] { GameFolder.platforms(for: files.map(\.relativePath)) }

    static func platforms(for paths: [String]) -> [String] {
        var found: [String] = []
        let lower = paths.map { $0.lowercased() }
        if lower.contains(where: { $0.hasSuffix(".exe") }) { found.append("Windows") }
        if lower.contains(where: { $0.hasSuffix(".pkg") || $0.hasSuffix(".dmg") }) { found.append("Mac") }
        if lower.contains(where: { $0.hasSuffix(".sh") }) { found.append("Linux") }
        return found
    }

    enum ScanError: LocalizedError {
        case notAFolder(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .notAFolder(let name): "\(name) is not a folder."
            case .empty(let name): "\(name) has no files in it."
            }
        }
    }

    /// Lists every regular file under `url`, skipping hidden files and symbolic links.
    static func scan(_ url: URL) throws -> GameFolder {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScanError.notAFolder(url.lastPathComponent)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw ScanError.notAFolder(url.lastPathComponent)
        }
        let basePath = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var files: [SourceFile] = []
        for case let item as URL in walker {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(basePath) else { continue }
            let rel = String(path.dropFirst(basePath.count))
            let size = Int64(values.fileSize ?? values.totalFileSize ?? 0)
            files.append(SourceFile(relativePath: rel, size: size))
        }
        guard !files.isEmpty else { throw ScanError.empty(url.lastPathComponent) }
        files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return GameFolder(url: url, files: files)
    }
}
