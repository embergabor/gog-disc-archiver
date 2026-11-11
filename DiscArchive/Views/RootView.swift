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
        .alert("Disc Archive", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
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

    var body: some View {
        @Bindable var model = model
        List(selection: $model.screen) {
            Section("Burn") {
                Label("New disc", systemImage: "plus.circle")
                    .tag(AppModel.Screen.newDisc)
            }
            Section("Archive") {
                Label("All discs", systemImage: "opticaldisc")
                    .badge(model.discs.count)
                    .tag(AppModel.Screen.archive)
            }
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
