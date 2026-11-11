import SwiftUI

struct BurnView: View {
    @Environment(AppModel.self) private var model
    var job: BurnJob
    @State private var confirmStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 28) {
                    ProgressRing(value: job.overall)
                        .frame(width: 168, height: 168)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Step \(job.stepNumber) of \(job.steps.count) · \(job.current?.title ?? "Starting")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("\(Int((job.overall * 100).rounded()))%")
                            .font(.system(size: 40, weight: .bold))
                            .monospacedDigit()
                        Text(stepLine)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                        Text("Don't eject the disc or unplug the drive. Interrupting a burn leaves the disc unusable.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(job.steps) { step in
                        StepRow(step: step, number: step.id.rawValue + 1, fraction: job.fraction)
                        if step.id != job.steps.last?.id {
                            Divider().overlay(Theme.rowDivider)
                        }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardBorder))

                HStack {
                    Text("Reading from the game folders: keep that drive connected until the read-back is done.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Print covers…") { model.printSessionCovers() }
                        .buttonStyle(PillButtonStyle())
                    Button("Stop…", role: .destructive) { confirmStop = true }
                        .buttonStyle(PillButtonStyle(destructive: true))
                }
            }
            .frame(maxWidth: 640)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Burning \(job.plan.label)")
        .navigationSubtitle("\(job.plan.media.label) · \(job.plan.speed)×")
        .confirmationDialog("Stop \(job.plan.label)?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { job.cancel() }
        } message: {
            Text(job.current?.id == .burn
                 ? "The burn has started. Stopping now leaves this disc unusable."
                 : "Nothing has been written to the disc yet.")
        }
    }

    private var stepLine: String {
        guard let step = job.current else { return "Getting ready" }
        switch step.id {
        case .checksums, .readBack:
            let bytes = Int64(Double(step.id == .readBack ? max(job.plan.gameBytes, 1) : job.plan.gameBytes) * job.fraction)
            return "\(ByteText.gb(bytes)) of \(ByteText.gb(job.plan.gameBytes)) \(step.id == .readBack ? "read back" : "checked")"
        case .burn:
            return "Writing \(job.plan.media.label) · \(Int((job.fraction * 100).rounded()))%"
        case .recovery:
            return "Making recovery data · \(Int((job.fraction * 100).rounded()))%"
        case .layout:
            return "Laying out the disc"
        }
    }
}

private struct StepRow: View {
    var step: BurnJob.Step
    var number: Int
    var fraction: Double

    var body: some View {
        HStack(spacing: 14) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(step.state == .waiting ? Theme.secondary : Theme.text)
                Text(step.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                if step.state == .running {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Theme.ink)
                        .frame(maxWidth: 360)
                }
            }
            Spacer()
            Text(timeText)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 60)
    }

    @ViewBuilder private var badge: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(Theme.accent, in: Circle())
        case .running:
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Theme.controlBorder, lineWidth: 1.5))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Tone.bad.foreground)
                .frame(width: 26, height: 26)
                .background(Tone.bad.background, in: Circle())
        case .waiting:
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Theme.controlBorder, lineWidth: 1.5))
        }
    }

    private var timeText: String {
        guard let start = step.started else { return "" }
        let end = step.finished ?? Date()
        let seconds = Int(end.timeIntervalSince(start))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct ProgressRing: View {
    var value: Double

    var body: some View {
        ZStack {
            Circle().fill(Theme.card).overlay(Circle().stroke(Theme.cardBorder))
            Circle().stroke(Theme.track, lineWidth: 16).padding(12)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 16))
                .rotationEffect(.degrees(-90))
                .padding(12)
                .animation(.easeOut(duration: 0.3), value: value)
            Circle().fill(Theme.window).overlay(Circle().stroke(Theme.cardBorder)).frame(width: 44, height: 44)
            Circle().fill(Theme.card).overlay(Circle().stroke(Theme.controlBorder)).frame(width: 14, height: 14)
        }
        .accessibilityElement()
        .accessibilityLabel("Progress \(Int(value * 100)) percent")
    }
}
