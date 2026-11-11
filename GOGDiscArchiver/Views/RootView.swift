import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Detail()
        }
        .background(Theme.window)
        .alert("GOG Disc Archiver", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .sheet(isPresented: Binding(get: { model.coverRequest != nil }, set: { if !$0 { model.coverRequest = nil } })) {
            CoverPrintView(source: model.coverRequest ?? .catalogue([]))
                .environment(model)
        }
        .onChange(of: model.drive.state) { _, state in
            if model.job == nil, state.blank, let media = state.media, media != model.draft.media {
                model.selectMedia(media)
            }
        }
    }
}

/// The content column. Kept as one view so the split view itself never sits inside an if/else.
private struct Detail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let session = model.session {
                if let job = session.job, job.isRunning {
                    BurnView(job: job)
                } else if session.job == nil || session.waitingForNextDisc {
                    SetView(session: session)
                } else if let job = session.job {
                    ResultView(job: job)
                }
            } else {
                switch model.screen ?? .newDisc {
                case .newDisc: NewDiscView()
                case .archive: ArchiveView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var opening: SavedList?
    @State private var deleting: SavedList?

    /// Opens a saved list, asking first when New disc holds games that would be lost.
    private func open(_ list: SavedList) {
        let unsaved = !model.draft.games.isEmpty && model.draft.listID != list.id
        if unsaved { opening = list } else { model.openList(list) }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.screen) {
            Section("Burn") {
                Label("New disc", systemImage: "plus.circle")
                    .tag(AppModel.Screen.newDisc)
            }
            if !model.savedLists.isEmpty {
                Section("Saved lists") {
                    ForEach(model.savedLists) { list in
                        SavedListRow(list: list, current: model.draft.listID == list.id)
                            .contentShape(Rectangle())
                            .onTapGesture { open(list) }
                            .contextMenu {
                                Button("Open") { open(list) }
                                Button("Delete…", role: .destructive) { deleting = list }
                            }
                    }
                }
            }
            Section("Archive") {
                Label("All discs", systemImage: "opticaldisc")
                    .badge(model.discs.count)
                    .tag(AppModel.Screen.archive)
            }
        }
        .confirmationDialog("Replace the games on New disc?", isPresented: Binding(get: { opening != nil }, set: { if !$0 { opening = nil } })) {
            Button("Open \u{201C}\(opening?.name ?? "")\u{201D}") { if let list = opening { model.openList(list) } }
        } message: {
            Text("New disc already has games that aren't saved in this list. Save them first with Save list… if you want to keep them.")
        }
        .confirmationDialog("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete list", role: .destructive) { if let list = deleting { model.deleteList(list) } }
        } message: {
            Text("Only the saved list is removed. The game folders stay where they are.")
        }
        .listStyle(.sidebar)
        .disabled(model.job?.isRunning == true)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Catalogue: " + abbreviate(model.paths.catalogue.path))
                if Features.recovery {
                    Text("Recovery data: " + abbreviate(model.paths.sets.path))
                }
                if Features.recovery && !model.par2Available {
                    Text("par2 not installed: no recovery data")
                        .foregroundStyle(Tone.warn.foreground)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct SavedListRow: View {
    var list: SavedList
    var current: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: list.burnedAt == nil ? "list.bullet.rectangle" : "checkmark.circle")
                .foregroundStyle(current ? Theme.ink : Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(list.name)
                    .lineLimit(1)
                    .fontWeight(current ? .semibold : .regular)
                Text(list.burnedAt.map { "Burned \(DateText.day($0))" } ?? list.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
        .help(list.burnedAt == nil ? "Open this list on New disc" : "Burned \(DateText.day(list.burnedAt!)) · open it again to burn another copy")
    }
}
