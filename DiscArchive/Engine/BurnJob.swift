import AppKit
import Foundation
import Observation

/// What the user set up on the New disc screen, frozen when Burn is pressed.
struct BurnPlan: Sendable {
    var id: String
    var media: Media
    var speed: Int
    var recoveryPercent: Int
    var games: [GameFolder]

    var volumeName: String { DiscID.volumeName(for: id) }
    var gameBytes: Int64 { games.reduce(0) { $0 + $1.totalBytes } }
    var fileCount: Int { games.reduce(0) { $0 + $1.files.count } }
}

/// Runs one disc: checksums → recovery data → disc layout → burn → read back.
@MainActor
@Observable
final class BurnJob {
    enum StepID: Int, CaseIterable, Identifiable {
        case checksums, recovery, layout, burn, readBack
        var id: Int { rawValue }
    }

    enum StepState: Equatable {
        case waiting, running, done, skipped, failed
    }

    struct Step: Identifiable {
        var id: StepID
        var title: String
        var detail: String
        var state: StepState = .waiting
        var started: Date?
        var finished: Date?
    }

    enum Outcome {
        case verified(DiscRecord)
        /// Burned, but the read-back found bad files. The record is saved with that check.
        case damaged(DiscRecord)
        case failed(String)
        case cancelled
    }

    let plan: BurnPlan
    private(set) var steps: [Step]
    /// Progress of the running step, 0…1.
    private(set) var fraction: Double = 0
    private(set) var outcome: Outcome?
    let startedAt = Date()

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    init(plan: BurnPlan, par2Available: Bool) {
        self.plan = plan
        let recoveryDetail: String
        if plan.recoveryPercent == 0 {
            recoveryDetail = "Off"
        } else if !par2Available {
            recoveryDetail = "Skipped: par2 is not installed"
        } else {
            recoveryDetail = "par2, \(plan.recoveryPercent)% per game"
        }
        steps = [
            Step(id: .checksums, title: "Checksums", detail: "SHA-256 for \(plan.fileCount) files"),
            Step(id: .recovery, title: "Recovery data", detail: recoveryDetail),
            Step(id: .layout, title: "Disc layout", detail: "UDF, volume \(plan.volumeName) · read straight from the game folders"),
            Step(id: .burn, title: "Burning", detail: "\(plan.media.label) at \(plan.speed)×"),
            Step(id: .readBack, title: "Read back", detail: "Re-read every file from the disc and compare"),
        ]
    }

    var current: Step? { steps.first { $0.state == .running } }
    var isRunning: Bool { outcome == nil }
    var stepNumber: Int { (current?.id.rawValue ?? 0) + 1 }

    /// Overall progress, steps weighted roughly by how long they take.
    var overall: Double {
        let weights: [StepID: Double] = [.checksums: 0.15, .recovery: plan.recoveryPercent > 0 ? 0.2 : 0, .layout: 0.01, .burn: 0.4, .readBack: 0.24]
        let total = weights.values.reduce(0, +)
        var done = 0.0
        for step in steps {
            let w = weights[step.id] ?? 0
            switch step.state {
            case .done, .skipped: done += w
            case .running: done += w * fraction
            default: break
            }
        }
        return total > 0 ? done / total : 0
    }

    func start(writer: DiscWriter, par2: URL?, paths: AppPaths, save: @escaping @MainActor (DiscRecord) -> Void) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Burning \(plan.id)")
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(writer: writer, par2: par2, paths: paths, save: save)
            if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity) }
            self.activity = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Steps

    private func run(writer: DiscWriter, par2: URL?, paths: AppPaths, save: @escaping @MainActor (DiscRecord) -> Void) async {
        let plan = self.plan
        let setFolder = paths.set(for: plan.id)
        let recoveryFolder = setFolder.appendingPathComponent("recovery", isDirectory: true)
        do {
            // A fresh set folder: anything left from an earlier, failed attempt is replaced.
            if FileManager.default.fileExists(atPath: setFolder.path) {
                try FileManager.default.removeItem(at: setFolder)
            }
            try FileManager.default.createDirectory(at: setFolder, withIntermediateDirectories: true)

            // 1. Checksums
            begin(.checksums)
            let games = try await hashGames(plan.games)
            end(.checksums)

            // 2. Recovery data
            var recoveryFiles: [FileRecord] = []
            if plan.recoveryPercent > 0, let par2 {
                begin(.recovery)
                recoveryFiles = try await makeRecovery(tool: par2, folder: recoveryFolder)
                end(.recovery)
            } else {
                mark(.recovery, .skipped)
            }

            // 3. Layout
            begin(.layout)
            let record = DiscRecord(id: plan.id, volumeName: plan.volumeName, media: plan.media, burnedAt: Date(),
                                    drive: writer.driveName, speed: plan.speed, recoveryPercent: recoveryFiles.isEmpty ? 0 : plan.recoveryPercent,
                                    games: games, recoveryFiles: recoveryFiles, checks: [])
            let layout = try DiscLayout.make(record: record, games: plan.games, recoveryFolder: recoveryFolder)
            try Data(Checksums.render(record.allFiles).utf8).write(to: setFolder.appendingPathComponent("checksums.sha256"))
            try CatalogueStore.encoder.encode(record).write(to: setFolder.appendingPathComponent("disc.json"))
            end(.layout)

            // 4. Burn
            begin(.burn)
            let mounted = try await writer.write(layout, media: plan.media, speed: plan.speed) { [weak self] value in
                self?.fraction = value
            }
            end(.burn)

            // 5. Read back
            begin(.readBack)
            let files = record.allFiles
            let check = try await Task.detached(priority: .userInitiated) {
                try Verifier.check(root: mounted, files: files) { value in
                    Task { @MainActor [weak self] in self?.fraction = value }
                }
            }.value
            var saved = record
            saved.checks = [check]
            save(saved)
            if check.ok {
                end(.readBack)
                outcome = .verified(saved)
            } else {
                mark(.readBack, .failed)
                outcome = .damaged(saved)
            }
            if writer.ejectsWhenDone {
                try? NSWorkspace.shared.unmountAndEjectDevice(at: mounted)
            }
        } catch is CancellationError {
            failRunning()
            outcome = .cancelled
        } catch {
            failRunning()
            outcome = .failed(error.localizedDescription)
        }
    }

    private func hashGames(_ games: [GameFolder]) async throws -> [GameRecord] {
        let total = max(1, games.reduce(0) { $0 + $1.totalBytes })
        return try await Task.detached(priority: .userInitiated) {
            var done: Int64 = 0
            var lastReport = Date.distantPast
            var records: [GameRecord] = []
            for game in games {
                var files: [FileRecord] = []
                for file in game.files {
                    let url = game.url.appendingPathComponent(file.relativePath)
                    let hash = try Checksums.sha256(of: url) { n in
                        done += n
                        if Date().timeIntervalSince(lastReport) > 0.2 {
                            lastReport = Date()
                            let value = Double(done) / Double(total)
                            Task { @MainActor [weak self] in self?.fraction = value }
                        }
                    }
                    files.append(FileRecord(path: game.name + "/" + file.relativePath, size: file.size, sha256: hash))
                }
                records.append(GameRecord(folder: game.name, platforms: game.platforms, files: files, version: game.version, info: game.info))
            }
            return records
        }.value
    }

    private func makeRecovery(tool: URL, folder: URL) async throws -> [FileRecord] {
        let games = plan.games
        let percent = plan.recoveryPercent
        let total = max(1, games.reduce(0) { $0 + $1.totalBytes })
        var doneBytes: Int64 = 0
        var made: [URL] = []
        for game in games {
            let weight = Double(game.totalBytes) / Double(total)
            let offset = Double(doneBytes) / Double(total)
            let files = game.files.map { game.url.appendingPathComponent($0.relativePath) }
            let urls = try await Par2.create(tool: tool, percent: percent, name: game.name,
                                             base: game.url.deletingLastPathComponent(), files: files, output: folder) { value in
                Task { @MainActor [weak self] in self?.fraction = offset + weight * value }
            }
            made += urls
            doneBytes += game.totalBytes
        }
        return try await Task.detached(priority: .userInitiated) {
            try made.map { url in
                let size = Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let hash = try Checksums.sha256(of: url)
                return FileRecord(path: DiscLayout.archiveFolder + "/recovery/" + url.lastPathComponent, size: size, sha256: hash)
            }
        }.value
    }

    // MARK: - Step bookkeeping

    private func begin(_ id: StepID) {
        fraction = 0
        update(id) {
            $0.state = .running
            $0.started = Date()
        }
    }

    private func end(_ id: StepID) {
        fraction = 1
        update(id) {
            $0.state = .done
            $0.finished = Date()
        }
    }

    private func mark(_ id: StepID, _ state: StepState) {
        update(id) { $0.state = state }
    }

    private func failRunning() {
        for i in steps.indices where steps[i].state == .running {
            steps[i].state = .failed
        }
    }

    private func update(_ id: StepID, _ change: (inout Step) -> Void) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        change(&steps[i])
    }
}
