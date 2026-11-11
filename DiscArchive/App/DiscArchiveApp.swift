import SwiftUI

@main
struct DiscArchiveApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Disc Archive", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
