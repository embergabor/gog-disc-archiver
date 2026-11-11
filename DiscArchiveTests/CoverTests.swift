import SwiftUI
import XCTest
@testable import DiscArchive

/// The same cases as the Steam Deck GOG installer's tests.
final class InstallerNameTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(InstallerName.title("setup_hollow_knight_1.5.12620_(64bit)_(89718).exe"), "Hollow Knight")
        XCTAssertEqual(InstallerName.title("setup_the_lord_of_the_rings_2.0_(1).exe"), "The Lord of the Rings")
        XCTAssertEqual(InstallerName.title("setup_baldurs_gate_2_v2.6.exe"), "Baldurs Gate 2")
        XCTAssertEqual(InstallerName.title("setup_some_game_12345.exe"), "Some Game")
    }

    func testParse() {
        XCTAssertTrue(InstallerName.parse("setup_hollow_knight_1.5.12620_(64bit)_(89718).exe") == ("hollow_knight", "1.5.12620"))
        XCTAssertTrue(InstallerName.parse("setup_heroes_of_might_and_magic_3_complete_4.0_(3.2)_gog_0.1_(77075).exe")
                      == ("heroes_of_might_and_magic_3_complete", "4.0_(3.2)_gog_0.1"))
        XCTAssertTrue(InstallerName.parse("setup_rollercoaster_tycoon2_2.0.0.6.exe") == ("rollercoaster_tycoon2", "2.0.0.6"))
    }

    func testCatalogMatchIsExact() {
        typealias P = GameInfoService.CatalogProduct
        func p(_ id: String, _ slug: String, _ title: String) -> P {
            P(id: id, slug: slug, title: title)
        }
        let products = [p("1", "hollow_knight_silksong", "Hollow Knight: Silksong"), p("2", "hollow_knight", "Hollow Knight")]
        XCTAssertEqual(GameInfoService.matchCatalog("hollow_knight", products: products)?.id, "2")
        XCTAssertNil(GameInfoService.matchCatalog("hollow", products: products))
        let heroes = [p("3", "heroes_of_might_and_magic_3_complete_edition", "Heroes of Might and Magic® 3: Complete")]
        XCTAssertEqual(GameInfoService.matchCatalog("heroes_of_might_and_magic_3_complete", products: heroes)?.id, "3")
        let rct = [p("4", "rollercoaster_tycoon_2", "RollerCoaster Tycoon® 2: Triple Thrill Pack")]
        XCTAssertEqual(GameInfoService.matchCatalog("rollercoaster_tycoon2", products: rct)?.id, "4")
    }

    func testSetupFileIsTheBaseGame() {
        let files = ["setup_witcher_3_4.04.exe", "setup_witcher_3_4.04-1.bin", "setup_witcher_3_hearts_of_stone_4.04.exe", "extras/setup_x.exe"]
        XCTAssertEqual(InstallerName.setupFile(in: files), "setup_witcher_3_4.04.exe")
    }

    func testPlainText() {
        XCTAssertEqual(GameInfoService.plainText("You are <b>the</b> Chosen One.<br><br>Tribe &amp; village."),
                       "You are the Chosen One.\n\nTribe & village.")
    }

    func testGridUsesTheLargestCovers() {
        let size = CGSize(width: 365, height: 351)
        XCTAssertEqual(FrontArt.gridLayout(count: 2, size: size, gap: 8).cols, 2)
        XCTAssertEqual(FrontArt.gridLayout(count: 5, size: size, gap: 8).cols, 3)
        let many = FrontArt.gridLayout(count: 14, size: size, gap: 4)
        XCTAssertGreaterThanOrEqual(many.cols * many.rows, 14)
    }
}

/// Real lookups and real art, rendered to PDF and PNG for a visual check.
/// Runs only when SNAPSHOT_DIR is set (xcodebuild: TEST_RUNNER_SNAPSHOT_DIR=/some/folder). Uses the network.
@MainActor
final class CoverSnapshotTests: XCTestCase {
    func testSampleCovers() async throws {
        guard let out = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { throw XCTSkip("SNAPSHOT_DIR not set") }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        let service = GameInfoService(cacheRoot: folder.appendingPathComponent("Info"))

        func record(_ id: String, _ games: [(String, String, Int64)]) -> DiscRecord {
            var r = DiscRecord.sample(id: id)
            r.recoveryPercent = 5
            r.recoveryFiles = [FileRecord(path: "_archive/recovery/x.par2", size: 1, sha256: "")]
            r.checks = [CheckRecord(date: r.burnedAt, filesTotal: 17, bad: [])]
            r.games = games.map { folderName, setup, size in
                GameRecord(folder: folderName, platforms: ["Windows"], files: [
                    FileRecord(path: "\(folderName)/\(setup)", size: size, sha256: ""),
                ])
            }
            return r
        }

        let single = record("GOG-015", [("Fallout 2", "setup_fallout_2_2.1.0.18.exe", 640_000_000)])
        let multi = record("GOG-014", [
            ("Disco Elysium", "setup_disco_elysium_1.0.exe", 14_800_000_000),
            ("Baldurs Gate 2", "setup_baldurs_gate_2_enhanced_edition_2.6.6.0.exe", 3_100_000_000),
            ("Planescape Torment", "setup_planescape_torment_enhanced_edition_3.1.4.exe", 2_400_000_000),
            ("Heroes 3", "setup_heroes_of_might_and_magic_3_complete_4.0_(3.2)_gog_0.1_(77075).exe", 1_000_000_000),
            ("Fallout 2", "setup_fallout_2_2.1.0.18.exe", 640_000_000),
        ])

        var discs: [CoverDisc] = []
        for r in [single, multi] {
            let filled = await CoverBuilder.withInfo(r, service: service)
            print("lookup", filled.id, filled.games.map { "\($0.folder) -> \($0.info?.title ?? "-") steam:\($0.info?.steamAppID.map(String.init) ?? "-")" })
            discs.append(await CoverBuilder.disc(filled, service: service))
        }

        try CoverBuilder.writePDF(kind: .bluRay, discs: discs, to: folder.appendingPathComponent("bluray.pdf"))
        try CoverBuilder.writePDF(kind: .jewel, discs: discs, to: folder.appendingPathComponent("jewel.pdf"))
        for (name, view) in [("bd-single", AnyView(CoverSheet(kind: .bluRay, discs: [discs[0]]))),
                             ("bd-multi", AnyView(CoverSheet(kind: .bluRay, discs: [discs[1]]))),
                             ("jewel", AnyView(CoverSheet(kind: .jewel, discs: discs)))] {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1.6
            let png = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }
}
