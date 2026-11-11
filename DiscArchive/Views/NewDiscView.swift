import SwiftUI

struct NewDiscView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let pending = model.pending {
                    PendingBanner(pending: pending)
                }
                header
                SpaceCard()
                HStack(alignment: .top, spacing: 18) {
                    contents
                    SafetyCard()
                        .frame(width: 320)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .navigationTitle("New disc")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .status) {
                DriveBadge()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.startBurn()
                } label: {
                    Label(burnTitle, systemImage: "flame")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(model.burnBlocker != nil)
                .help(model.burnBlocker ?? "Burn \(model.draft.id)")
            }
        }
    }

    private var plan: [PlannedDisc] { (try? model.draftPlan.get()) ?? [] }

    private var burnTitle: String { plan.count > 1 ? "Burn \(plan.count) discs" : "Burn disc" }

    private var subtitle: String {
        let ids = DiscPlanner.baseIDs(plan)
        let what = ids.count > 1 ? "\(ids.first!) to \(ids.last!)" : model.draft.id
        return "\(what) · \(plan.count > 1 ? "\(plan.count) discs" : "1 disc") · not burned yet"
    }

    private var volumeLine: String {
        let ids = DiscPlanner.baseIDs(plan)
        let lead = ids.count > 1 ? "Disc IDs \(ids.joined(separator: ", "))" : "Volume name \(plan.first?.volumeName ?? DiscID.volumeName(for: model.draft.id))"
        return lead + " · UDF, readable on Mac, Windows and Linux"
    }

    /// "GOG-014 · 5 discs" or "GOG-015" per game, shown when the games need more than one disc.
    private var tags: [URL: String] {
        guard plan.count > 1 else { return [:] }
        var out: [URL: String] = [:]
        for disc in plan {
            for game in disc.games {
                if let setID = disc.setID, let count = disc.partCount {
                    out[game.url] = "\(setID) · \(count) discs"
                } else {
                    out[game.url] = disc.id
                }
            }
        }
        return out
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("First disc ID")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                TextField("GOG-014", text: $model.draft.id)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(28, .bold))
                    .tracking(2)
                    .frame(maxWidth: 260)
                Text(volumeLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 16)
            PillPicker(options: Media.allCases.map { ($0, $0.label) },
                       selection: Binding(get: { model.draft.media }, set: { model.selectMedia($0) }))
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Contents").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("\(model.draft.games.count) games · \(model.draft.fileCount) files")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider().overlay(Theme.rowDivider)
            ForEach(model.draft.games) { game in
                GameRow(game: game, thumbnail: model.thumbnails[game.url], tag: tags[game.url],
                        edition: Binding(get: { game.edition ?? "" }, set: { model.setEdition($0, for: game) })) { model.remove(game) }
                Divider().overlay(Theme.rowDivider)
            }
            dropZone
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardBorder))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .dropDestination(for: URL.self) { urls, _ in
            model.addFolders(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            Text("Drop game folders here")
                .foregroundStyle(Theme.secondary)
            Button {
                model.chooseFolders()
            } label: {
                Label("Add folder…", systemImage: "plus")
            }
            .buttonStyle(PillButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(dropTargeted ? Theme.tint : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Theme.ink : Theme.controlBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }
}

private struct GameRow: View {
    var game: GameFolder
    var thumbnail: NSImage?
    var tag: String?
    @Binding var edition: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BoxArt(image: thumbnail, width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            TextField("Edition", text: $edition, prompt: Text("Edition, e.g. Next Gen"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 150)
                .help("Your own label for this release, shown in the archive and on covers")
            if let tag {
                Text(tag)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.tint, in: Capsule())
            }
            Text(ByteText.gb(game.totalBytes))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .accessibilityLabel("Remove \(game.name)")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(minHeight: 52)
    }

    private var detail: String {
        var parts: [String] = []
        if let byline = game.info?.byline, !byline.isEmpty { parts.append(byline) }
        if let v = game.version { parts.append("v" + v.replacingOccurrences(of: "_", with: " ")) }
        parts += game.platforms
        parts.append(ByteText.files(game.files.count))
        if game.lookedUp && game.info == nil { parts.append("not found on GOG") }
        if game.title != game.name { parts.append("folder \u{201C}\(game.name)\u{201D}") }
        return parts.joined(separator: " · ")
    }
}

private struct SpaceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let draft = model.draft
        let percent = draft.effectiveRecovery(par2Available: model.par2Available)
        let plan = (try? model.draftPlan.get()) ?? []
        let cap = draft.media.capacity
        let games = draft.gameBytes
        let recovery = plan.reduce(Int64(0)) { $0 + DiscPlanner.recoveryBytes($1.dataBytes, games: $1.games.count, percent: percent) }

        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.count > 1 ? "\(plan.count) discs" : "Space").font(.system(size: 15, weight: .bold))
                Spacer()
                if plan.count > 1 {
                    Text("\(plan.count) × \(draft.media.label) · \(ByteText.gb(games + recovery)) in all")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                } else {
                    Text(ByteText.gb(games + recovery)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    + Text(" of \(ByteText.gb(cap))").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            if plan.count > 1 {
                ForEach(plan) { disc in
                    let rec = DiscPlanner.recoveryBytes(disc.dataBytes, games: disc.games.count, percent: percent)
                    Divider().overlay(Theme.rowDivider)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(disc.label).font(Theme.mono(13)).frame(minWidth: 110, alignment: .leading)
                        Text(disc.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(2)
                        Spacer()
                        Text("\(ByteText.gb(disc.dataBytes + rec)) of \(ByteText.gb(cap))")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary)
                    }
                    SpaceBar(games: disc.dataBytes, recovery: rec, capacity: cap, height: 10)
                }
            } else {
                SpaceBar(games: games, recovery: recovery, capacity: cap, height: 14)
            }
            HStack(spacing: 18) {
                legend(Theme.accent, "Games \(ByteText.gb(games))")
                legend(Theme.accent.opacity(0.45), model.par2Available ? "Recovery data \(ByteText.gb(recovery))" : "Recovery data off (par2 not installed)")
                if plan.count <= 1 {
                    legend(Theme.track, "Free \(ByteText.gb(max(0, draft.media.usable - games - recovery)))")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            if plan.count > 1 {
                Label("A game too big for one disc gets discs of its own under one ID (1/5 … 5/5), and its last disc is never topped up with other games. Files are never cut in half. Each disc has its own checksums and recovery data. To install a split game, copy its folder from every disc into one folder.",
                      systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.window, in: RoundedRectangle(cornerRadius: 10))
            }
            if case .failure(let error) = model.draftPlan, error != .noGames {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tone.bad.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tone.bad.background, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color)
                .frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.controlBorder))
            Text(text)
        }
    }
}

private struct SafetyCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card {
            Text("Safety").font(.system(size: 15, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Recovery data").font(.system(size: 13, weight: .semibold))
                PillPicker(options: [(0, "Off"), (5, "5%"), (10, "10%")], selection: $model.draft.recoveryPercent)
                    .disabled(!model.par2Available)
                Text(model.par2Available
                     ? "Repairs files if part of the disc goes bad later. 5% survives a few scratched or faded spots."
                     : "Needs par2. Install it with Homebrew (brew install par2), then reopen the app.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            check("Checksums on the disc", "SHA-256 for every file, always on")
            check("Read back after burning", "Every file is re-read from the disc and compared, always on")
            check("Burns straight from the folders", "No disc image, so no extra space beyond the recovery data")
            HStack {
                Text("Burn speed").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Burn speed", selection: $model.draft.speed) {
                    ForEach(model.draft.media.speeds, id: \.self) { speed in
                        Text(speed == model.draft.media.recommendedSpeed ? "\(speed)× (recommended)" : "\(speed)×").tag(speed)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func check(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DriveBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label(model.driveSummary, systemImage: "opticaldiscdrive")
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .padding(.horizontal, 10)
    }
}

/// Portrait box art at 2:3, or a folder symbol while there is none.
struct BoxArt: View {
    var image: NSImage?
    var width: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "folder").foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct SpaceBar: View {
    var games: Int64
    var recovery: Int64
    var capacity: Int64
    var height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let g = min(1, Double(games) / Double(capacity))
            HStack(spacing: 0) {
                Rectangle().fill(Theme.accent).frame(width: w * g)
                Rectangle().fill(Theme.accent.opacity(0.45)).frame(width: w * max(0, min(1 - g, Double(recovery) / Double(capacity))))
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Theme.track)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct PendingBanner: View {
    @Environment(AppModel.self) private var model
    var pending: PendingSet
    @State private var confirmDiscard = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldisc")
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfinished set").font(.system(size: 13, weight: .semibold))
                Text(pending.summary + " · " + pending.discs.flatMap(\.games).map(\.title).uniqued().joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button("Discard…") { confirmDiscard = true }
                .buttonStyle(PillButtonStyle())
            Button("Continue") { model.continuePending() }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(14)
        .background(Theme.tint, in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog("Discard the rest of this set?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { model.discardPending() }
        } message: {
            Text("The discs already burned stay in the archive. The ones not burned yet are forgotten.")
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
