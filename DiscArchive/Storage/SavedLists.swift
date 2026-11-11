import Foundation

/// A prepared New disc list kept to burn later: the games in their order, with titles and editions.
struct SavedList: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var savedAt: Date
    /// Set when the list was burned, so it isn't burned twice by mistake.
    var burnedAt: Date?
    var media: Media
    var speed: Int
    var games: [GameFolder]

    var totalBytes: Int64 { games.reduce(0) { $0 + $1.totalBytes } }

    var summary: String {
        "\(games.count == 1 ? "1 game" : "\(games.count) games") · \(ByteText.gb(totalBytes)) · \(media.label)"
    }
}

/// One JSON file per list in `<archive>/Lists`.
struct SavedListStore: Sendable {
    var folder: URL

    func load() -> [SavedList] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? CatalogueStore.decoder.decode(SavedList.self, from: Data(contentsOf: $0)) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func save(_ list: SavedList) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try CatalogueStore.encoder.encode(list).write(to: file(list.id), options: .atomic)
    }

    func delete(_ list: SavedList) throws {
        if FileManager.default.fileExists(atPath: file(list.id).path) {
            try FileManager.default.removeItem(at: file(list.id))
        }
    }

    private func file(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }
}
