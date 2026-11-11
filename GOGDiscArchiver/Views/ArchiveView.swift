import SwiftUI

struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Find a game on disc…", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.controlBorder))
                .padding(12)
                Divider().overlay(Theme.divider)
                if filtered.isEmpty {
                    Text(model.discs.isEmpty ? "No discs yet." : "No disc has \u{201C}\(search)\u{201D}.")
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, selection: $model.selectedDisc) { disc in
                        DiscRow(disc: disc, highlight: search)
                            .tag(disc.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 340)
            .background(Theme.list)
            Divider().overlay(Theme.divider)
            Group {
                if let disc = model.disc(model.selectedDisc) {
                    DiscDetail(disc: disc)
                } else {
                    Text("Select a disc")
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("All discs")
        .navigationSubtitle("\(model.discs.count) discs · \(ByteText.gb(model.discs.reduce(0) { $0 + $1.gameBytes })) · \(model.dueCount) need a check")
        .toolbar {
            ToolbarItem(placement: .status) { DriveBadge() }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.coverRequest = .catalogue(model.selectedDisc.map { [$0] } ?? [])
                } label: {
                    Label("Print covers…", systemImage: "printer")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(model.discs.isEmpty)
            }
        }
        .onAppear {
            if model.selectedDisc == nil { model.selectedDisc = filtered.first?.id }
        }
    }

    private var filtered: [DiscRecord] {
        let sorted = model.discs.sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sorted }
        return sorted.filter { disc in
            disc.label.localizedCaseInsensitiveContains(q) || disc.games.contains { $0.folder.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q) || ($0.edition ?? "").localizedCaseInsensitiveContains(q) }
        }
    }
}

private struct DiscRow: View {
    var disc: DiscRecord
    var highlight: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(disc.label).font(Theme.mono(13))
                Text("\(disc.media.label) · \(DateText.day(disc.burnedAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                StatusPill(text: disc.health().label, tone: disc.health().tone)
            }
            Text(games)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    private var games: String {
        let names = disc.games.map(\.title)
        let q = highlight.trimmingCharacters(in: .whitespaces)
        let ordered = q.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(q) } + names.filter { !$0.localizedCaseInsensitiveContains(q) }
        return ordered.joined(separator: ", ")
    }
}

private struct DiscDetail: View {
    @Environment(AppModel.self) private var model
    var disc: DiscRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Text(disc.label).font(Theme.mono(28)).tracking(2)
                    StatusPill(text: disc.health().label, tone: disc.health().tone)
                }
                Text("\(disc.media.longName) · burned \(DateText.day(disc.burnedAt)) · \(ByteText.gb(disc.gameBytes))")
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, -10)

                checkCard

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Contents").font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text("\(disc.games.count) games · \(disc.games.reduce(0) { $0 + $1.files.count }) files")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    ForEach(disc.games) { game in
                        Divider().overlay(Theme.rowDivider)
                        HStack(spacing: 12) {
                            BoxArt(image: model.cachedPortrait(game.info), width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.title).font(.system(size: 13, weight: .semibold))
                                Text(([game.releaseText, game.info?.byline].compactMap { $0 }.filter { !$0.isEmpty } + game.platforms + [ByteText.files(game.files.count)]).joined(separator: " · "))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            if let bad = badCount(game), bad > 0 {
                                StatusPill(text: bad == 1 ? "1 file damaged" : "\(bad) files damaged", tone: .bad)
                            }
                            Text(ByteText.gb(game.bytes)).monospacedDigit().foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 20)
                        .frame(minHeight: 52)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardBorder))

                DiscFacts(record: disc)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }

    private func badCount(_ game: GameRecord) -> Int? {
        guard let bad = disc.lastCheck?.bad else { return nil }
        return bad.filter { $0.hasPrefix(game.folder + "/") }.count
    }

    @ViewBuilder private var checkCard: some View {
        let job = model.check?.record.id == disc.id ? model.check : nil
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(cardTitle(job)).font(.system(size: 15, weight: .bold))
                Spacer()
            }
            if let job, job.isRunning {
                if job.waitingForDisc {
                    Text("Insert \(disc.label) (volume \(disc.volumeName)). The check starts as soon as it appears in the Finder.")
                        .foregroundStyle(Theme.muted)
                } else {
                    ProgressView(value: job.fraction).tint(Theme.ink)
                    Text("Reading every file back · \(Int(job.fraction * 100))%")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                Button("Stop") { job.cancel() }.buttonStyle(PillButtonStyle())
            } else {
                Text(summary(job))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let bad = disc.lastCheck?.bad, !bad.isEmpty {
                    ForEach(bad.prefix(8), id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
                }
                Button("Check disc") { model.startCheck(disc) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
    }

    private func cardTitle(_ job: CheckJob?) -> String {
        if let job, job.isRunning { return "Checking \(disc.label)" }
        if let last = disc.lastCheck { return "Last read · \(DateText.day(last.date))" }
        return "Never read back"
    }

    private func summary(_ job: CheckJob?) -> String {
        if let error = job?.error { return error }
        guard let last = disc.lastCheck else { return "Insert the disc and check it to make sure every file still reads." }
        if last.ok {
            return "All \(last.filesTotal) files matched their checksums."
        }
        let repair = disc.recoveryFiles.isEmpty ? "" : " The recovery data on the disc may be able to rebuild them."
        return "\(last.filesOK) of \(last.filesTotal) files matched. \(last.bad.count) could not be read or did not match.\(repair)"
    }
}
