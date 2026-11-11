import AppKit
import SwiftUI

/// Pick discs and a case type, preview the A4 sheet, then save a PDF or open it in Preview to print.
struct CoverPrintView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initial: [String]

    @State private var kind: CoverKind = .bluRay
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
        .task { if selected.isEmpty { selected = Set(initial) } }
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
                                Text(option == .jewel ? "Front with box art and disc ID, 120 × 120 mm. Two per sheet."
                                                      : "Box art and ID on the front, ID on the spine, games and disc details on the back.")
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Discs").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.discs.sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }) { disc in
                            Toggle(isOn: Binding(get: { selected.contains(disc.id) },
                                                 set: { on in if on { selected.insert(disc.id) } else { selected.remove(disc.id) } })) {
                                HStack(spacing: 8) {
                                    Text(disc.id).font(Theme.mono(12))
                                    Text(disc.games.map(\.title).joined(separator: ", "))
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

    private var ordered: [CoverDisc] {
        selected.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { covers[$0] }
    }

    private var pages: [[CoverDisc]] { CoverBuilder.pages(kind: kind, discs: ordered) }
    private var sheetCount: Int { pages.count }
    private var ready: Bool { !loading && !ordered.isEmpty && ordered.count == selected.count }

    private func load() async {
        loading = true
        defer { loading = false }
        for id in selected.sorted() where covers[id] == nil {
            guard let record = model.disc(id) else { continue }
            let updated = await CoverBuilder.withInfo(record, service: model.infoService)
            if updated != record { model.upsert(updated) }
            covers[id] = await CoverBuilder.disc(updated, service: model.infoService)
        }
    }

    private var fileName: String {
        let ids = ordered.map(\.id)
        let name = ids.count <= 3 ? ids.joined(separator: " ") : "\(ids.first!) to \(ids.last!)"
        return "\(name) \(kind == .jewel ? "jewel" : "bluray") cover.pdf"
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
