import XCTest
@testable import DiscArchive

final class PlannerTests: XCTestCase {
    private func game(_ name: String, _ files: [(String, Int64)]) -> GameFolder {
        GameFolder(url: URL(fileURLWithPath: "/games/\(name)"), files: files.map { SourceFile(relativePath: $0.0, size: $0.1) })
    }

    /// A Witcher-sized game gets its own discs; small games share another; files stay whole.
    func testBigGameGetsItsOwnDiscs() throws {
        let bins = (1...13).map { ("setup_the_witcher_3_4.04-\($0).bin", Int64(3_970_000_000)) }
        let witcher = game("The Witcher 3", bins + [("setup_the_witcher_3_4.04.exe", 100_000_000)])
        let small = [game("Fallout 2", [("setup_fallout2.exe", 600_000_000)]), game("Heroes 3", [("setup_h3.exe", 1_000_000_000)])]

        let discs = try DiscPlanner.plan(games: [small[0], witcher, small[1]], media: .bd25, percent: 5, firstID: "GOG-014")

        let set = discs.filter { $0.setID == "GOG-014" }
        XCTAssertEqual(set.count, 3)
        XCTAssertEqual(set.map(\.part), [1, 2, 3])
        XCTAssertTrue(set.allSatisfy { $0.partCount == 3 && $0.games.count == 1 && $0.games[0].name == "The Witcher 3" })
        XCTAssertEqual(set[0].games[0].files.first?.relativePath, "setup_the_witcher_3_4.04.exe", "installer first")
        XCTAssertEqual(set[1].games[0].files.first?.relativePath, "setup_the_witcher_3_4.04-6.bin", "parts in number order")
        XCTAssertEqual(set.map { $0.games[0].files.count }.reduce(0, +), 14, "every file once")
        XCTAssertLessThan(set[2].dataBytes, set[0].dataBytes, "last disc is not topped up")
        XCTAssertEqual(set.map(\.volumeName), ["GOG_014_1", "GOG_014_2", "GOG_014_3"])
        XCTAssertEqual(set.map(\.label), ["GOG-014 1/3", "GOG-014 2/3", "GOG-014 3/3"])
        for disc in discs {
            XCTAssertLessThanOrEqual(DiscPlanner.usedBytes(disc.dataBytes, games: disc.games.count, percent: 5), Media.bd25.usable)
        }

        let shared = discs.filter { $0.setID == nil }
        XCTAssertEqual(shared.map(\.id), ["GOG-015"])
        XCTAssertEqual(shared[0].games.map(\.name), ["Fallout 2", "Heroes 3"])
        XCTAssertEqual(DiscPlanner.baseIDs(discs), ["GOG-014", "GOG-015"])
    }

    func testOneDiscWhenItFits() throws {
        let discs = try DiscPlanner.plan(games: [game("A", [("setup_a.exe", 3_000_000_000)])], media: .bd25, percent: 5, firstID: "GOG-020")
        XCTAssertEqual(discs.map(\.id), ["GOG-020"])
        XCTAssertNil(discs[0].setID)
        XCTAssertEqual(discs[0].volumeName, "GOG_020")
    }

    func testFileBiggerThanTheDisc() {
        let zip = game("Witcher zip", [("part1.zip", 20_000_000_000)])
        XCTAssertThrowsError(try DiscPlanner.plan(games: [zip], media: .dvdR, percent: 0, firstID: "GOG-001")) { error in
            XCTAssertEqual(error as? DiscPlanner.PlanError, .fileTooBig(game: "Witcher zip", file: "part1.zip"))
        }
        XCTAssertNoThrow(try DiscPlanner.plan(games: [zip], media: .bd25, percent: 5, firstID: "GOG-001"))
    }

    func testNumberingContinuesAfterASet() {
        var a = DiscRecord.sample(id: DiscID.setDiscKey(setID: "GOG-014", part: 1, of: 3))
        a.setID = "GOG-014"; a.part = 1; a.partCount = 3
        XCTAssertEqual(a.label, "GOG-014 1/3")
        XCTAssertEqual(DiscID.next(after: [a.baseID, "GOG-013"]), "GOG-015")
        XCTAssertNil(DiscID.split(a.id), "set disc keys never count as numbers")
    }
}

@MainActor
final class SetBurnTests: XCTestCase {
    /// Two discs of one game, burned with the folder writer: swap, second disc, both in the catalogue.
    func testSimulatedSetBurn() async throws {
        let dir = try TempDir()
        let folder = try dir.makeGame("source/Big Game", files: ["setup_big.exe": 200_000, "setup_big-1.bin": 400_000, "setup_big-2.bin": 400_000])
        let whole = try GameFolder.scan(folder)
        var part1 = whole, part2 = whole
        part1.files = whole.files.filter { $0.relativePath != "setup_big-2.bin" }
        part2.files = whole.files.filter { $0.relativePath == "setup_big-2.bin" }
        let discs = [
            PlannedDisc(id: DiscID.setDiscKey(setID: "GOG-030", part: 1, of: 2), setID: "GOG-030", part: 1, partCount: 2, games: [part1]),
            PlannedDisc(id: DiscID.setDiscKey(setID: "GOG-030", part: 2, of: 2), setID: "GOG-030", part: 2, partCount: 2, games: [part2]),
        ]
        let paths = AppPaths(root: dir.url.appendingPathComponent("Archive"))
        let out = dir.url.appendingPathComponent("discs")
        let session = BurnSession(discs: discs, media: .dvdR, speed: 8, recoveryPercent: 0)
        var saved: [DiscRecord] = []

        session.start(writer: FolderWriter(folder: out), par2: nil, paths: paths) { saved.append($0) }
        try await waitFor { session.job?.outcome != nil }
        XCTAssertTrue(session.waitingForNextDisc)
        XCTAssertEqual(session.remaining.map(\.label), ["GOG-030 2/2"])

        session.advance()
        session.start(writer: FolderWriter(folder: out), par2: nil, paths: paths) { saved.append($0) }
        try await waitFor { session.job?.outcome != nil }
        XCTAssertFalse(session.waitingForNextDisc)
        XCTAssertTrue(session.remaining.isEmpty)

        XCTAssertEqual(saved.map(\.label), ["GOG-030 1/2", "GOG-030 2/2"])
        XCTAssertTrue(saved.allSatisfy { $0.lastCheck?.ok == true && $0.setID == "GOG-030" })
        XCTAssertEqual(saved[1].games[0].files.map(\.path), ["Big Game/setup_big-2.bin"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("GOG_030_1/Big Game/setup_big.exe").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("GOG_030_2/Big Game/setup_big-2.bin").path))
        let readme = try String(contentsOf: out.appendingPathComponent("GOG_030_2/_archive/README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("disc 2 of 2"))
    }

    private func waitFor(seconds: Double = 15, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
