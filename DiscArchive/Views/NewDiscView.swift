import SwiftUI

struct NewDiscView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var savingList = false
    @State private var listName = ""
    @State private var confirmClear = false
    /// Where a dragged game would land: before or after a row, or at the end (`url` nil).
    @State private var marker: DropMarker?
    @State private var rowHeights: [URL: CGFloat] = [:]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let pending = model.pending {
                    PendingBanner(pending: pending)
                }
                header
                SpaceCard()
                if !plan.isEmpty {
                    CoverPreviewCard(plan: plan)
                }
                HStack(alignment: .top, spacing: 18) {
                    contents
                    SafetyCard()
                        .frame(width: 320)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .alert(model.draft.listID == nil ? "Save list" : "Update saved list", isPresented: $savingList) {
            TextField("Name", text: $listName)
            Button("Save") { model.saveList(name: listName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps the games in this order with their titles and editions, the disc type and speed, to burn later.")
        }
        .confirmationDialog("Clear New disc?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearDraft() }
        } message: {
            Text(model.draft.listID == nil ? "The games are removed from this screen. Nothing is deleted from your drive." : "The saved list stays under Saved lists.")
        }
        .navigationTitle(model.draft.listName ?? "New disc")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .status) {
                DriveBadge()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    listName = model.suggestedListName
                    savingList = true
                } label: {
                    Label(model.draft.listID == nil ? "Save list…" : "Save list", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(model.draft.games.isEmpty)
                .help("Keep this list, its order, titles and editions, to burn later. It appears under Saved lists.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.printDraftCovers()
                } label: {
                    Label("Print covers…", systemImage: "printer")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(plan.isEmpty)
                .help("Print the covers now, before or while the discs burn")
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
                if !model.draft.games.isEmpty {
                    Button("Clear…") { confirmClear = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider().overlay(Theme.rowDivider)
            ForEach(model.draft.games) { game in
                GameRow(game: game, thumbnail: model.thumbnails[game.url], tag: tags[game.url],
                        edition: Binding(get: { game.edition ?? "" }, set: { model.setEdition($0, for: game) }),
                        setTitle: { model.setTitle($0, for: game) }) { model.remove(game) }
                    .overlay(alignment: marker?.below == true ? .bottom : .top) {
                        if marker?.url == game.url { InsertionLine() }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[game.url] = $0 }
                    .onDrag {
                        model.draggingGame = game.url
                        return NSItemProvider(object: (GameRow.reorderPrefix + game.url.path) as NSString)
                    }
                    .onDrop(of: [.plainText, .fileURL],
                            delegate: RowDrop(target: game.url, height: rowHeights[game.url] ?? 52, model: model, marker: $marker))
                Divider().overlay(Theme.rowDivider)
            }
            dropZone
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .overlay(alignment: .top) {
                    if marker != nil && marker?.url == nil { InsertionLine() }
                }
                .onDrop(of: [.plainText, .fileURL], delegate: RowDrop(target: nil, height: 0, model: model, marker: $marker))
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
    var setTitle: (String) -> Void
    var remove: () -> Void
    @State private var editingTitle = false

    /// Drag payload for reordering rows; plain URLs would look like new folders dropped from the Finder.
    static let reorderPrefix = "discarchive-reorder:"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .help("Drag to change the order: covers on the front and games on the back follow it")
            BoxArt(image: thumbnail, width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(game.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Button { editingTitle = true } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Type the title yourself: it's shown everywhere and used to find the cover")
                    .popover(isPresented: $editingTitle, arrowEdge: .bottom) {
                        TitleEditor(current: game.customTitle ?? game.title, hasCustom: game.customTitle != nil) { text in
                            editingTitle = false
                            setTitle(text)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    if game.lookedUp && game.info == nil {
                        Button("Not found · set title…") { editingTitle = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tone.warn.foreground)
                    } else if !game.lookedUp {
                        ProgressView().controlSize(.mini)
                    }
                }
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
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts: [String] = []
        if let byline = game.info?.byline, !byline.isEmpty { parts.append(byline) }
        if let v = game.version { parts.append("v" + v.replacingOccurrences(of: "_", with: " ")) }
        parts += game.platforms
        parts.append(ByteText.files(game.files.count))
        if game.title != game.name { parts.append("folder \u{201C}\(game.name)\u{201D}") }
        return parts.joined(separator: " · ")
    }
}

private struct SpaceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let draft = model.draft
        let percent = draft.effectiveRecovery(par2Available: model.recoveryEnabled)
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
            if model.optimiseSaving > 0 || model.orderBeforeOptimise != nil {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(Theme.ink)
                    if model.orderBeforeOptimise != nil {
                        Text("Reordered for the fewest discs. Games on each disc keep your order.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Undo") { withAnimation { model.undoOptimise() } }
                            .buttonStyle(PillButtonStyle())
                    } else {
                        let saving = model.optimiseSaving
                        Text("Discs follow your list order. Reordering the list would save \(saving == 1 ? "1 disc" : "\(saving) discs").")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Optimise order") { withAnimation { model.optimiseOrder() } }
                            .buttonStyle(PillButtonStyle(prominent: true))
                            .help("Reorders the games in Contents so they fit on the fewest discs. You can undo it.")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.tint, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 18) {
                legend(Theme.accent, "Games \(ByteText.gb(games))")
                if Features.recovery {
                    legend(Theme.accent.opacity(0.45), model.par2Available ? "Recovery data \(ByteText.gb(recovery))" : "Recovery data off (par2 not installed)")
                }
                if plan.count <= 1 {
                    legend(Theme.track, "Free \(ByteText.gb(max(0, draft.media.usable - games - recovery)))")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            if plan.count > 1 {
                Label("Discs fill in your list order: when the next game doesn't fit, a new disc starts. A game too big for one disc gets discs of its own under one ID (1/5 … 5/5), and its last disc is never topped up with other games. Files are never cut in half. Each disc has its own checksums. To install a split game, copy its folder from every disc into one folder.",
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
            if Features.recovery {
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
            }
            check("Checksums on the disc", "SHA-256 for every file, always on")
            check("Read back after burning", "Every file is re-read from the disc and compared, always on")
            check("Burns straight from the folders", "No disc image, so no extra space is needed")
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

/// The front of every planned disc, live, so a collection disc can be arranged by eye.
private struct CoverPreviewCard: View {
    @Environment(AppModel.self) private var model
    var plan: [PlannedDisc]
    @State private var covers: [String: CoverDisc] = [:]
    @State private var enlarged: String?
    @AppStorage(CoverTheme.inkSaverKey) private var inkSaver = false

    private static let scale: CGFloat = 0.55

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Cover preview").font(.system(size: 15, weight: .bold))
                Text("Blu-ray case: back, spine, front · click to enlarge · drag games in Contents to change the order")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("Print covers…") { model.printDraftCovers() }
                    .buttonStyle(PillButtonStyle())
            }
            ScrollView(.horizontal, showsIndicators: plan.count > 4) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(plan) { disc in
                        Button {
                            if covers[disc.id] != nil { enlarged = disc.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Group {
                                    if let cover = covers[disc.id] {
                                        BDWrapView(disc: cover)
                                            .environment(\.coverTheme, .purple(inkSaver: inkSaver))
                                            .allowsHitTesting(false)
                                            .scaleEffect(Self.scale, anchor: .topLeading)
                                    } else {
                                        Color(hex: 0x111111)
                                    }
                                }
                                .frame(width: BDWrap.size.width * Self.scale, height: BDWrap.size.height * Self.scale, alignment: .topLeading)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                                HStack(spacing: 6) {
                                    Text(disc.label).font(Theme.mono(11, .semibold))
                                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                                }
                                .foregroundStyle(Theme.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to see this cover larger")
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .sheet(isPresented: Binding(get: { enlarged != nil }, set: { if !$0 { enlarged = nil } })) {
            CoverZoomView(covers: plan.compactMap { covers[$0.id] }, selected: enlarged ?? plan.first?.id ?? "") {
                enlarged = nil
                model.printDraftCovers()
            }
        }
        .task(id: signature) {
            // Wait for typing and dragging to settle before rebuilding.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            var built: [String: CoverDisc] = [:]
            for disc in plan {
                let record = CoverBuilder.record(for: disc, media: model.draft.media, speed: model.draft.speed,
                                                 recoveryPercent: model.draft.effectiveRecovery(par2Available: model.recoveryEnabled))
                built[disc.id] = await CoverBuilder.disc(record, service: model.infoService)
                guard !Task.isCancelled else { return }
            }
            covers = built
        }
    }

    /// Changes whenever something on a front would change.
    private var signature: String {
        plan.map { d in
            d.label + ":" + d.games.map { "\($0.url.path)|\($0.info?.gogID ?? "-")|\($0.edition ?? "")" }.joined(separator: ",")
        }.joined(separator: ";") + model.draft.media.rawValue
    }
}

/// One cover large: the Blu-ray case or the jewel case front, with arrows between discs.
struct CoverZoomView: View {
    @Environment(\.dismiss) private var dismiss
    var covers: [CoverDisc]
    @State var selected: String
    var print: () -> Void
    @State private var kind: CoverKind = .bluRay
    @AppStorage(CoverTheme.inkSaverKey) private var inkSaver = false

    var body: some View {
        let index = covers.firstIndex { $0.id == selected } ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(covers.indices.contains(index) ? covers[index].label : "")
                    .font(Theme.mono(15))
                if covers.count > 1 {
                    Text("\(index + 1) of \(covers.count)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Toggle("Ink saver", isOn: $inkSaver)
                    .toggleStyle(.switch)
                    .help("White front with purple text and rings; the spine stays purple")
                PillPicker(options: [(CoverKind.bluRay, "Blu-ray case"), (CoverKind.jewel, "Jewel booklet")], selection: $kind)
                if covers.count > 1 {
                    Button { step(-1, from: index) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(index == 0)
                    Button { step(1, from: index) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(index >= covers.count - 1)
                }
                Button("Print covers…") { print() }
                    .buttonStyle(PillButtonStyle())
                Button("Done") { dismiss() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            GeometryReader { geo in
                let size = kind == .bluRay ? BDWrap.size : JewelBooklet.size
                let scale = min(geo.size.width / size.width, geo.size.height / size.height, 2.2)
                Group {
                    if covers.indices.contains(index) {
                        Group {
                            if kind == .bluRay {
                                BDWrapView(disc: covers[index])
                            } else {
                                JewelBooklet(disc: covers[index])
                            }
                        }
                        .environment(\.coverTheme, .purple(inkSaver: inkSaver))
                        // Covers have nothing to click, and their blurred backdrop reaches past the frame,
                        // which would otherwise swallow clicks on the header controls.
                        .allowsHitTesting(false)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(24)
            .background(Theme.track)
            .clipped()
        }
        .frame(minWidth: 1000, idealWidth: 1300, minHeight: 640, idealHeight: 820)
        .background(Theme.window)
    }

    private func step(_ delta: Int, from index: Int) {
        let next = index + delta
        guard covers.indices.contains(next) else { return }
        selected = covers[next].id
    }
}

struct DropMarker: Equatable {
    var url: URL?
    var below: Bool
}

/// The accent line showing where a dragged game will be dropped.
private struct InsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Theme.ink, lineWidth: 2).frame(width: 9, height: 9)
            Rectangle().fill(Theme.ink).frame(height: 3)
        }
        .padding(.horizontal, 10)
        .offset(y: 0)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Drops on a game row (or the end zone when `target` is nil): reorder games, or add folders from the Finder.
private struct RowDrop: DropDelegate {
    var target: URL?
    var height: CGFloat
    var model: AppModel
    @Binding var marker: DropMarker?

    private func isReorder(_ info: DropInfo) -> Bool {
        !info.hasItemsConforming(to: [.fileURL]) && model.draggingGame != nil
    }

    private func below(_ info: DropInfo) -> Bool { target != nil && info.location.y > height / 2 }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) || model.draggingGame != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isReorder(info) else {
            marker = nil
            return DropProposal(operation: .copy)
        }
        let next = DropMarker(url: target, below: below(info))
        if marker != next { marker = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if marker?.url == target { marker = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            marker = nil
            model.draggingGame = nil
        }
        if info.hasItemsConforming(to: [.fileURL]) {
            for provider in info.itemProviders(for: [.fileURL]) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.addFolders([url]) }
                }
            }
            return true
        }
        guard let dragged = model.draggingGame else { return false }
        withAnimation(.easeOut(duration: 0.15)) {
            model.moveGame(dragged, to: target, after: below(info))
        }
        return true
    }
}

/// Type a game's title: it replaces the installer's name and is used to search GOG and Steam for the cover.
private struct TitleEditor: View {
    @State var current: String
    var hasCustom: Bool
    var save: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game title").font(.system(size: 13, weight: .semibold))
            TextField("Title", text: $current)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .onSubmit { save(current) }
            Text("Shown in the archive and on covers, and used to search GOG and Steam for the cover. If nothing is found, the cover shows this title.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .frame(width: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if hasCustom {
                    Button("Use the installer's title") { save("") }
                        .buttonStyle(PillButtonStyle())
                }
                Spacer()
                Button("Save and find cover") { save(current) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
