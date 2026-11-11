import DiscRecording
import Foundation
import Observation

/// What the burner and the disc in it look like right now.
struct DriveState: Equatable {
    var name: String?
    var mediaPresent = false
    var busy = false
    var blank = false
    var media: Media?
    var freeBytes: Int64 = 0

    var hasDrive: Bool { name != nil }
    /// Ready for a burn onto this media type.
    func ready(for media: Media) -> Bool { blank && !busy && self.media == media }

    var summary: String {
        guard let name else { return "No burner connected" }
        if busy { return name + " · busy" }
        if !mediaPresent { return name + " · no disc" }
        guard let media else { return name + " · disc not supported" }
        if !blank { return name + " · \(media.label) is not blank" }
        return name + " · blank \(media.longName) ready"
    }
}

/// Watches DiscRecording for burners coming and going and discs being inserted.
@MainActor
@Observable
final class DriveMonitor {
    private(set) var state = DriveState()
    @ObservationIgnored private var bridge: Bridge?

    init() {
        let bridge = Bridge(owner: self)
        self.bridge = bridge
        let center = DRNotificationCenter.currentRunLoop()
        center?.addObserver(bridge, selector: #selector(Bridge.changed(_:)), name: NSNotification.Name.DRDeviceAppeared.rawValue, object: nil)
        center?.addObserver(bridge, selector: #selector(Bridge.changed(_:)), name: NSNotification.Name.DRDeviceDisappeared.rawValue, object: nil)
        center?.addObserver(bridge, selector: #selector(Bridge.changed(_:)), name: NSNotification.Name.DRDeviceStatusChanged.rawValue, object: nil)
        refresh()
    }

    /// The first drive that can write DVDs or Blu-ray discs.
    var device: DRDevice? {
        let devices = (DRDevice.devices() as? [DRDevice]) ?? []
        return devices.first { $0.writesDVD() || Self.writesBD($0) }
    }

    func refresh() {
        guard let device else {
            state = DriveState()
            return
        }
        var s = DriveState(name: device.displayName() ?? "Burner")
        let status = (device.status() as? [String: Any]) ?? [:]
        s.busy = (status[DRDeviceIsBusyKey] as? Bool) ?? false
        s.mediaPresent = (status[DRDeviceMediaStateKey] as? String) == DRDeviceMediaStateMediaPresent
        if s.mediaPresent, let info = status[DRDeviceMediaInfoKey] as? [String: Any] {
            s.blank = (info[DRDeviceMediaIsBlankKey] as? Bool) ?? false
            let blocks = (info[DRDeviceMediaBlocksFreeKey] as? NSNumber)?.int64Value ?? 0
            s.freeBytes = blocks * 2048
            if let type = info[DRDeviceMediaTypeKey] as? String, let kind = Self.kind(of: type) {
                s.media = Media.from(kind: kind, blocks: blocks)
            }
        }
        state = s
    }

    static func kind(of type: String) -> Media.Kind? {
        switch type {
        case DRDeviceMediaTypeDVDPlusR, DRDeviceMediaTypeDVDR: .dvd
        case DRDeviceMediaTypeDVDPlusRDoubleLayer, DRDeviceMediaTypeDVDRDualLayer: .dvdDualLayer
        case DRDeviceMediaTypeBDR: .bluRay
        default: nil
        }
    }

    static func writesBD(_ device: DRDevice) -> Bool {
        let info = (device.info() as? [String: Any]) ?? [:]
        let caps = (info[DRDeviceWriteCapabilitiesKey] as? [String: Any]) ?? [:]
        return (caps[DRDeviceCanWriteBDRKey] as? Bool) ?? false
    }

    /// DiscRecording wants an Objective-C object to call back.
    private final class Bridge: NSObject {
        weak var owner: DriveMonitor?

        init(owner: DriveMonitor) {
            self.owner = owner
        }

        @objc func changed(_ note: Notification) {
            MainActor.assumeIsolated { owner?.refresh() }
        }
    }
}
