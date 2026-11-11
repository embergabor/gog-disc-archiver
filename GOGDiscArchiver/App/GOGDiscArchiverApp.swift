import SwiftUI

@main
struct GOGDiscArchiverApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("GOG Disc Archiver", id: "main") {
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
