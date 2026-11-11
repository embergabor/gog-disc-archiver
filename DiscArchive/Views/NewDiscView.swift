import SwiftUI

struct NewDiscView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
        .navigationSubtitle(model.draft.id + " · not burned yet")
        .toolbar {
            ToolbarItem(placement: .status) {
                DriveBadge()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.startBurn()
                } label: {
                    Label("Burn disc", systemImage: "flame")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(model.burnBlocker != nil)
                .help(model.burnBlocker ?? "Burn \(model.draft.id)")
            }
        }
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Disc ID")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                TextField("GOG-014", text: $model.draft.id)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(28, .bold))
                    .tracking(2)
                    .frame(maxWidth: 260)
                Text("Volume name \(DiscID.volumeName(for: model.draft.id)) · UDF, readable on Mac, Windows and Linux")
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
                GameRow(game: game, thumbnail: model.thumbnails[game.url]) { model.remove(game) }
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
        parts += game.platforms
        parts.append(ByteText.files(game.files.count))
        if game.lookedUp && game.info == nil { parts.append("not found on GOG") }
        if game.info?.title != nil && game.info?.title != game.name { parts.append("folder \u{201C}\(game.name)\u{201D}") }
        return parts.joined(separator: " · ")
    }
}

private struct SpaceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let draft = model.draft
        let cap = draft.media.capacity
        let games = draft.gameBytes
        let recovery = draft.recoveryBytes(par2Available: model.par2Available)
        let used = games + recovery
        let fits = draft.fits(par2Available: model.par2Available)
        let fill = fits ? Theme.accent : Color(hex: 0xE39A91)

        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Space").font(.system(size: 15, weight: .bold))
                Spacer()
                Text(ByteText.gb(used)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                + Text(" of \(ByteText.gb(cap))").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 0) {
                    Rectangle().fill(fill)
                        .frame(width: w * min(1, Double(games) / Double(cap)))
                    Rectangle().fill(fill.opacity(0.45))
                        .frame(width: w * max(0, min(1 - Double(games) / Double(cap), Double(recovery) / Double(cap))))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)
            .background(Theme.track)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            HStack(spacing: 18) {
                legend(fill, "Games \(ByteText.gb(games))")
                legend(fill.opacity(0.45), model.par2Available ? "Recovery data \(ByteText.gb(recovery))" : "Recovery data off (par2 not installed)")
                legend(Theme.track, fits ? "Free \(ByteText.gb(max(0, draft.media.usable - used)))" : "No space left")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            if !fits {
                Label("\(ByteText.gb(used - draft.media.usable)) too much for one \(draft.media.label). Remove a game or pick a bigger disc.",
                      systemImage: "exclamationmark.triangle")
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
