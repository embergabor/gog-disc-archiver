import Foundation
import Observation

/// Burns a plan of one or more discs, one at a time. Between discs it waits for the next blank.
@MainActor
@Observable
final class BurnSession {
    let discs: [PlannedDisc]
    let media: Media
    let speed: Int
    let recoveryPercent: Int
    private(set) var index = 0
    private(set) var job: BurnJob?
    /// Records of discs already burned in this session, by disc id.
    private(set) var burned: [String: DiscRecord] = [:]

    init(discs: [PlannedDisc], media: Media, speed: Int, recoveryPercent: Int) {
        self.discs = discs
        self.media = media
        self.speed = speed
        self.recoveryPercent = recoveryPercent
    }

    var current: PlannedDisc { discs[index] }
    var isSet: Bool { discs.count > 1 }
    var isLast: Bool { index == discs.count - 1 }
    var next: PlannedDisc? { isLast ? nil : discs[index + 1] }

    /// The current disc burned and read back cleanly and another disc follows: time to swap.
    var waitingForNextDisc: Bool {
        guard let job, case .verified = job.outcome else { return false }
        return !isLast
    }

    func start(writer: DiscWriter, par2: URL?, paths: AppPaths, save: @escaping @MainActor (DiscRecord) -> Void) {
        let plan = BurnPlan(disc: current, media: media, speed: speed, recoveryPercent: recoveryPercent)
        let job = BurnJob(plan: plan, par2Available: par2 != nil)
        self.job = job
        job.start(writer: writer, par2: par2, paths: paths) { [weak self] record in
            self?.burned[record.id] = record
            save(record)
        }
    }

    /// Move on to the next disc; the caller starts it.
    func advance() {
        guard !isLast else { return }
        index += 1
        job = nil
    }

    /// Discs still to burn if the user stops now: from the next one when this one is done, else this one.
    var remaining: [PlannedDisc] {
        if let job, case .verified = job.outcome { return Array(discs[(index + 1)...]) }
        return Array(discs[index...])
    }

    enum DiscState { case verified, damaged, current, waiting }

    func state(of disc: PlannedDisc) -> DiscState {
        if let record = burned[disc.id] { return record.lastCheck?.ok == true ? .verified : .damaged }
        return disc.id == current.id ? .current : .waiting
    }
}
