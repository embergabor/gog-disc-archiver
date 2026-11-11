import Foundation

/// One disc the planner lays out: a group of whole games, or one part of a game too big for one disc.
struct PlannedDisc: Codable, Hashable, Identifiable, Sendable {
    /// Catalogue key: "GOG-015", or "GOG-014-2of5" for a set disc.
    var id: String
    var setID: String?
    var part: Int?
    var partCount: Int?
    /// The games on this disc. For a set disc: the one game, with only this disc's files.
    var games: [GameFolder]

    var label: String { DiscID.label(id: id, setID: setID, part: part, partCount: partCount) }
    var volumeName: String { DiscID.volumeName(for: setID ?? id) + (part.map { "_\($0)" } ?? "") }
    var dataBytes: Int64 { games.reduce(0) { $0 + $1.totalBytes } }
    var fileCount: Int { games.reduce(0) { $0 + $1.files.count } }
    var isSetDisc: Bool { setID != nil }

    var summary: String {
        if let part, let partCount, let game = games.first {
            return "\(game.title) · part \(part) of \(partCount) · \(ByteText.files(game.files.count)) · this game only"
        }
        return games.map(\.title).joined(separator: " · ")
    }
}

/// Splits the chosen games over as many discs as needed.
///
/// Rules (agreed with the user):
/// - Files are never cut in half.
/// - Games that fit on one disc are kept whole and packed together, largest first.
/// - A game too big for one disc gets discs of its own under one ID (1/5 … 5/5). Those discs hold
///   only that game, and its last disc is not topped up with other games.
/// - Every disc gets its own checksums and recovery data, so it can be checked and repaired alone.
enum DiscPlanner {
    enum PlanError: Error, Equatable {
        case noGames
        case badID
        case fileTooBig(game: String, file: String)

        var message: String {
            switch self {
            case .noGames: "Add game folders first."
            case .badID: "Use an ID like GOG-014."
            case let .fileTooBig(game, file): "\(file) in \(game) is bigger than a whole disc. Pick a bigger disc."
            }
        }
    }

    /// par2 adds about the chosen percentage, plus a little for its index files.
    static func recoveryBytes(_ data: Int64, games: Int, percent: Int) -> Int64 {
        guard percent > 0, data > 0 else { return 0 }
        return data * Int64(percent) / 100 + data / 2000 + Int64(games) * 2_000_000
    }

    static func usedBytes(_ data: Int64, games: Int, percent: Int) -> Int64 {
        data + recoveryBytes(data, games: games, percent: percent)
    }

    /// `percent` is the recovery data actually made (0 when par2 is missing).
    static func plan(games: [GameFolder], media: Media, percent: Int, firstID: String) throws -> [PlannedDisc] {
        guard !games.isEmpty else { throw PlanError.noGames }
        guard DiscID.split(firstID) != nil else { throw PlanError.badID }
        let limit = media.usable
        func fits(_ data: Int64, games n: Int) -> Bool { usedBytes(data, games: n, percent: percent) <= limit }

        for game in games {
            if let file = game.files.first(where: { !fits($0.size, games: 1) }) {
                throw PlanError.fileTooBig(game: game.title, file: file.relativePath)
            }
        }

        var id = firstID
        var discs: [PlannedDisc] = []
        func takeID() -> String {
            defer { id = DiscID.following(id) ?? id }
            return id
        }

        // Games too big for one disc: each gets its own run of discs.
        for game in games where !fits(game.totalBytes, games: 1) {
            var parts: [[SourceFile]] = [[]]
            var used: Int64 = 0
            for file in installOrder(game.files) {
                if !parts[parts.count - 1].isEmpty && !fits(used + file.size, games: 1) {
                    parts.append([])
                    used = 0
                }
                parts[parts.count - 1].append(file)
                used += file.size
            }
            let setID = takeID()
            for (i, files) in parts.enumerated() {
                var piece = game
                piece.files = files
                discs.append(PlannedDisc(id: DiscID.setDiscKey(setID: setID, part: i + 1, of: parts.count),
                                         setID: setID, part: i + 1, partCount: parts.count, games: [piece]))
            }
        }

        // Everything else: whole games, largest first, on the first disc with room.
        var shared: [[GameFolder]] = []
        for game in games.filter({ fits($0.totalBytes, games: 1) }).sorted(by: { $0.totalBytes > $1.totalBytes }) {
            if let i = shared.firstIndex(where: { group in
                fits(group.reduce(0) { $0 + $1.totalBytes } + game.totalBytes, games: group.count + 1)
            }) {
                shared[i].append(game)
            } else {
                shared.append([game])
            }
        }
        for group in shared {
            let ordered = games.filter { g in group.contains { $0.url == g.url } }
            discs.append(PlannedDisc(id: takeID(), games: ordered))
        }
        return discs
    }

    /// The installer first (so disc 1 starts the install), then the parts in number order.
    static func installOrder(_ files: [SourceFile]) -> [SourceFile] {
        files.sorted { a, b in
            let ae = isTopLevelExe(a.relativePath), be = isTopLevelExe(b.relativePath)
            if ae != be { return ae }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }
    }

    private static func isTopLevelExe(_ path: String) -> Bool {
        !path.contains("/") && path.lowercased().hasSuffix(".exe")
    }

    /// Every ID a plan would use, for clash checks against the catalogue.
    static func baseIDs(_ discs: [PlannedDisc]) -> [String] {
        var seen: [String] = []
        for d in discs where !seen.contains(d.setID ?? d.id) { seen.append(d.setID ?? d.id) }
        return seen
    }
}

/// A set left part-way with "Finish later". Saved as `pending.json` next to the catalogue.
struct PendingSet: Codable {
    var discs: [PlannedDisc]
    var media: Media
    var speed: Int
    var recoveryPercent: Int
    var savedAt: Date

    var summary: String {
        let labels = discs.map(\.label)
        let range = labels.count == 1 ? labels[0] : "\(labels.first!) to \(labels.last!)"
        return "\(range) · \(discs.count == 1 ? "1 disc" : "\(discs.count) discs") left"
    }
}
