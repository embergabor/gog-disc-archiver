import AppKit
import SwiftUI

/// Turns catalogue records into cover content (fetching missing game info and art) and writes PDFs.
@MainActor
enum CoverBuilder {
    /// Fills in GOG info for games that don't have it yet. Returns the updated record (unchanged if nothing was found).
    static func withInfo(_ record: DiscRecord, service: GameInfoService) async -> DiscRecord {
        var record = record
        for i in record.games.indices where record.games[i].info == nil {
            let game = record.games[i]
            record.games[i].info = await service.lookup(setupFile: game.setupFile, productName: game.installerTitle, folderName: game.folder)
            if record.games[i].version == nil, let setup = game.setupFile {
                let v = InstallerName.parse(setup).version
                record.games[i].version = v.isEmpty ? nil : v
            }
        }
        return record
    }

    /// A not-yet-burned disc as a catalogue record, so covers can be made before and during the burn.
    /// Dated today; no checksums or read-back yet.
    static func record(for disc: PlannedDisc, media: Media, speed: Int, recoveryPercent: Int) -> DiscRecord {
        let games = disc.games.map { g in
            GameRecord(folder: g.name, platforms: g.platforms,
                       files: g.files.map { FileRecord(path: g.name + "/" + $0.relativePath, size: $0.size, sha256: "") },
                       version: g.version, info: g.info, edition: g.edition, installerTitle: g.installer?.productName)
        }
        return DiscRecord(id: disc.id, volumeName: disc.volumeName, media: media, burnedAt: Date(), drive: "", speed: speed,
                          recoveryPercent: recoveryPercent, games: games, recoveryFiles: [], checks: [],
                          setID: disc.setID, part: disc.part, partCount: disc.partCount)
    }

    static func disc(_ record: DiscRecord, service: GameInfoService) async -> CoverDisc {
        var games: [CoverGame] = []
        for game in record.games {
            var portrait: NSImage?
            var wide: NSImage?
            if let info = game.info {
                let art = await service.art(for: info)
                portrait = art.portrait.flatMap(NSImage.init(contentsOf:))
                wide = art.wide.flatMap(NSImage.init(contentsOf:))
            }
            // Covers are portrait only. No box art: make one from the wide art and the title.
            if portrait == nil, let wide {
                portrait = MadeCover.from(wide: wide, title: game.title)
            }
            var details: [String] = []
            if let release = game.releaseText { details.append(release) }
            details += game.platforms
            details.append(ByteText.gb(game.bytes))
            games.append(CoverGame(id: game.folder, title: game.title, edition: game.edition, byline: game.info?.byline ?? "",
                                   genres: game.info?.genres ?? [], details: details.joined(separator: " · "),
                                   summary: game.info?.summary.map { Self.shortSummary($0) }, portrait: portrait, wide: wide))
        }
        let source = games.first?.portrait
        var facts: [(String, String)] = [("Burned", "\(DateText.day(record.burnedAt)) · \(record.media.longName) · \(record.speed)×")]
        if let check = record.lastCheck {
            facts.append(("Verified", "\(DateText.day(check.date)) · \(check.filesOK) of \(check.filesTotal) files OK"))
        }
        facts.append(("On disc", record.recoveryPercent == 0 ? "checksums.sha256" : "checksums.sha256 · par2 recovery \(record.recoveryPercent)%"))
        let count = record.games.count
        var subtitle = "\(count == 1 ? "1 game" : "\(count) games") · \(ByteText.gb(record.gameBytes)) · \(record.media.label)"
        var partText: String?
        if let part = record.part, let total = record.partCount, let setID = record.setID {
            partText = "\(part)/\(total)"
            subtitle = "Disc \(part) of \(total) · \(ByteText.files(record.games.first?.files.count ?? 0)) · \(ByteText.gb(record.gameBytes)) · \(record.media.label)"
            facts.append(("Set", "\(setID) 1/\(total) to \(total)/\(total) hold only this game"))
            facts.append(("Install", "copy the game's folder from all \(total) discs into one folder, run setup_*.exe"))
            if let i = games.indices.first {
                let files = record.games[0].files.map { String($0.path.dropFirst(record.games[0].folder.count + 1)) }
                let range = Self.partsText(files)
                let release = record.games[0].releaseText.map { $0 + " · " } ?? ""
                games[i].details = release + "Part \(part) of \(total) · " + range + " · " + ByteText.gb(record.gameBytes)
            }
        } else {
            facts.append(("Install", "copy a game's folder to your drive and run setup_*.exe"))
        }
        return CoverDisc(id: record.id, idText: record.setID ?? record.id, partText: partText, media: record.media.label, burned: record.burnedAt,
                         subtitle: subtitle, facts: facts, games: games, backdrop: CoverStyle.backdrop(from: source))
    }

    /// "installer + parts 1–5", "parts 6–10", or the file count when the names don't follow GOG's pattern.
    nonisolated static func partsText(_ files: [String]) -> String {
        let hasInstaller = files.contains { !$0.contains("/") && $0.lowercased().hasSuffix(".exe") }
        let parts = files.compactMap { name -> Int? in
            guard let r = name.range(of: #"-(\d+)\.bin$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return Int(name[r].dropFirst().dropLast(4))
        }.sorted()
        var pieces: [String] = []
        if hasInstaller { pieces.append("installer") }
        if let first = parts.first, let last = parts.last {
            pieces.append(first == last ? "part \(first)" : "parts \(first)–\(last)")
        }
        let other = files.count - parts.count - (hasInstaller ? 1 : 0)
        if other > 0 || pieces.isEmpty { pieces.append(ByteText.files(pieces.isEmpty ? files.count : other) + (pieces.isEmpty ? "" : " more")) }
        return pieces.joined(separator: " + ")
    }

    /// Whole paragraphs up to about 520 characters; a long first paragraph ends at its last full sentence.
    nonisolated static func shortSummary(_ text: String, limit: Int = 520) -> String {
        var out = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if out.isEmpty {
                out = p
            } else if out.count + p.count + 2 <= limit {
                out += "\n\n" + p
            } else {
                break
            }
        }
        guard out.count > limit + 160 else { return out }
        let cut = String(out.prefix(limit))
        if let end = cut.range(of: #"[.!?](\s|$)"#, options: [.regularExpression, .backwards]) {
            return String(cut[..<end.lowerBound]) + String(cut[end].prefix(1))
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One A4 page per sheet: two jewel fronts or one Blu-ray wrap per page.
    static func pages(kind: CoverKind, discs: [CoverDisc]) -> [[CoverDisc]] {
        stride(from: 0, to: discs.count, by: kind.perPage).map { Array(discs[$0..<min($0 + kind.perPage, discs.count)]) }
    }

    enum PDFError: LocalizedError {
        case cannotCreate(String)
        var errorDescription: String? {
            switch self {
            case .cannotCreate(let path): "Could not write \(path)."
            }
        }
    }

    static func writePDF(kind: CoverKind, discs: [CoverDisc], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(origin: .zero, size: kind.pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: "Disc Archive covers"] as CFDictionary) else {
            throw PDFError.cannotCreate(url.path)
        }
        for page in pages(kind: kind, discs: discs) {
            let renderer = ImageRenderer(content: CoverSheet(kind: kind, discs: page))
            renderer.proposedSize = ProposedViewSize(kind.pageSize)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
}
