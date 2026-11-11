import AppKit
import DiscRecording
import Foundation

/// Something that puts a `DiscLayout` on a disc and returns where the result is mounted.
/// `progress` gets the fraction done and, when the drive reports it, the current write rate in bytes per second.
@MainActor
protocol DiscWriter: AnyObject {
    var driveName: String { get }
    var ejectsWhenDone: Bool { get }
    func write(_ layout: DiscLayout, media: Media, speed: Int, progress: @escaping @MainActor (Double, Double?) -> Void) async throws -> URL
}

enum WriteError: LocalizedError {
    case burnFailed(String)
    case notMounted(String)

    var errorDescription: String? {
        switch self {
        case .burnFailed(let detail): "The burn failed. \(detail)"
        case .notMounted(let name): "The disc was burned but \(name) did not appear in the Finder, so it could not be read back."
        }
    }
}

/// Burns with Apple's DiscRecording framework. The UDF file system is built on the fly from the
/// original files, so no disc image is made.
@MainActor
final class DiscRecordingWriter: NSObject, DiscWriter {
    let device: DRDevice
    private var burn: DRBurn?
    private var continuation: CheckedContinuation<Void, Error>?
    private var onProgress: (@MainActor (Double, Double?) -> Void)?

    init(device: DRDevice) {
        self.device = device
    }

    var driveName: String { device.displayName() ?? "Burner" }
    var ejectsWhenDone: Bool { true }

    func write(_ layout: DiscLayout, media: Media, speed: Int, progress: @escaping @MainActor (Double, Double?) -> Void) async throws -> URL {
        let root = try Self.makeTree(layout)
        guard let track = DRTrack(forRootFolder: root), let burn = DRBurn(device: device) else {
            throw WriteError.burnFailed("Could not prepare the disc layout.")
        }
        burn.setRequestedBurnSpeed(Float(speed) * media.oneXKBps)
        burn.setAppendable(false)
        burn.setVerifyDisc(false)
        burn.setCompletionAction(DRBurnCompletionActionMount)
        self.burn = burn
        self.onProgress = progress

        DRNotificationCenter.currentRunLoop().addObserver(self, selector: #selector(statusChanged(_:)),
                                                          name: NSNotification.Name.DRBurnStatusChanged.rawValue, object: burn)
        defer {
            DRNotificationCenter.currentRunLoop().removeObserver(self, name: NSNotification.Name.DRBurnStatusChanged.rawValue, object: burn)
            self.burn = nil
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                burn.writeLayout(track)
            }
        } onCancel: {
            Task { @MainActor in burn.abort() }
        }
        return try await Self.waitForMount(named: layout.volumeName, seconds: 120)
    }

    @objc private func statusChanged(_ note: Notification) {
        guard let status = note.userInfo else { return }
        let state = status[DRStatusStateKey] as? String
        if let percent = status[DRStatusPercentCompleteKey] as? Double, percent >= 0 {
            // The drive reports its current write speed in kilobytes (1000 bytes) per second.
            let info = status[DRStatusProgressInfoKey] as? [AnyHashable: Any]
            let kbps = (info?[DRStatusProgressCurrentKPS] as? NSNumber)?.doubleValue
            onProgress?(percent, kbps.flatMap { $0 > 0 ? $0 * 1000 : nil })
        }
        if state == DRStatusStateDone {
            continuation?.resume()
            continuation = nil
        } else if state == DRStatusStateFailed {
            let error = status[DRErrorStatusKey] as? [AnyHashable: Any]
            let text = (error?[DRErrorStatusErrorStringKey] as? String) ?? "The drive reported an error."
            continuation?.resume(throwing: WriteError.burnFailed(text))
            continuation = nil
        }
    }

    /// Builds the virtual folder tree DiscRecording burns from. Real files stay where they are.
    static func makeTree(_ layout: DiscLayout) throws -> DRFolder {
        guard let root = DRFolder(name: layout.volumeName) else { throw WriteError.burnFailed("Could not create the disc's top folder.") }
        root.setExplicitFilesystemMask(DRFilesystemInclusionMask(DRFilesystemInclusionMaskUDF))
        root.setSpecificName(layout.volumeName, forFilesystem: DRUDF)
        var folders: [String: DRFolder] = ["": root]

        func folder(for path: String) throws -> DRFolder {
            if let existing = folders[path] { return existing }
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent = try folder(for: parentPath)
            guard let made = DRFolder(name: (path as NSString).lastPathComponent) else {
                throw WriteError.burnFailed("Could not add the folder \(path).")
            }
            parent.addChild(made)
            folders[path] = made
            return made
        }

        for entry in layout.entries {
            let parent = try folder(for: (entry.path as NSString).deletingLastPathComponent)
            let name = (entry.path as NSString).lastPathComponent
            let made: DRFile?
            switch entry.source {
            case .file(let url): made = DRFile(path: url.path)
            case .data(let data): made = DRFile(name: name, data: data)
            }
            guard let file = made else { throw WriteError.burnFailed("Could not add \(entry.path).") }
            file.setBaseName(name)
            parent.addChild(file)
        }
        return root
    }

    static func waitForMount(named name: String, seconds: Int) async throws -> URL {
        for _ in 0..<(seconds * 2) {
            if let url = Verifier.mountedVolume(named: name) { return url }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw WriteError.notMounted(name)
    }
}

/// Development stand-in: "burns" by copying the layout into a folder, so the whole flow can be
/// tried without a drive or blank discs. Enabled with `-simulateBurn <folder>`.
@MainActor
final class FolderWriter: DiscWriter {
    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    var driveName: String { "Simulated burner" }
    var ejectsWhenDone: Bool { false }

    func write(_ layout: DiscLayout, media: Media, speed: Int, progress: @escaping @MainActor (Double, Double?) -> Void) async throws -> URL {
        let target = folder.appendingPathComponent(layout.volumeName, isDirectory: true)
        let entries = layout.entries
        let total = max(1, layout.totalBytes)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            var done: Int64 = 0
            for entry in entries {
                try Task.checkCancellation()
                let dest = target.appendingPathComponent(entry.path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch entry.source {
                case .file(let url): try fm.copyItem(at: url, to: dest)
                case .data(let data): try data.write(to: dest)
                }
                done += entry.size
                let fraction = Double(done) / Double(total)
                await MainActor.run { progress(fraction, nil) }
            }
        }.value
        return target
    }
}
