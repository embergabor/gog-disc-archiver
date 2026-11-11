import Foundation

/// Everything that goes on one disc: disc path → where the bytes come from.
/// Game files are read straight from their folders; nothing is copied first.
struct DiscLayout: Sendable {
    struct Entry: Sendable {
        enum Source: Sendable {
            case file(URL)
            case data(Data)
        }

        var path: String
        var source: Source
        var size: Int64
    }

    var volumeName: String
    var entries: [Entry]

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }

    static let archiveFolder = "_archive"

    /// Disc layout:
    ///   <Game folder>/<its files>
    ///   _archive/checksums.sha256   SHA-256 of every game and recovery file
    ///   _archive/disc.json          the catalogue record for this disc
    ///   _archive/recovery/*.par2    recovery data, one set per game
    ///   _archive/README.txt
    static func make(record: DiscRecord, games: [GameFolder], recoveryFolder: URL) throws -> DiscLayout {
        var entries: [Entry] = []
        for game in games {
            for file in game.files {
                entries.append(Entry(path: game.name + "/" + file.relativePath,
                                     source: .file(game.url.appendingPathComponent(file.relativePath)),
                                     size: file.size))
            }
        }
        for file in record.recoveryFiles {
            let name = (file.path as NSString).lastPathComponent
            entries.append(Entry(path: file.path, source: .file(recoveryFolder.appendingPathComponent(name)), size: file.size))
        }
        let sums = Data(Checksums.render(record.allFiles).utf8)
        entries.append(Entry(path: archiveFolder + "/checksums.sha256", source: .data(sums), size: Int64(sums.count)))
        var forDisc = record
        forDisc.checks = []
        let json = try CatalogueStore.encoder.encode(forDisc)
        entries.append(Entry(path: archiveFolder + "/disc.json", source: .data(json), size: Int64(json.count)))
        let readme = Data(readmeText(for: record).utf8)
        entries.append(Entry(path: archiveFolder + "/README.txt", source: .data(readme), size: Int64(readme.count)))
        return DiscLayout(volumeName: record.volumeName, entries: entries)
    }

    static func readmeText(for record: DiscRecord) -> String {
        var lines = [
            "\(record.id) — archive disc",
            "Burned \(DateText.dayTime(record.burnedAt)) on \(record.media.longName).",
            "",
            "Games:",
        ]
        for game in record.games {
            lines.append("  \(game.folder)  (\(ByteText.gb(game.bytes)), \(game.files.count) files)")
        }
        lines += [
            "",
            "To install: copy a game's folder to your drive and run its setup file.",
            "",
            "To check this disc by hand, open a terminal in the disc's top folder and run:",
            "  shasum -a 256 -c _archive/checksums.sha256",
        ]
        if !record.recoveryFiles.isEmpty {
            lines += [
                "",
                "If a file is damaged, copy that game's folder and its _archive/recovery/<game>*.par2",
                "files to your drive and run:  par2 repair \"<game>.par2\"",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
