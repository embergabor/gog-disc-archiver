import SwiftUI
import XCTest
@testable import GOGDiscArchiver

/// README screenshots of the real app window. Runs only with SCREENSHOT_DIR set. Uses the network
/// for cover lookups (cached) and the user's game folders and archive, copied to a temporary folder.
@MainActor
final class ScreenshotTests: XCTestCase {
    func testScreenshots() async throws {
        guard let out = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { throw XCTSkip("SCREENSHOT_DIR not set") }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let games = home.appendingPathComponent("Downloads/GOG")

        // A private copy of the real archive, so nothing the screenshots do touches it.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GOGDiscArchiver-shots-" + UUID().uuidString)
        try FileManager.default.copyItem(at: home.appendingPathComponent("Archive"), to: root)
        UserDefaults.standard.register(defaults: ["archiveRoot": root.path, "archiveDisplayName": "~/Archive"])
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel()
        model.selectMedia(.bd25)
        model.addFolders(["Hollow Knight", "Kingdom Two Crowns", "Limbo", "The Witness", "TUNIC + TUNIC Original Game Soundtrack - GOG",
          "A Short Hike v1.10.1_patched - GoG", "Noita GOG", "Stardew Valley"]
            .map { games.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) })
        for _ in 0..<150 where model.draft.games.isEmpty || model.draft.games.contains(where: { !$0.lookedUp }) || model.thumbnails.count < model.draft.games.count {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.draft.games.isEmpty, "no game folders found")
        guard !model.draft.games.isEmpty else { return }

        let window = makeWindow(model)

        // 1. New disc, with the live cover preview.
        model.screen = .newDisc
        window.title = "New disc"
        try await snap(window, to: folder.appendingPathComponent("new-disc.png"), wait: 3)

        // 2. Enlarged cover preview.
        guard case .success(let plan) = model.draftPlan else { return XCTFail("no plan") }
        var covers: [CoverDisc] = []
        for disc in plan {
            let record = CoverBuilder.record(for: disc, media: model.draft.media, speed: model.draft.speed, recoveryPercent: 0)
            covers.append(await CoverBuilder.disc(record, service: model.infoService))
        }
        UserDefaults.standard.set(CoverKind.bluRay.rawValue, forKey: CoverTheme.kindKey)
        let zoom = NSHostingView(rootView: CoverZoomView(covers: covers, selected: covers[0].id, print: {}).frame(width: 1280, height: 820))
        try await snapView(zoom, size: CGSize(width: 1280, height: 820), to: folder.appendingPathComponent("cover-preview.png"))

        // 3. A printed cover page: the real GOG-001.
        let record = try XCTUnwrap(model.discs.first)
        let cover = await CoverBuilder.disc(record, service: model.infoService)
        let renderer = ImageRenderer(content: CoverSheet(kind: .bluRay, discs: [cover]).environment(\.coverTheme, .purple(inkSaver: false)))
        renderer.scale = 2
        try png(renderer.nsImage!).write(to: folder.appendingPathComponent("covers.png"))

        // 4. Burning, part-way.
        let session = BurnSession(discs: plan, media: .bd25, speed: 4, recoveryPercent: 0)
        let job = BurnJob.preview(plan: BurnPlan(disc: plan[0], media: .bd25, speed: 4, recoveryPercent: 0),
                                  done: [.checksums, .layout], running: .burn, fraction: 0.46, rate: 17_600_000,
                                  minutes: [.checksums: 0.4, .layout: 0, .burn: 9])
        session.showPreview(job)
        model.session = session
        window.title = "Burning \(plan[0].label)"
        window.subtitle = "BD-R 25 · 4×"
        try await snap(window, to: folder.appendingPathComponent("burning.png"), wait: 1)
        model.session = nil

        // 5. The archive, with GOG-001 selected.
        model.screen = .archive
        model.selectedDisc = record.id
        window.title = "All discs"
        try await snap(window, to: folder.appendingPathComponent("archive.png"), wait: 2)
        window.close()
    }

    private func makeWindow(_ model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: RootView().environment(model).frame(width: 1280, height: 820))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        return window
    }

    private func snap(_ window: NSWindow, to url: URL, wait: Double) async throws {
        for _ in 0..<Int(wait * 10) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let frame = window.contentView!.superview!
        let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private func snapView(_ view: NSView, size: CGSize, to url: URL) async throws {
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private func png(_ image: NSImage) -> Data {
        NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}
