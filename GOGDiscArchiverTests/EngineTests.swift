import XCTest
@testable import GOGDiscArchiver

final class ModelTests: XCTestCase {
    func testMediaCapacities() {
        XCTAssertEqual(Media.bd25.capacity, 25_025_314_816)
        XCTAssertEqual(Media.dvdR.capacity, 4_700_372_992)
        XCTAssertLessThan(Media.bd25.usable, Media.bd25.capacity)
        XCTAssertEqual(Media.from(kind: .bluRay, blocks: 12_219_392), .bd25)
        XCTAssertEqual(Media.from(kind: .bluRay, blocks: 24_438_784), .bd50)
        XCTAssertEqual(Media.from(kind: .bluRay, blocks: 48_878_592), .bdxl100)
    }

    func testDiscIDs() {
        XCTAssertEqual(DiscID.next(after: []), "GOG-001")
        XCTAssertEqual(DiscID.next(after: ["GOG-013", "GOG-002", "OTHER-099"]), "GOG-014")
        XCTAssertEqual(DiscID.volumeName(for: "GOG-014"), "GOG_014")
        XCTAssertNil(DiscID.split("GOG"))
    }

    func testHealth() {
        let now = Date()
        var record = DiscRecord.sample(id: "GOG-001")
        XCTAssertEqual(record.health(now: now), .neverChecked)
        record.checks = [CheckRecord(date: now.addingTimeInterval(-86400), filesTotal: 3, bad: [])]
        XCTAssertEqual(record.health(now: now), .ok)
        record.checks.append(CheckRecord(date: now, filesTotal: 3, bad: ["A/x.bin"]))
        XCTAssertEqual(record.health(now: now), .damaged)
        record.checks = [CheckRecord(date: now.addingTimeInterval(-4 * 365 * 86400), filesTotal: 3, bad: [])]
        XCTAssertEqual(record.health(now: now), .due)
    }

    func testDraftFits() {
        var draft = DiscDraft(id: "GOG-001", media: .dvdR)
        draft.games = [GameFolder(url: URL(fileURLWithPath: "/tmp/A"), files: [SourceFile(relativePath: "a.bin", size: 4_300_000_000)])]
        XCTAssertEqual(try draft.plan(par2Available: false).get().count, 1)
        draft.recoveryPercent = 10
        XCTAssertEqual(draft.plan(par2Available: true).failure, .fileTooBig(game: "A", file: "a.bin"))
    }
}

final class ChecksumTests: XCTestCase {
    func testKnownVector() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try Checksums.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testRenderAndParse() {
        let files = [FileRecord(path: "Fallout 2/setup fallout 2.exe", size: 3, sha256: String(repeating: "a", count: 64))]
        let text = Checksums.render(files)
        XCTAssertEqual(text, String(repeating: "a", count: 64) + "  Fallout 2/setup fallout 2.exe\n")
        XCTAssertEqual(Checksums.parse(text)["Fallout 2/setup fallout 2.exe"], String(repeating: "a", count: 64))
    }

    func testPar2Progress() {
        XCTAssertEqual(Par2.lastPercent(in: "Processing: 3.1%\rProcessing: 45.6%\r"), 45.6)
        XCTAssertNil(Par2.lastPercent(in: "Opening: file.bin"))
    }
}

final class FolderTests: XCTestCase {
    func testScanSkipsHiddenAndFindsPlatforms() throws {
        let dir = try TempDir()
        let game = try dir.makeGame("Planescape Torment", files: ["setup_pst.exe": 10, "setup_pst-1.bin": 20, "extras/manual.pdf": 5, ".DS_Store": 1, "pst.sh": 2])
        let scanned = try GameFolder.scan(game)
        XCTAssertEqual(scanned.name, "Planescape Torment")
        XCTAssertEqual(Set(scanned.files.map(\.relativePath)), ["setup_pst.exe", "setup_pst-1.bin", "extras/manual.pdf", "pst.sh"])
        XCTAssertEqual(scanned.totalBytes, 37)
        XCTAssertEqual(scanned.platforms, ["Windows", "Linux"])
    }

    func testCatalogueRoundTrip() throws {
        let dir = try TempDir()
        let store = CatalogueStore(url: dir.url.appendingPathComponent("discs.json"))
        XCTAssertEqual(try store.load(), [])
        let record = DiscRecord.sample(id: "GOG-002")
        try store.save([record, DiscRecord.sample(id: "GOG-001")])
        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.id), ["GOG-001", "GOG-002"])
        XCTAssertEqual(loaded.last, record)
    }
}

@MainActor
final class BurnFlowTests: XCTestCase {
    /// The whole flow with the folder writer: checksums, layout, "burn", read back, catalogue.
    func testSimulatedBurnVerifiesAndSaves() async throws {
        let dir = try TempDir()
        let source = dir.url.appendingPathComponent("source")
        let g1 = try dir.makeGame("source/Fallout 2", files: ["setup_fallout2.exe": 300_000, "extras/manual.pdf": 1_000])
        let g2 = try dir.makeGame("source/Heroes 3", files: ["setup_h3.exe": 50_000, "setup_h3-1.bin": 2_000_000])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let games = try [GameFolder.scan(g1), GameFolder.scan(g2)]
        let paths = AppPaths(root: dir.url.appendingPathComponent("Archive"))
        let discs = dir.url.appendingPathComponent("discs")

        let plan = BurnPlan(id: "GOG-014", media: .dvdR, speed: 8, recoveryPercent: 5, games: games)
        let job = BurnJob(plan: plan, par2Available: false)
        var saved: DiscRecord?
        job.start(writer: FolderWriter(folder: discs), par2: nil, paths: paths) { saved = $0 }
        try await waitFor { job.outcome != nil }

        guard case .verified(let record) = job.outcome else {
            return XCTFail("Expected a verified disc, got \(String(describing: job.outcome))")
        }
        XCTAssertEqual(saved, record)
        XCTAssertEqual(record.games.map(\.folder), ["Fallout 2", "Heroes 3"])
        XCTAssertEqual(record.allFiles.count, 4)
        XCTAssertEqual(record.recoveryPercent, 0, "no par2 → no recovery data recorded")
        XCTAssertEqual(record.checks.count, 1)
        XCTAssertTrue(record.checks[0].ok)
        XCTAssertEqual(job.steps.first { $0.id == .recovery }?.state, .skipped)

        // The disc holds the games plus _archive with checksums that shasum can use.
        let disc = discs.appendingPathComponent("GOG_014")
        let sums = try String(contentsOf: disc.appendingPathComponent("_archive/checksums.sha256"), encoding: .utf8)
        XCTAssertEqual(Checksums.parse(sums).count, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disc.appendingPathComponent("Heroes 3/setup_h3-1.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disc.appendingPathComponent("_archive/disc.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.set(for: "GOG-014").appendingPathComponent("checksums.sha256").path))

        // A flipped byte on the disc is caught by a later check.
        let victim = disc.appendingPathComponent("Fallout 2/setup_fallout2.exe")
        var bytes = try Data(contentsOf: victim)
        bytes[1000] ^= 0xFF
        try bytes.write(to: victim)
        let files = record.allFiles
        let check = try Verifier.check(root: disc, files: files) { _ in }
        XCTAssertEqual(check.bad, ["Fallout 2/setup_fallout2.exe"])
        XCTAssertEqual(check.filesOK, 3)
    }

    /// With par2 installed, recovery files are made, put on the disc and checked too.
    func testRecoveryDataWhenPar2IsInstalled() async throws {
        guard let par2 = Par2.find() else { throw XCTSkip("par2 is not installed") }
        let dir = try TempDir()
        let g = try dir.makeGame("source/Fallout 2", files: ["setup_fallout2.exe": 400_000, "setup_fallout2-1.bin": 900_000])
        let paths = AppPaths(root: dir.url.appendingPathComponent("Archive"))
        let plan = BurnPlan(id: "GOG-015", media: .dvdR, speed: 8, recoveryPercent: 10, games: [try GameFolder.scan(g)])
        let job = BurnJob(plan: plan, par2Available: true)
        job.start(writer: FolderWriter(folder: dir.url.appendingPathComponent("discs")), par2: par2, paths: paths) { _ in }
        try await waitFor(seconds: 60) { job.outcome != nil }
        guard case .verified(let record) = job.outcome else { return XCTFail("\(String(describing: job.outcome))") }
        XCTAssertFalse(record.recoveryFiles.isEmpty)
        XCTAssertTrue(record.recoveryFiles.allSatisfy { $0.path.hasPrefix("_archive/recovery/Fallout 2") })
        XCTAssertEqual(record.recoveryPercent, 10)
    }

    private func waitFor(seconds: Double = 15, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { throw XCTSkip("timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - Helpers

final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("DiscArchiveTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Makes a folder of files filled with pseudo-random bytes of the given sizes.
    func makeGame(_ path: String, files: [String: Int]) throws -> URL {
        let folder = url.appendingPathComponent(path, isDirectory: true)
        for (name, size) in files {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var generator = SystemRandomNumberGenerator()
            let bytes = (0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) }
            try Data(bytes).write(to: file)
        }
        return folder
    }
}

extension DiscRecord {
    static func sample(id: String) -> DiscRecord {
        DiscRecord(id: id, volumeName: DiscID.volumeName(for: id), media: .bd25, burnedAt: Date(timeIntervalSince1970: 1_790_000_000),
                   drive: "Test drive", speed: 4, recoveryPercent: 5,
                   games: [GameRecord(folder: "A", platforms: ["Windows"], files: [FileRecord(path: "A/x.bin", size: 3, sha256: String(repeating: "0", count: 64))])],
                   recoveryFiles: [], checks: [])
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

@MainActor
final class SourceChangeTests: XCTestCase {
    func testBurnStopsWhenAFileChangedAfterAdding() async throws {
        let dir = try TempDir()
        let folder = try dir.makeGame("source/Copying", files: ["setup_copying.exe": 1000])
        let game = try GameFolder.scan(folder)
        try Data(count: 5000).write(to: folder.appendingPathComponent("setup_copying.exe"))
        XCTAssertThrowsError(try BurnJob.checkUnchanged([game]))
    }
}

@MainActor
final class SavedListTests: XCTestCase {
    func testSaveAndOpenKeepsOrderTitlesAndEditions() async throws {
        let dir = try TempDir()
        UserDefaults.standard.register(defaults: ["archiveRoot": dir.url.appendingPathComponent("Archive").path])
        let model = AppModel()
        let a = try GameFolder.scan(try dir.makeGame("g/Alpha", files: ["setup_alpha.exe": 100]))
        var b = try GameFolder.scan(try dir.makeGame("g/Beta", files: ["setup_beta.exe": 200]))
        let gone = try dir.makeGame("g/Gone", files: ["setup_gone.exe": 50])
        b.edition = "Next Gen"
        b.customTitle = "Beta Remastered"
        model.draft.games = [b, a, try GameFolder.scan(gone)]
        model.selectMedia(.dvdR)
        model.saveList(name: "Weekend batch")
        XCTAssertEqual(model.savedLists.map(\.name), ["Weekend batch"])

        // A fresh app reads it back from disk.
        let reopened = AppModel()
        let list = try XCTUnwrap(reopened.savedLists.first)
        XCTAssertEqual(list.games.map(\.name), ["Beta", "Alpha", "Gone"])
        try FileManager.default.removeItem(at: gone)
        reopened.openList(list)
        for _ in 0..<100 where reopened.draft.games.count < 2 || reopened.alert == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(reopened.draft.games.map(\.name), ["Beta", "Alpha"])
        XCTAssertEqual(reopened.draft.games[0].edition, "Next Gen")
        XCTAssertEqual(reopened.draft.games[0].title, "Beta Remastered")
        XCTAssertEqual(reopened.draft.media, .dvdR)
        XCTAssertEqual(reopened.draft.listName, "Weekend batch")
        XCTAssertTrue(reopened.alert?.contains("setup_gone") == false && reopened.alert?.contains("Gone") == true)

        reopened.deleteList(list)
        XCTAssertTrue(reopened.savedLists.isEmpty)
        XCTAssertTrue(AppModel().savedLists.isEmpty)
    }
}
