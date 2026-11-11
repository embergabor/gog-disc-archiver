import AppKit
import SwiftUI

/// Pick discs and a case type, preview the A4 sheet, then save a PDF or open it in Preview to print.
struct CoverPrintView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var source: CoverSource

    @AppStorage(CoverTheme.kindKey) private var kind: CoverKind = .bluRay
    @AppStorage(CoverTheme.inkSaverKey) private var inkSaver = false
    @AppStorage(CoverTheme.brightenKey) private var brighten = true
    @State private var selected: Set<String> = []
    @State private var covers: [String: CoverDisc] = [:]
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                options
                    .frame(width: 300)
                    .padding(20)
                Divider()
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
                    .background(Theme.track)
            }
            Divider()
            HStack(spacing: 10) {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Finding game info and cover art…").foregroundStyle(Theme.secondary)
                } else if let error {
                    Text(error).foregroundStyle(Tone.bad.foreground)
                } else {
                    Text("\(sheetCount) A4 \(sheetCount == 1 ? "sheet" : "sheets") · print at 100%, not \u{201C}Scale to fit\u{201D}")
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillButtonStyle())
                Button("Save PDF…") { save() }.buttonStyle(PillButtonStyle()).disabled(!ready)
                Button("Open in Preview") { openInPreview() }.buttonStyle(PillButtonStyle(prominent: true)).disabled(!ready)
            }
            .font(.system(size: 12))
            .padding(16)
        }
        .frame(width: 1000, height: 680)
        .background(Theme.window)
        .task { if selected.isEmpty { selected = Set(initialSelection) } }
        .task(id: selected) { await load() }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Print covers").font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Case").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                ForEach(CoverKind.allCases) { option in
                    Button { kind = option } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: kind == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(kind == option ? Theme.ink : Theme.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.system(size: 13, weight: .semibold))
                                Text(option.explanation)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(kind == option ? Theme.tint : Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(kind == option ? Theme.ink : Theme.cardBorder, lineWidth: kind == option ? 1.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Ink saver: white front", isOn: $inkSaver)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .semibold))
                Text("The front turns white with purple text and rings. The spine stays purple.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Brighten box art for print", isOn: $brighten)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 8)
                Text("Lifts dark covers so they don't print as solid ink. Colours are kept; text and purple are unchanged.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Discs").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.id) { disc in
                            Toggle(isOn: Binding(get: { selected.contains(disc.id) },
                                                 set: { on in if on { selected.insert(disc.id) } else { selected.remove(disc.id) } })) {
                                HStack(spacing: 8) {
                                    Text(disc.label).font(Theme.mono(12))
                                    Text(disc.titles)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            let page = kind.pageSize
            let scale = min(geo.size.width / page.width, geo.size.height / page.height)
            Group {
                if let first = pages.first {
                    CoverSheet(kind: kind, discs: first)
                        .environment(\.coverTheme, .purple(inkSaver: inkSaver, brighten: brighten))
                        .allowsHitTesting(false)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: page.width * scale, height: page.height * scale, alignment: .topLeading)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                } else {
                    Text(selected.isEmpty ? "Pick at least one disc." : "Preparing…")
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Data

    private struct Row { var id: String; var label: String; var titles: String }

    private var rows: [Row] {
        switch source {
        case .catalogue:
            return model.discs.sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }
                .map { Row(id: $0.id, label: $0.label, titles: $0.games.map(\.title).joined(separator: ", ")) }
        case .plan(let discs, _, _, _):
            return discs.map { Row(id: $0.id, label: $0.label + " · not burned yet", titles: $0.games.map(\.title).joined(separator: ", ")) }
        }
    }

    private var initialSelection: [String] {
        switch source {
        case .catalogue(let ids): ids
        case .plan(let discs, _, _, _): discs.map(\.id)
        }
    }

    /// Plan order for planned discs (the burn order), ID order for burned ones.
    private func order(_ ids: Set<String>) -> [String] {
        if case .plan(let discs, _, _, _) = source { return discs.map(\.id).filter(ids.contains) }
        return ids.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var ordered: [CoverDisc] {
        order(selected).compactMap { covers[$0] }
    }

    private var pages: [[CoverDisc]] { CoverBuilder.pages(kind: kind, discs: ordered) }
    private var sheetCount: Int { pages.count }
    private var ready: Bool { !loading && !ordered.isEmpty && ordered.count == selected.count }

    private func load() async {
        loading = true
        defer { loading = false }
        for id in order(selected) where covers[id] == nil {
            switch source {
            case .catalogue:
                guard let record = model.disc(id) else { continue }
                let updated = await CoverBuilder.withInfo(record, service: model.infoService)
                if updated != record { model.upsert(updated) }
                covers[id] = await CoverBuilder.disc(updated, service: model.infoService)
            case .plan(let discs, let media, let speed, let recovery):
                guard let planned = discs.first(where: { $0.id == id }) else { continue }
                let record = CoverBuilder.record(for: planned, media: media, speed: speed, recoveryPercent: recovery)
                let filled = await CoverBuilder.withInfo(record, service: model.infoService)
                covers[id] = await CoverBuilder.disc(filled, service: model.infoService)
            }
        }
    }

    private var fileName: String {
        let ids = ordered.map(\.id)
        let name = ids.count <= 3 ? ids.joined(separator: " ") : "\(ids.first!) to \(ids.last!)"
        return "\(name) \(kind.fileWord) cover.pdf"
    }

    private func write(to url: URL) -> Bool {
        do {
            try CoverBuilder.writePDF(kind: kind, discs: ordered, to: url)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if write(to: url) { dismiss() }
    }

    private func openInPreview() {
        let url = model.paths.covers.appendingPathComponent(fileName)
        if write(to: url) {
            NSWorkspace.shared.open(url)
            dismiss()
        }
    }
}
