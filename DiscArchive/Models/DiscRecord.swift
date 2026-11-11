import Foundation

/// A file on a burned disc. `path` is relative to the disc root, e.g. "Fallout 2/setup_fallout2.exe".
struct FileRecord: Codable, Hashable, Sendable {
    var path: String
    var size: Int64
    var sha256: String
}

struct GameRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String { folder }
    /// Folder name on the disc (also the display name).
    var folder: String
    var platforms: [String]
    var files: [FileRecord]
    /// Installer build, from the setup file name ("2.6.6.0").
    var version: String? = nil
    /// GOG catalog data, when the game was found there.
    var info: GameInfo? = nil
    /// The user's label for this release, e.g. "Next Gen".
    var edition: String? = nil

    /// "Next Gen · v4.04b"
    var releaseText: String? {
        let parts = [edition, version.map { "v" + $0.replacingOccurrences(of: "_", with: " ") }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var title: String { info?.title ?? folder }

    /// The base game's installer, for looking the game up again.
    var setupFile: String? {
        InstallerName.setupFile(in: files.map { String($0.path.dropFirst(folder.count + 1)) })
    }
}

/// One read-back of a disc: right after burning, or a later re-check.
struct CheckRecord: Codable, Hashable, Sendable {
    var date: Date
    var filesTotal: Int
    /// Disc paths that were missing, unreadable or didn't match their checksum.
    var bad: [String]

    var ok: Bool { bad.isEmpty }
    var filesOK: Int { filesTotal - bad.count }
}

/// One disc in the catalogue.
struct DiscRecord: Codable, Hashable, Identifiable, Sendable {
    /// Disc ID as written on the disc, e.g. "GOG-014".
    var id: String
    var volumeName: String
    var media: Media
    var burnedAt: Date
    var drive: String
    var speed: Int
    var recoveryPercent: Int
    var games: [GameRecord]
    /// Recovery files on the disc (`_archive/recovery/...`), checked like game files.
    var recoveryFiles: [FileRecord]
    var checks: [CheckRecord]
    /// For a game split over several discs: the set's ID ("GOG-014") and this disc's place in it.
    var setID: String? = nil
    var part: Int? = nil
    var partCount: Int? = nil

    /// What's written on the disc: "GOG-014", or "GOG-014 2/5" for a disc of a set.
    var label: String { DiscID.label(id: id, setID: setID, part: part, partCount: partCount) }
    /// The ID that numbering continues from: the set's ID for a set disc.
    var baseID: String { setID ?? id }

    var gameBytes: Int64 { games.reduce(0) { $0 + $1.bytes } }
    var recoveryBytes: Int64 { recoveryFiles.reduce(0) { $0 + $1.size } }
    var allFiles: [FileRecord] { games.flatMap(\.files) + recoveryFiles }
    var lastCheck: CheckRecord? { checks.max { $0.date < $1.date } }

    enum Health: Equatable {
        case ok, due, damaged, neverChecked
    }

    /// Re-read every three years; damaged if the latest read found bad files.
    func health(now: Date = Date()) -> Health {
        guard let last = lastCheck else { return .neverChecked }
        if !last.ok { return .damaged }
        let due = Calendar.current.date(byAdding: .year, value: 3, to: last.date) ?? last.date
        return now >= due ? .due : .ok
    }

    var nextCheckDate: Date? {
        guard let last = lastCheck else { return nil }
        return Calendar.current.date(byAdding: .year, value: 3, to: last.date)
    }
}

/// The whole catalogue file, `discs.json`.
struct CatalogueFile: Codable, Sendable {
    var version = 1
    var discs: [DiscRecord] = []
}

enum DateText {
    /// "2026.11.11", the user's preferred date style.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd"
        return f.string(from: date)
    }

    static func dayTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd HH:mm"
        return f.string(from: date)
    }

    static func month(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM"
        return f.string(from: date)
    }
}
