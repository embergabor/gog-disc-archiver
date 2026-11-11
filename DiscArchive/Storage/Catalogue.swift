import Foundation

/// Where the app keeps its own data. Default `~/Archive`, override with `-archiveRoot <path>`.
struct AppPaths: Sendable {
    var root: URL

    var catalogue: URL { root.appendingPathComponent("discs.json") }
    /// Per-disc checksums and recovery data, kept so a second copy can be burned identically.
    var sets: URL { root.appendingPathComponent("Sets", isDirectory: true) }

    func set(for id: String) -> URL { sets.appendingPathComponent(id, isDirectory: true) }

    static func fromDefaults() -> AppPaths {
        if let custom = UserDefaults.standard.string(forKey: "archiveRoot"), !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return AppPaths(root: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AppPaths(root: home.appendingPathComponent("Archive", isDirectory: true))
    }
}

/// Reads and writes `discs.json`. Writes are atomic so a crash never leaves half a catalogue.
struct CatalogueStore: Sendable {
    var url: URL

    func load() throws -> [DiscRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(CatalogueFile.self, from: data).discs
    }

    func save(_ discs: [DiscRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sorted = discs.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let data = try Self.encoder.encode(CatalogueFile(discs: sorted))
        try data.write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

enum DiscID {
    /// "GOG-014" → ("GOG", 14). Returns nil for IDs that don't end in a number.
    static func split(_ id: String) -> (prefix: String, number: Int)? {
        guard let dash = id.lastIndex(of: "-") else { return nil }
        let prefix = String(id[..<dash])
        guard let number = Int(id[id.index(after: dash)...]), !prefix.isEmpty else { return nil }
        return (prefix, number)
    }

    /// The next free ID with this prefix, three digits: GOG-015 after GOG-014.
    static func next(after existing: [String], prefix: String = "GOG") -> String {
        let used = existing.compactMap(split).filter { $0.prefix == prefix }.map(\.number)
        let n = (used.max() ?? 0) + 1
        return prefix + "-" + String(format: "%03d", n)
    }

    /// Volume name on the disc: GOG-014 → GOG_014 (letters, digits and underscores only).
    static func volumeName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped).uppercased()
    }
}
