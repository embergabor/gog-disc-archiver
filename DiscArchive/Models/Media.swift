import Foundation

/// Recordable disc types the app writes. Capacities are the standard sector counts × 2048 bytes.
enum Media: String, CaseIterable, Codable, Identifiable, Sendable {
    case dvdR = "DVD+R"
    case dvdRDL = "DVD+R DL"
    case bd25 = "BD-R 25"
    case bd50 = "BD-R 50"
    case bdxl100 = "BDXL 100"

    var id: String { rawValue }

    /// Short label for buttons: "BD-R 25".
    var label: String {
        switch self {
        case .dvdR: "DVD+R 4.7"
        case .dvdRDL: "DVD+R DL 8.5"
        case .bd25: "BD-R 25"
        case .bd50: "BD-R 50"
        case .bdxl100: "BDXL 100"
        }
    }

    /// Long label for sentences: "BD-R 25 GB".
    var longName: String { label + " GB" }

    var sectors: Int64 {
        switch self {
        case .dvdR: 2_295_104
        case .dvdRDL: 4_173_824
        case .bd25: 12_219_392
        case .bd50: 24_438_784
        case .bdxl100: 48_878_592
        }
    }

    var capacity: Int64 { sectors * 2048 }

    /// What we allow ourselves to fill: the file system and the `_archive` folder need some room.
    var usable: Int64 { capacity - max(48 << 20, capacity / 400) }

    var isBluRay: Bool { self == .bd25 || self == .bd50 || self == .bdxl100 }

    /// 1× in kilobytes per second, the unit DiscRecording uses for burn speeds.
    var oneXKBps: Float { isBluRay ? 4495.5 : 1385.0 }

    /// Speeds offered in the UI. The drive may still pick the nearest one it supports.
    var speeds: [Int] { isBluRay ? [2, 4, 6] : [4, 8] }
    var recommendedSpeed: Int { isBluRay ? 4 : 8 }

    enum Kind { case dvd, dvdDualLayer, bluRay }

    /// Maps what the drive reports for an inserted write-once disc to one of ours.
    /// `blocks` is the free block count (the whole disc when it is blank).
    static func from(kind: Kind, blocks: Int64) -> Media {
        switch kind {
        case .dvd: return .dvdR
        case .dvdDualLayer: return .dvdRDL
        case .bluRay:
            if blocks <= Media.bd25.sectors + 200_000 { return .bd25 }
            if blocks <= Media.bd50.sectors + 400_000 { return .bd50 }
            return .bdxl100
        }
    }
}

enum ByteText {
    /// Decimal gigabytes, one decimal place: "21.9 GB".
    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }

    static func gbNumber(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1e9)
    }
}

extension ByteText {
    /// "1 file", "6 files".
    static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}
