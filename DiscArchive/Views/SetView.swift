import SwiftUI

/// Between the discs of a set: label the one that just came out, insert the next blank.
/// Also shown when an unfinished set is continued, before its first remaining disc.
struct SetView: View {
    @Environment(AppModel.self) private var model
    var session: BurnSession

    var body: some View {
        let target = session.job == nil ? session.current : (session.next ?? session.current)
        let blocker = model.driveBlocker(for: session.media)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                tiles(highlight: target)

                HStack(spacing: 26) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 120, height: 120)
                        .background(Theme.card, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.controlBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    VStack(alignment: .leading, spacing: 8) {
                        if let done = lastBurned {
                            Text("\(done.label) verified · \(done.lastCheck?.filesOK ?? 0) of \(done.lastCheck?.filesTotal ?? 0) files OK")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        Text("Insert a blank \(session.media.label) for \(target.label)")
                            .font(.system(size: 30, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let done = lastBurned {
                            (Text("The last disc is out. Write ") + Text(done.label).font(Theme.mono(14)) + Text(" on its hub now, before the discs get mixed up."))
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.muted)
                        }
                        Text(model.isSimulating ? "Simulated burner: press Start when ready." : "Burning starts by itself once a blank disc is in.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("On \(target.label)").font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text("\(target.volumeName) · \(ByteText.gb(target.dataBytes))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    ForEach(target.games) { game in
                        Divider().overlay(Theme.rowDivider)
                        HStack(spacing: 12) {
                            BoxArt(image: model.cachedPortrait(game.info), width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.title).font(.system(size: 13, weight: .semibold))
                                Text(partLine(target, game))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Text(ByteText.gb(game.totalBytes)).monospacedDigit().foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 20)
                        .frame(minHeight: 52)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardBorder))

                HStack(spacing: 12) {
                    Text("You can stop between discs and finish the set another day. It waits on the New disc screen.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Finish later") { model.finishLater() }
                        .buttonStyle(PillButtonStyle())
                    Button("Start \(target.label)") { start() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(blocker != nil)
                        .help(blocker ?? "")
                }
            }
            .frame(maxWidth: 720)
            .padding(.vertical, 36)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Burning \(session.discs.count) discs")
        .navigationSubtitle("\(session.media.label) · \(session.speed)× · \(session.burned.count) of \(session.discs.count) done")
        .toolbar {
            ToolbarItem(placement: .status) { DriveBadge() }
        }
        .onChange(of: model.drive.state) { _, state in
            if !model.isSimulating, state.ready(for: session.media) { start() }
        }
    }

    private var lastBurned: DiscRecord? {
        guard let job = session.job, case .verified(let record) = job.outcome else { return nil }
        return record
    }

    private func start() {
        if session.job == nil {
            if model.driveBlocker(for: session.media) == nil { model.startCurrentDisc() }
        } else {
            model.burnNextDisc()
        }
    }

    private func partLine(_ disc: PlannedDisc, _ game: GameFolder) -> String {
        if let part = disc.part, let count = disc.partCount {
            let files = DiscPlanner.installOrder(game.files).map(\.relativePath)
            let range = files.count > 1 ? "\(files.first!) … \(files.last!)" : (files.first ?? "")
            return "Part \(part) of \(count) · \(ByteText.files(files.count)): \(range)"
        }
        return ByteText.files(game.files.count)
    }

    private func tiles(highlight: PlannedDisc) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: min(6, max(1, session.discs.count)))
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(session.discs) { disc in
                let state = session.state(of: disc)
                let next = disc.id == highlight.id && state != .verified
                VStack(alignment: .leading, spacing: 3) {
                    Text(disc.setID ?? disc.id).font(Theme.mono(11, .semibold))
                    Text(disc.part.map { "\($0)/\(disc.partCount ?? 0)" } ?? "1 disc").font(Theme.mono(15))
                    Text(stateText(state, next: next)).font(.system(size: 11, weight: .semibold))
                    Text(ByteText.gb(disc.dataBytes)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                .foregroundStyle(state == .verified ? Theme.onAccent : (next ? Theme.ink : Theme.muted))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background(state), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(next ? Theme.ink : Theme.cardBorder, lineWidth: next ? 2 : 1))
            }
        }
    }

    private func stateText(_ state: BurnSession.DiscState, next: Bool) -> String {
        switch state {
        case .verified: "Verified"
        case .damaged: "Damaged"
        case .current, .waiting: next ? "Next" : "Waiting"
        }
    }

    private func background(_ state: BurnSession.DiscState) -> Color {
        switch state {
        case .verified: Theme.accent
        case .damaged: Tone.bad.background
        default: Theme.card
        }
    }
}
