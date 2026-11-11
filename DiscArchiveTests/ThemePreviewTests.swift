import SwiftUI
import XCTest
@testable import DiscArchive

/// Design previews of the purple cover themes, from the user's real folders. Needs COVER_PREVIEW_DIR. Network.
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

        let multi = await disc("GOG-001", ["Fallout v1.2.27130 GoG", "Fallout 2", "Fallout.Tactics.v2.1.0.12.GOG.Retail-CORE",
                                            "Gabriel Knight", "Gabriel Knight 2", "Gabriel Knight 3", "Arx Fatalis", "Chronicles of Riddick"])
        let single = await disc("GOG-002", ["The Witcher 3 Wild Hunt"])

        func sheet(_ title: String, _ items: [(String, CoverTheme, CoverDisc)]) -> some View {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.system(size: 20, weight: .bold))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.0).font(.system(size: 13, weight: .semibold))
                        BDWrapView(disc: item.2)
                            .environment(\.coverTheme, item.1)
                            .overlay(Rectangle().stroke(Color(hex: 0xCCCCCC), lineWidth: 0.5))
                    }
                }
            }
            .padding(24)
            .background(Color(hex: 0xF4F4F4))
        }

        let options: [(String, CoverTheme.Backdrop)] = [("A · Flat purple", .flat), ("B · Purple with disc-groove rings", .rings),
                                                        ("C · Purple duotone of the box art", .duotone)]
        let pages: [(String, AnyView)] = [
            ("1-backdrops-multi", AnyView(sheet("Backdrop options · multi-game disc · back black on white",
                                                options.map { ($0.0, CoverTheme.purple($0.1), multi) }))),
            ("2-backdrops-single", AnyView(sheet("Backdrop options · single game · back black on white",
                                                 options.map { ($0.0, CoverTheme.purple($0.1), single) }))),
            ("3-back-styles", AnyView(sheet("Back styles (shown with backdrop A)",
                                            [("Back: black on white", CoverTheme.purple(.flat), multi),
                                             ("Back: purple on white", CoverTheme.purple(.flat, purpleBack: true), multi),
                                             ("Back: purple on white, single game", CoverTheme.purple(.flat, purpleBack: true), single)]))),
        ]
        for (name, view) in pages {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1.4
            let png = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: folder.appendingPathComponent("theme-\(name).png"))
        }
    }
}
