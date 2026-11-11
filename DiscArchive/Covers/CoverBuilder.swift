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
            record.games[i].info = await service.lookup(setupFile: game.setupFile, folderName: game.folder)
            if record.games[i].version == nil, let setup = game.setupFile {
                let v = InstallerName.parse(setup).version
                record.games[i].version = v.isEmpty ? nil : v
            }
        }
        return record
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
                                   summary: game.info?.summary, portrait: portrait, wide: wide))
        }
        let source = games.first?.portrait
        var facts: [(String, String)] = [("Burned", "\(DateText.day(record.burnedAt)) · \(record.media.longName) · \(record.speed)×")]
        if let check = record.lastCheck {
            facts.append(("Verified", "\(DateText.day(check.date)) · \(check.filesOK) of \(check.filesTotal) files OK"))
        }
        facts.append(("On disc", record.recoveryFiles.isEmpty ? "checksums.sha256" : "checksums.sha256 · par2 recovery \(record.recoveryPercent)%"))
        let count = record.games.count
        var subtitle = "\(count == 1 ? "1 game" : "\(count) games") · \(ByteText.gb(record.gameBytes)) · \(record.media.label)"
        var partText: String?
        if let part = record.part, let total = record.partCount, let setID = record.setID {
            partText = "\(part)/\(total)"
            subtitle = "Disc \(part) of \(total) · \(ByteText.files(record.games.first?.files.count ?? 0)) · \(ByteText.gb(record.gameBytes)) · \(record.media.label)"
            facts.append(("Set", "\(setID) 1/\(total) to \(total)/\(total) hold only this game"))
            facts.append(("Install", "copy the game's folder from all \(total) discs into one folder, run setup_*.exe"))
            if let i = games.indices.first {
                let files = DiscPlanner.installOrder(record.games[0].files.map { SourceFile(relativePath: String($0.path.dropFirst(record.games[0].folder.count + 1)), size: $0.size) })
                    .map(\.relativePath)
                let range = files.count > 1 ? "\(files.first!) … \(files.last!)" : (files.first ?? "")
                let release = record.games[0].releaseText.map { $0 + " · " } ?? ""
                games[i].details = release + "Part \(part) of \(total) · " + range + " · " + ByteText.gb(record.gameBytes)
            }
        } else {
            facts.append(("Install", "copy a game's folder to your drive and run setup_*.exe"))
        }
        return CoverDisc(id: record.id, idText: record.setID ?? record.id, partText: partText, media: record.media.label, burned: record.burnedAt,
                         subtitle: subtitle, facts: facts, games: games, backdrop: CoverStyle.backdrop(from: source))
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
