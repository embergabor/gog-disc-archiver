import SwiftUI

/// After a burn: verified, damaged, failed or stopped.
struct ResultView: View {
    @Environment(AppModel.self) private var model
    var job: BurnJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch job.outcome {
                case .verified(let record):
                    headline(icon: "checkmark", tone: nil, title: "\(record.id) is safe",
                             text: "All \(record.allFiles.count) files were read back from the disc and matched their checksums.")
                    DiscFacts(record: record)
                    nextSteps(record)
                case .damaged(let record):
                    let bad = record.lastCheck?.bad ?? []
                    headline(icon: "exclamationmark", tone: .bad, title: "\(record.id) did not read back cleanly",
                             text: "\(bad.count) of \(record.allFiles.count) files did not match. Don't rely on this disc: burn it again on a new blank.")
                    BadFiles(paths: bad)
                    DiscFacts(record: record)
                    HStack {
                        Button("Show in archive") { model.showInArchive(record.id) }.buttonStyle(PillButtonStyle())
                        Button("New disc") { model.closeJob() }.buttonStyle(PillButtonStyle(prominent: true))
                    }
                case .failed(let message):
                    headline(icon: "xmark", tone: .bad, title: "\(job.plan.id) was not finished", text: message)
                    stepsSummary
                    Button("Back to the disc") { model.closeJob() }.buttonStyle(PillButtonStyle(prominent: true))
                case .cancelled, .none:
                    headline(icon: "minus", tone: .neutral, title: "Stopped", text: job.steps.contains { $0.id == .burn && $0.state == .failed }
                             ? "The burn was stopped part way. That disc can't be used."
                             : "Nothing was written to the disc.")
                    Button("Back to the disc") { model.closeJob() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(job.plan.id)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New disc") { model.closeJob() }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }

    private var subtitle: String {
        switch job.outcome {
        case .verified(let r): "Burned and verified · \(DateText.day(r.burnedAt))"
        case .damaged: "Read-back found errors"
        case .failed: "Failed"
        default: "Stopped"
        }
    }

    private func headline(icon: String, tone: Tone?, title: String, text: String) -> some View {
        HStack(spacing: 22) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(tone?.foreground ?? Theme.onAccent)
                .frame(width: 72, height: 72)
                .background(tone?.background ?? Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 34, weight: .bold))
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stepsSummary: some View {
        Card {
            ForEach(job.steps) { step in
                HStack {
                    Text(step.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(stateText(step.state)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private func stateText(_ state: BurnJob.StepState) -> String {
        switch state {
        case .done: "Done"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .running: "Running"
        case .waiting: "Not started"
        }
    }

    private func nextSteps(_ record: DiscRecord) -> some View {
        Card {
            Text("Next").font(.system(size: 15, weight: .bold))
            HStack(spacing: 12) {
                (Text("Write ") + Text(record.id).font(Theme.mono(13)) + Text(" on the clear hub ring with a disc-safe marker, print a cover for its case and store it upright."))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Print cover…") { model.printCover(record.id) }
                    .buttonStyle(PillButtonStyle())
            }
            Divider().overlay(Theme.rowDivider)
            HStack(spacing: 12) {
                Text("The catalogue knows what's on it: find any game later under All discs.")
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Show in archive") { model.showInArchive(record.id) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
    }
}

struct DiscFacts: View {
    var record: DiscRecord

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(row.0)
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(row.1)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                if index < rows.count - 1 { Divider().overlay(Theme.rowDivider) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardBorder))
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Media", record.media.longName),
            ("Contents", "\(record.games.count) games · \(ByteText.gb(record.gameBytes))"),
            ("Safety data", record.recoveryFiles.isEmpty
                ? "checksums.sha256 · no recovery data"
                : "checksums.sha256 · par2 recovery \(record.recoveryPercent)% (\(ByteText.gb(record.recoveryBytes)))"),
            ("Burned", "\(DateText.dayTime(record.burnedAt)) at \(record.speed)× · \(record.drive)"),
        ]
        if let check = record.lastCheck {
            rows.append(("Last read", "\(DateText.day(check.date)) · \(check.filesOK) of \(check.filesTotal) files OK"))
        }
        if let next = record.nextCheckDate {
            rows.append(("Next check", "Around \(DateText.month(next)) (re-read every 3 years)"))
        }
        return rows
    }
}

struct BadFiles: View {
    var paths: [String]

    var body: some View {
        Card {
            Text("Files that failed").font(.system(size: 15, weight: .bold))
            ForEach(paths.prefix(20), id: \.self) { path in
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            if paths.count > 20 {
                Text("and \(paths.count - 20) more").foregroundStyle(Theme.secondary)
            }
        }
    }
}
