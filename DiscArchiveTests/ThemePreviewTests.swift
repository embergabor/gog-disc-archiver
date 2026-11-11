import SwiftUI
import XCTest
@testable import DiscArchive

/// Previews of the chosen cover design and its ink-saver variant, from the user's real folders.
/// Needs COVER_PREVIEW_DIR. Network.
@MainActor
final class ThemePreviewTests: XCTestCase {
    func testThemePreviews() async throws {
        guard let out = ProcessInfo.processInfo.environment["COVER_PREVIEW_DIR"] else { throw XCTSkip("COVER_PREVIEW_DIR not set") }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/GOG")
        let service = GameInfoService(cacheRoot: folder.appendingPathComponent("Info"))

        func disc(_ id: String, _ names: [String]) async -> CoverDisc {
            var r = DiscRecord.sample(id: id)
            r.burnedAt = Date()
            r.recoveryPercent = 0
            r.media = .bd50
            var games: [GameRecord] = []
            for name in names {
                guard let g = try? GameFolder.scan(root.appendingPathComponent(name)) else { continue }
                let info = await service.lookup(setupFile: g.setupFile, productName: g.installer?.productName, folderName: g.name)
                games.append(GameRecord(folder: g.name, platforms: g.platforms,
                                        files: g.files.map { FileRecord(path: g.name + "/" + $0.relativePath, size: $0.size, sha256: "") },
                                        version: g.version, info: info, installerTitle: g.installer?.usableName))
            }
            r.games = games
            r.checks = [CheckRecord(date: Date(), filesTotal: r.allFiles.count, bad: [])]
            return await CoverBuilder.disc(r, service: service)
        }

        let multi = await disc("GOG-001", ["Fallout v1.2.27130 GoG", "Fallout 2", "Gabriel Knight", "Gabriel Knight 2",
                                            "Gabriel Knight 3", "Arx Fatalis", "Chronicles of Riddick"])
        let single = await disc("GOG-002", ["The Witcher 3 Wild Hunt"])

        func item(_ label: String, _ view: some View) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 13, weight: .semibold))
                view.overlay(Rectangle().stroke(Color(hex: 0xCCCCCC), lineWidth: 0.5))
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 18) {
            Text("Chosen design: purple spine, disc-groove rings, purple on white back").font(.system(size: 20, weight: .bold))
            item("Jewel front + tray · standard · multi-game", CoverSheet(kind: .jewelTray, discs: [multi]).environment(\.coverTheme, .purple(inkSaver: false)))
            item("Jewel front + tray · ink saver · single game", CoverSheet(kind: .jewelTray, discs: [single]).environment(\.coverTheme, .purple(inkSaver: true)))
        }
        .padding(24)
        .background(Color(hex: 0xF4F4F4))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1.4
        let png = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: folder.appendingPathComponent("jewel-tray.png"))
        try CoverBuilder.writePDF(kind: .jewelTray, discs: [multi, single], to: folder.appendingPathComponent("Jewel front and tray.pdf"))
    }
}
