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
                       version: game.version, info: info, edition: edition, installerTitle: game.customTitle ?? game.installer?.usableName)
        }
        func games(_ names: [String]) async throws -> [(GameFolder, GameInfo?)] {
            var out: [(GameFolder, GameInfo?)] = []
            for name in names {
                guard let g = try? GameFolder.scan(root.appendingPathComponent(name)) else { continue }
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
        guard !witcherItems.isEmpty else { throw XCTSkip("no Witcher 3 folder") }
        var w = witcherItems[0].0
        w.files = Array(DiscPlanner.installOrder(w.files).prefix(6))
        var witcher = disc("GOG-002-1of3", [(w, witcherItems[0].1)], edition: "Next Gen")
        witcher.setID = "GOG-002"; witcher.part = 1; witcher.partCount = 3
        let sierra = disc("GOG-003", try await games(["Gabriel Knight", "Gabriel Knight 2", "Gabriel Knight 3", "Planescape Torment", "Icewind Dale"]))
        let baldur = disc("GOG-004", try await games(["Baldur's Gate - Enhanced Edition v2.7.3.0-s - GoG", "Baldurs Gate 2"]))
        let oblivionItems = try await games(["The Elder Scrolls IV - Oblivion"])
        print("OBLIVION", oblivionItems.first.map { "\($0.0.title) | \($0.1?.title ?? "NOT FOUND") | steam \($0.1?.steamAppID.map(String.init) ?? "-")" } ?? "no folder")
        let oblivion = disc("GOG-006", oblivionItems)

        var covers: [CoverDisc] = []
        for (name, r) in [("1-riddick", riddick), ("2-witcher-1of3", witcher), ("3-five-games", sierra), ("4-two-games", baldur), ("5-oblivion", oblivion)] {
            let c = await CoverBuilder.disc(r, service: service)
            covers.append(c)
            for kind in [CoverKind.bluRay, .jewel] {
                let renderer = ImageRenderer(content: CoverSheet(kind: kind, discs: [c]))
                renderer.scale = 1.6
                let png = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                try png.write(to: folder.appendingPathComponent("\(kind == .bluRay ? "bd" : "jewel")-\(name).png"))
            }
        }
        try CoverBuilder.writePDF(kind: .jewel, discs: covers, to: folder.appendingPathComponent("Jewel booklet previews.pdf"))
        try CoverBuilder.writePDF(kind: .bluRay, discs: covers, to: folder.appendingPathComponent("Blu-ray cover previews.pdf"))

        // The New disc screen with a collection disc, to check the live cover preview.
        UserDefaults.standard.register(defaults: ["archiveRoot": folder.path])
        let model = AppModel()
        model.selectMedia(.bd25)
        model.draft.id = "GOG-005"
        for name in ["Gabriel Knight", "Gabriel Knight 2", "Gabriel Knight 3", "Fallout 2", "Arx Fatalis", "Chronicles of Riddick"] {
            guard var g = try? GameFolder.scan(root.appendingPathComponent(name)) else { continue }
            g.info = await service.lookup(setupFile: g.setupFile, productName: g.installer?.productName, folderName: g.name)
            g.lookedUp = true
            model.draft.games.append(g)
        }
        let host = NSHostingView(rootView: NewDiscView().environment(model).frame(width: 1100, height: 1100).background(Theme.window))
        host.frame = CGRect(x: 0, y: 0, width: 1100, height: 1100)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 1100, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); try await Task.sleep(nanoseconds: 50_000_000) }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("new-disc-preview.png"))

        // The enlarged cover view.
        let zoomHost = NSHostingView(rootView: CoverZoomView(covers: covers, selected: covers[2].id, print: {}).frame(width: 1300, height: 820))
        zoomHost.frame = CGRect(x: 0, y: 0, width: 1300, height: 820)
        let zoomWindow = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 1300, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        zoomWindow.contentView = zoomHost
        zoomWindow.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let zoomRep = zoomHost.bitmapImageRepForCachingDisplay(in: zoomHost.bounds)!
        zoomHost.cacheDisplay(in: zoomHost.bounds, to: zoomRep)
        zoomWindow.orderOut(nil)
        try zoomRep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("zoom.png"))
    }
}

/// Renders cover backs for several game counts so overflow can be checked by eye. Needs COVER_PREVIEW_DIR.
@MainActor
final class BackFitTests: XCTestCase {
    func testBackFitsManyGames() throws {
        guard let out = ProcessInfo.processInfo.environment["COVER_PREVIEW_DIR"] else { throw XCTSkip("COVER_PREVIEW_DIR not set") }
        var row: [AnyView] = []
        for count in [6, 10, 14] {
            let games = (1...count).map { i in
                CoverGame(id: "g\(i)", title: "A Rather Long Game Title Number \(i): The Enhanced Edition", edition: nil,
                          byline: "Some Developer Studio · 1999", genres: ["Role-playing", "Adventure", "Fantasy"],
                          details: "v2.0.0.12 · Windows · Mac · 3.1 GB", summary: nil, portrait: nil, wide: nil)
            }
            let disc = CoverDisc(id: "GOG-001", idText: "GOG-001", partText: nil, media: "BD-R 25", burned: Date(), subtitle: "\(count) games",
                                 facts: [("Burned", "2026.11.11"), ("Verified", "2026.11.11"), ("On disc", "checksums.sha256"), ("Install", "copy a game's folder")],
                                 games: games, backdrop: nil)
            row.append(AnyView(BDBack(disc: disc).border(Color.red, width: 0.5)))
        }
        let renderer = ImageRenderer(content: HStack(spacing: 10) { ForEach(0..<row.count, id: \.self) { row[$0] } }.padding(10).background(Color.white))
        renderer.scale = 1.5
        let png = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("backs.png"))
    }
}
