import AppKit
import Foundation
import Observation

/// The disc being put together on the New disc screen.
struct DiscDraft {
    var id: String
    var media: Media = .bd25
    var recoveryPercent = 5
    var speed = 4
    var games: [GameFolder] = []

    var gameBytes: Int64 { games.reduce(0) { $0 + $1.totalBytes } }
    var fileCount: Int { games.reduce(0) { $0 + $1.files.count } }

    /// par2 adds about the chosen percentage, plus a little for its index files.
    func recoveryBytes(par2Available: Bool) -> Int64 {
        guard par2Available, recoveryPercent > 0, !games.isEmpty else { return 0 }
        let perGameIndex = Int64(games.count) * 2_000_000
        return gameBytes * Int64(recoveryPercent) / 100 + gameBytes / 2000 + perGameIndex
    }

    func usedBytes(par2Available: Bool) -> Int64 { gameBytes + recoveryBytes(par2Available: par2Available) }
    func fits(par2Available: Bool) -> Bool { usedBytes(par2Available: par2Available) <= media.usable }
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
    var job: BurnJob?
    var check: CheckJob?
    var alert: String?
    /// Archive selection.
    var selectedDisc: String?
    /// Disc IDs for the Print covers sheet; the sheet shows while this is set.
    var coverRequest: [String]?
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
        draft = DiscDraft(id: DiscID.next(after: loaded.map(\.id)))
        discs = loaded
        alert = problem
        if let media = drive.state.media, drive.state.blank { selectMedia(media) }
        // Development: `-addFolders "/path/one|/path/two"` pre-fills the new disc.
        if let list = UserDefaults.standard.string(forKey: "addFolders"), !list.isEmpty {
            addFolders(list.split(separator: "|").map { URL(fileURLWithPath: String($0), isDirectory: true) })
        }
    }

    var par2Available: Bool { par2 != nil }
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
            let info = await service.lookup(setupFile: game.setupFile, folderName: game.name)
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

    func remove(_ game: GameFolder) {
        draft.games.removeAll { $0.id == game.id }
    }

    /// Why Burn is not available, or nil when it is.
    var burnBlocker: String? {
        if draft.games.isEmpty { return "Add game folders first." }
        if !draft.fits(par2Available: par2Available) { return "Too much for one \(draft.media.label)." }
        if discs.contains(where: { $0.id == draft.id }) { return "\(draft.id) is already in the archive." }
        if DiscID.split(draft.id) == nil { return "Use an ID like GOG-014." }
        if isSimulating { return nil }
        let s = drive.state
        if !s.hasDrive { return "Connect a burner." }
        if !s.mediaPresent { return "Insert a blank \(draft.media.label)." }
        if !s.ready(for: draft.media) {
            if let m = s.media, s.blank { return "The disc in the drive is a \(m.label)." }
            return "Insert a blank \(draft.media.label)."
        }
        return nil
    }

    func startBurn() {
        guard burnBlocker == nil else { return }
        let writer: DiscWriter
        if let folder = simulateFolder {
            writer = FolderWriter(folder: folder)
        } else if let device = drive.device {
            writer = DiscRecordingWriter(device: device)
        } else {
            alert = "No burner found."
            return
        }
        let plan = BurnPlan(id: draft.id, media: draft.media, speed: draft.speed,
                            recoveryPercent: draft.recoveryPercent, games: draft.games)
        let job = BurnJob(plan: plan, par2Available: par2Available)
        self.job = job
        job.start(writer: writer, par2: par2, paths: paths) { [weak self] record in
            self?.upsert(record)
        }
    }

    /// Leave the burn screens. A verified disc clears the draft; a failed one keeps it for another try.
    func closeJob() {
        guard let job, !job.isRunning else { return }
        switch job.outcome {
        case .verified, .damaged:
            draft = DiscDraft(id: DiscID.next(after: discs.map(\.id)), media: draft.media,
                              recoveryPercent: draft.recoveryPercent, speed: draft.speed)
        default:
            break
        }
        self.job = nil
    }

    func showInArchive(_ id: String) {
        closeJob()
        selectedDisc = id
        screen = .archive
    }

    func printCover(_ id: String) {
        showInArchive(id)
        coverRequest = [id]
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
