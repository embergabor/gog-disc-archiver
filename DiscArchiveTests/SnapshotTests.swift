import SwiftUI
import XCTest
@testable import DiscArchive

/// Renders screens to PNG for a visual check without driving the app.
/// Runs only when SNAPSHOT_DIR is set (xcodebuild: TEST_RUNNER_SNAPSHOT_DIR=/some/folder).
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderScreens() async throws {
        guard let out = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { throw XCTSkip("SNAPSHOT_DIR not set") }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let model = AppModel()
        model.draft.id = "GOG-014"
        model.draft.games = [
            GameFolder(url: URL(fileURLWithPath: "/g/Disco Elysium - The Final Cut"), files: (1...6).map { SourceFile(relativePath: "setup_disco-\($0).bin", size: 2_460_000_000) }),
            GameFolder(url: URL(fileURLWithPath: "/g/Baldur's Gate II Enhanced Edition"), files: [SourceFile(relativePath: "setup_bg2.exe", size: 3_100_000_000), SourceFile(relativePath: "bg2.pkg", size: 1_000)]),
            GameFolder(url: URL(fileURLWithPath: "/g/Fallout 2"), files: [SourceFile(relativePath: "setup_fallout2.exe", size: 600_000_000)]),
        ]

        try render(NewDiscView().environment(model), size: CGSize(width: 1060, height: 760), to: folder.appendingPathComponent("new-disc.png"))

        let bins = (1...13).map { SourceFile(relativePath: "setup_the_witcher_3_4.04-\($0).bin", size: 3_970_000_000) }
        model.draft.games.insert(GameFolder(url: URL(fileURLWithPath: "/g/The Witcher 3 Next Gen"),
                                            files: [SourceFile(relativePath: "setup_the_witcher_3_4.04.exe", size: 100_000_000)] + bins), at: 0)
        try render(NewDiscView().environment(model), size: CGSize(width: 1060, height: 1000), to: folder.appendingPathComponent("new-disc-set.png"))
        if case .success(let plan) = model.draftPlan {
            let session = BurnSession(discs: plan, media: .bd25, speed: 4, recoveryPercent: 0)
            try render(SetView(session: session).environment(model), size: CGSize(width: 1060, height: 760), to: folder.appendingPathComponent("set.png"))
        }

        let plan = BurnPlan(id: "GOG-014", media: .bd25, speed: 4, recoveryPercent: 5, games: model.draft.games)
        let job = BurnJob(plan: plan, par2Available: true)
        try render(BurnView(job: job).environment(model), size: CGSize(width: 1060, height: 760), to: folder.appendingPathComponent("burning.png"))

        var record = DiscRecord.sample(id: "GOG-014")
        record.checks = [CheckRecord(date: Date(), filesTotal: 9, bad: [])]
        try render(VStack(alignment: .leading, spacing: 18) { DiscFacts(record: record) }.padding(24).frame(width: 700).background(Theme.window),
                   size: CGSize(width: 700, height: 360), to: folder.appendingPathComponent("facts.png"))
    }

    /// Hosts the view in an off-screen window so AppKit-backed parts (scroll views, pickers) draw too.
    private func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Theme.window))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("could not render \(url.lastPathComponent)")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}
