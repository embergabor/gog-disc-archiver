import AppKit
import Foundation
import Observation

/// Switches for features that are built but not shown yet.
enum Features {
    /// par2 recovery data: hidden for now (user, 2026-11-11). The code stays; flip to bring it back.
    static let recovery = false
}

/// Discs for the Print covers sheet: burned ones from the catalogue, or planned ones before/while burning.
enum CoverSource: Equatable {
    case catalogue([String])
    case plan([PlannedDisc], Media, Int, Int)
}

/// The disc being put together on the New disc screen.
struct DiscDraft {
    var id: String
    var media: Media = .bd25
    var recoveryPercent = 5
    var speed = 4
    var games: [GameFolder] = []

    var gameBytes: Int64 { games.reduce(0) { $0 + $1.totalBytes } }
    var fileCount: Int { games.reduce(0) { $0 + $1.files.count } }

    /// The recovery percentage that will really be made: none without par2.
    func effectiveRecovery(par2Available: Bool) -> Int { par2Available ? recoveryPercent : 0 }

    /// The discs these games need. One disc in the common case.
    func plan(par2Available: Bool) -> Result<[PlannedDisc], DiscPlanner.PlanError> {
        Result { try DiscPlanner.plan(games: games, media: media, percent: effectiveRecovery(par2Available: par2Available), firstID: id) }
            .mapError { $0 as? DiscPlanner.PlanError ?? .noGames }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Screen: Hashable {
        case newDisc, archive
    }

    var screen: Screen? = .newDisc
    private(set) var discs: [DiscRecord] = []
    var draft: DiscDraft
    var session: BurnSession?
    /// A set left part-way with Finish later.
    private(set) var pending: PendingSet?
    /// The list order before Optimise, for Undo. Cleared by any other change to the list.
    private(set) var orderBeforeOptimise: [URL]?
    var check: CheckJob?
    var alert: String?
    /// Archive selection.
    var selectedDisc: String?
    /// What the Print covers sheet shows; the sheet is open while this is set.
    var coverRequest: CoverSource?
    /// Box art thumbnails for folders on the new disc.
    private(set) var thumbnails: [URL: NSImage] = [:]
    @ObservationIgnored private var artCache: [String: NSImage] = [:]

    let paths: AppPaths
    let store: CatalogueStore
    let drive = DriveMonitor()
    let par2: URL?
    let infoService: GameInfoService
    /// Set with `-simulateBurn <folder>`: burns copy into that folder instead of a disc.
    let simulateFolder: URL?

    init() {
        let paths = AppPaths.fromDefaults()
        self.paths = paths
        store = CatalogueStore(url: paths.catalogue)
        infoService = GameInfoService(cacheRoot: paths.info)
        par2 = Par2.find()
        if let sim = UserDefaults.standard.string(forKey: "simulateBurn"), !sim.isEmpty {
            simulateFolder = URL(fileURLWithPath: (sim as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            simulateFolder = nil
        }
        var loaded: [DiscRecord] = []
        var problem: String?
        do {
            loaded = try store.load()
        } catch {
            problem = "Could not read the catalogue at \(paths.catalogue.path): \(error.localizedDescription)"
        }
        let pending = try? CatalogueStore.decoder.decode(PendingSet.self, from: Data(contentsOf: paths.pendingSet))
        self.pending = pending
        draft = DiscDraft(id: DiscID.next(after: loaded.map(\.baseID) + DiscPlanner.baseIDs(pending?.discs ?? [])))
        discs = loaded
        alert = problem
        if let media = drive.state.media, drive.state.blank { selectMedia(media) }
        // Development: `-addFolders "/path/one|/path/two"` pre-fills the new disc.
        if let list = UserDefaults.standard.string(forKey: "addFolders"), !list.isEmpty {
            addFolders(list.split(separator: "|").map { URL(fileURLWithPath: String($0), isDirectory: true) })
        }
    }

    var par2Available: Bool { par2 != nil }
    /// Recovery data is made only when the feature is on and par2 is installed.
    var recoveryEnabled: Bool { Features.recovery && par2Available }
    var job: BurnJob? { session?.job }

    var draftPlan: Result<[PlannedDisc], DiscPlanner.PlanError> { draft.plan(par2Available: recoveryEnabled) }

    /// IDs already used by the catalogue or by an unfinished set.
    private var usedIDs: [String] { discs.map(\.baseID) + DiscPlanner.baseIDs(pending?.discs ?? []) }

    private func nextID() -> String { DiscID.next(after: usedIDs) }
    var isSimulating: Bool { simulateFolder != nil }

    var driveSummary: String {
        isSimulating ? "Simulated burner · writes to \(simulateFolder!.path)" : drive.state.summary
    }

    // MARK: - New disc

    func selectMedia(_ media: Media) {
        draft.media = media
        if !media.speeds.contains(draft.speed) { draft.speed = media.recommendedSpeed }
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one folder per game."
        if panel.runModal() == .OK { addFolders(panel.urls) }
    }

    func addFolders(_ urls: [URL]) {
        Task {
            var problems: [String] = []
            for url in urls {
                do {
                    let game = try await Task.detached { try GameFolder.scan(url) }.value
                    if draft.games.contains(where: { $0.name == game.name }) {
                        problems.append("A folder named \u{201C}\(game.name)\u{201D} is already on this disc.")
                    } else {
                        draft.games.append(game)
                        orderBeforeOptimise = nil
                        lookUp(game)
                    }
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            if !problems.isEmpty { alert = problems.joined(separator: "\n") }
        }
    }

    /// Finds the game in GOG's catalog and fetches its box art for the contents list.
    private func lookUp(_ game: GameFolder) {
        let service = infoService
        Task {
            let info = await service.lookup(setupFile: game.setupFile, productName: game.installer?.productName, folderName: game.name)
            if let i = draft.games.firstIndex(where: { $0.url == game.url }) {
                draft.games[i].info = info
                draft.games[i].lookedUp = true
            }
            if let info, let file = await service.art(for: info).portrait, let image = NSImage(contentsOf: file) {
                thumbnails[game.url] = image
            }
        }
    }

    /// Box art already downloaded for a game in the catalogue (no network).
    func cachedPortrait(_ info: GameInfo?) -> NSImage? {
        guard let info else { return nil }
        if let hit = artCache[info.gogID] { return hit }
        let folder = infoService.artRoot.appendingPathComponent(info.gogID)
        for ext in ["jpg", "png"] {
            if let image = NSImage(contentsOf: folder.appendingPathComponent("portrait." + ext)) {
                artCache[info.gogID] = image
                return image
            }
        }
        return nil
    }

    func setEdition(_ text: String, for game: GameFolder) {
        guard let i = draft.games.firstIndex(where: { $0.url == game.url }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        draft.games[i].edition = trimmed.isEmpty ? nil : trimmed
    }

    func remove(_ game: GameFolder) {
        draft.games.removeAll { $0.id == game.id }
        orderBeforeOptimise = nil
    }

    /// Why Burn is not available, or nil when it is.
    var burnBlocker: String? {
        let plan: [PlannedDisc]
        switch draftPlan {
        case .success(let p): plan = p
        case .failure(let e): return e.message
        }
        if let clash = DiscPlanner.baseIDs(plan).first(where: usedIDs.contains) {
            return "\(clash) is already in the archive."
        }
        return driveBlocker(for: draft.media)
    }

    /// Nil when the drive holds a blank disc of this type (or burns are simulated).
    func driveBlocker(for media: Media) -> String? {
        if isSimulating { return nil }
        let s = drive.state
        if !s.hasDrive { return "Connect a burner." }
        if !s.mediaPresent { return "Insert a blank \(media.label)." }
        if !s.ready(for: media) {
            if let m = s.media, s.blank { return "The disc in the drive is a \(m.label)." }
            return "Insert a blank \(media.label)."
        }
        return nil
    }

    private func makeWriter() -> DiscWriter? {
        if let folder = simulateFolder { return FolderWriter(folder: folder) }
        if let device = drive.device { return DiscRecordingWriter(device: device) }
        alert = "No burner found."
        return nil
    }

    func startBurn() {
        guard burnBlocker == nil, case .success(let plan) = draftPlan else { return }
        session = BurnSession(discs: plan, media: draft.media, speed: draft.speed,
                              recoveryPercent: draft.effectiveRecovery(par2Available: recoveryEnabled))
        startCurrentDisc()
    }

    /// Burns the session's current disc (the first, the next after a swap, or a retry).
    func startCurrentDisc() {
        guard let session, session.job?.isRunning != true, let writer = makeWriter() else { return }
        session.start(writer: writer, par2: recoveryEnabled ? par2 : nil, paths: paths) { [weak self] record in
            self?.upsert(record)
        }
    }

    /// After a verified set disc: move on and burn the next one.
    func burnNextDisc() {
        guard let session, session.waitingForNextDisc, driveBlocker(for: session.media) == nil else { return }
        session.advance()
        startCurrentDisc()
    }

    /// Burn the current disc again on a new blank, after a failure or a bad read-back.
    func retryDisc() {
        guard let session, session.job?.isRunning == false else { return }
        startCurrentDisc()
    }

    /// Stop between discs and keep the rest of the set for later.
    func finishLater() {
        guard let session, session.job?.isRunning != true else { return }
        let rest = session.remaining
        savePending(rest.isEmpty ? nil : PendingSet(discs: rest, media: session.media, speed: session.speed,
                                                     recoveryPercent: session.recoveryPercent, savedAt: Date()))
        endSession(clearDraft: true)
    }

    func continuePending() {
        guard let pending, session == nil else { return }
        session = BurnSession(discs: pending.discs, media: pending.media, speed: pending.speed, recoveryPercent: pending.recoveryPercent)
        savePending(nil)
        screen = .newDisc
    }

    func discardPending() {
        savePending(nil)
        draft.id = nextID()
    }

    private func savePending(_ set: PendingSet?) {
        pending = set
        do {
            if let set {
                try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
                try CatalogueStore.encoder.encode(set).write(to: paths.pendingSet, options: .atomic)
            } else if FileManager.default.fileExists(atPath: paths.pendingSet.path) {
                try FileManager.default.removeItem(at: paths.pendingSet)
            }
        } catch {
            alert = "Could not save the unfinished set: \(error.localizedDescription)"
        }
    }

    /// Leave the burn screens. Something burned clears the draft; a failure before any disc keeps it.
    func closeJob() {
        guard let session, session.job?.isRunning != true else { return }
        if session.isSet, !session.remaining.isEmpty, !session.burned.isEmpty {
            // Part of a set is on disc: keep the rest so it can be finished later.
            finishLater()
            return
        }
        endSession(clearDraft: !session.burned.isEmpty)
    }

    private func endSession(clearDraft: Bool) {
        session = nil
        if clearDraft {
            draft = DiscDraft(id: nextID(), media: draft.media, recoveryPercent: draft.recoveryPercent, speed: draft.speed)
        }
    }

    func showInArchive(_ id: String) {
        closeJob()
        selectedDisc = id
        screen = .archive
    }

    func printCover(_ id: String) {
        showInArchive(id)
        coverRequest = .catalogue([id])
    }

    /// Covers for the discs on the New disc screen, before burning.
    func printDraftCovers() {
        guard case .success(let plan) = draftPlan else { return }
        coverRequest = .plan(plan, draft.media, draft.speed, draft.effectiveRecovery(par2Available: recoveryEnabled))
    }

    /// Covers for the discs being burned, while the burn runs.
    func printSessionCovers() {
        guard let session else { return }
        coverRequest = .plan(session.discs, session.media, session.speed, session.recoveryPercent)
    }

    /// Moves a game on the new disc; the order is the order of covers on the front and games on the back.
    func moveGame(_ url: URL, before target: URL) {
        guard url != target, let from = draft.games.firstIndex(where: { $0.url == url }) else { return }
        let game = draft.games.remove(at: from)
        let to = draft.games.firstIndex(where: { $0.url == target }) ?? draft.games.count
        draft.games.insert(game, at: to)
        orderBeforeOptimise = nil
    }

    /// The list order that needs the fewest discs.
    private var optimisedGames: [GameFolder] {
        DiscPlanner.optimisedOrder(games: draft.games, media: draft.media, percent: draft.effectiveRecovery(par2Available: recoveryEnabled))
    }

    /// How many discs Optimise would save (0 when the list order is already as good).
    var optimiseSaving: Int {
        guard draft.games.count > 1, case .success(let now) = draftPlan else { return 0 }
        var trial = draft
        trial.games = optimisedGames
        guard case .success(let better) = trial.plan(par2Available: recoveryEnabled) else { return 0 }
        return max(0, now.count - better.count)
    }

    /// Reorders the list for the fewest discs. Undo puts the user's order back.
    func optimiseOrder() {
        guard optimiseSaving > 0 else { return }
        let before = draft.games.map(\.url)
        draft.games = optimisedGames
        orderBeforeOptimise = before
    }

    func undoOptimise() {
        guard let before = orderBeforeOptimise else { return }
        let byURL = Dictionary(uniqueKeysWithValues: draft.games.map { ($0.url, $0) })
        draft.games = before.compactMap { byURL[$0] }
        orderBeforeOptimise = nil
    }

    // MARK: - Catalogue

    func upsert(_ record: DiscRecord) {
        if let i = discs.firstIndex(where: { $0.id == record.id }) {
            discs[i] = record
        } else {
            discs.append(record)
        }
        do {
            try store.save(discs)
        } catch {
            alert = "Could not save the catalogue: \(error.localizedDescription)"
        }
    }

    func disc(_ id: String?) -> DiscRecord? {
        guard let id else { return nil }
        return discs.first { $0.id == id }
    }

    var dueCount: Int {
        discs.filter { [.due, .damaged].contains($0.health()) }.count
    }

    // MARK: - Re-checking an old disc

    func startCheck(_ record: DiscRecord) {
        guard check?.isRunning != true else { return }
        let job = CheckJob(record: record)
        check = job
        job.start { [weak self] result in
            guard var updated = self?.disc(record.id) else { return }
            updated.checks.append(result)
            self?.upsert(updated)
        }
    }
}

/// Re-reads an archived disc. Waits for it to be inserted, then hashes every file.
@MainActor
@Observable
final class CheckJob {
    let record: DiscRecord
    private(set) var waitingForDisc = true
    private(set) var fraction: Double = 0
    private(set) var result: CheckRecord?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(record: DiscRecord) {
        self.record = record
    }

    var isRunning: Bool { result == nil && error == nil }

    func start(save: @escaping @MainActor (CheckRecord) -> Void) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var root: URL?
                while root == nil {
                    root = Verifier.mountedVolume(named: record.volumeName)
                    if root == nil { try await Task.sleep(nanoseconds: 1_000_000_000) }
                }
                waitingForDisc = false
                let files = record.allFiles
                let mounted = root!
                let check = try await Task.detached(priority: .userInitiated) {
                    try Verifier.check(root: mounted, files: files) { value in
                        Task { @MainActor [weak self] in self?.fraction = value }
                    }
                }.value
                result = check
                save(check)
            } catch is CancellationError {
                error = "Check stopped."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
