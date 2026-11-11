import SwiftUI
import XCTest
@testable import DiscArchive

/// Blu-ray cover previews from the user's real GOG folders. Runs only with COVER_PREVIEW_DIR set. Network.
@MainActor
final class CoverPreviewTests: XCTestCase {
    func testBluRayPreviews() async throws {
        guard let out = ProcessInfo.processInfo.environment["COVER_PREVIEW_DIR"] else { throw XCTSkip("COVER_PREVIEW_DIR not set") }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/GOG")
        let service = GameInfoService(cacheRoot: folder.appendingPathComponent("Info"))

        func record(_ game: GameFolder, info: GameInfo?, edition: String? = nil) -> GameRecord {
            GameRecord(folder: game.name, platforms: game.platforms,
                       files: game.files.map { FileRecord(path: game.name + "/" + $0.relativePath, size: $0.size, sha256: "") },
                       version: game.version, info: info, edition: edition, installerTitle: game.installer?.productName)
        }
        func games(_ names: [String]) async throws -> [(GameFolder, GameInfo?)] {
            var out: [(GameFolder, GameInfo?)] = []
            for name in names {
                let g = try GameFolder.scan(root.appendingPathComponent(name))
                out.append((g, await service.lookup(setupFile: g.setupFile, productName: g.installer?.productName, folderName: g.name)))
            }
            return out
        }
        func disc(_ id: String, _ items: [(GameFolder, GameInfo?)], edition: String? = nil) -> DiscRecord {
            var r = DiscRecord.sample(id: id)
            r.burnedAt = Date()
            r.recoveryPercent = 5
            r.recoveryFiles = [FileRecord(path: "_archive/recovery/x.par2", size: 1, sha256: "")]
            r.games = items.map { record($0.0, info: $0.1, edition: edition) }
            r.checks = [CheckRecord(date: Date(), filesTotal: r.allFiles.count, bad: [])]
            return r
        }

        let riddick = disc("GOG-001", try await games(["Chronicles of Riddick"]))
        // One disc of a split set: Witcher 3 part 1 of 3, the installer and the first parts.
        let witcherItems = try await games(["The Witcher 3 Wild Hunt"])
        var w = witcherItems[0].0
        w.files = Array(DiscPlanner.installOrder(w.files).prefix(6))
        var witcher = disc("GOG-002-1of3", [(w, witcherItems[0].1)], edition: "Next Gen")
        witcher.setID = "GOG-002"; witcher.part = 1; witcher.partCount = 3
        let sierra = disc("GOG-003", try await games(["Gabriel Knight", "Gabriel Knight 2", "Gabriel Knight 3", "Planescape Torment", "Icewind Dale"]))
        let baldur = disc("GOG-004", try await games(["Baldur's Gate - Enhanced Edition v2.7.3.0-s - GoG", "Baldurs Gate 2"]))

        var covers: [CoverDisc] = []
        for (name, r) in [("1-riddick", riddick), ("2-witcher-1of3", witcher), ("3-five-games", sierra), ("4-two-games", baldur)] {
            let c = await CoverBuilder.disc(r, service: service)
            covers.append(c)
            let renderer = ImageRenderer(content: CoverSheet(kind: .bluRay, discs: [c]))
            renderer.scale = 1.6
            let png = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: folder.appendingPathComponent("bd-\(name).png"))
        }
        try CoverBuilder.writePDF(kind: .bluRay, discs: covers, to: folder.appendingPathComponent("Blu-ray cover previews.pdf"))
    }
}
