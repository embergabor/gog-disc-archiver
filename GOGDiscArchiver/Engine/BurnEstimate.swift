import Foundation

/// Rough timings for planning a burn. Write rates are the disc standards' nominal speeds;
/// the read-back and checksum rates are deliberately cautious guesses for USB drives.
enum BurnEstimate {
    /// Bytes per second written at a given speed: BD 1× = 4.5 MB/s, DVD 1× = 1.385 MB/s.
    static func writeRate(_ media: Media, speed: Int) -> Double {
        Double(media.oneXKBps) * 1000 * Double(speed)
    }

    /// Reading the burned disc back: about 4× on Blu-ray, 6× on DVD.
    static func readRate(_ media: Media) -> Double {
        media.isBluRay ? 18_000_000 : 8_000_000
    }

    /// Hashing the source files on the Mac's own drive.
    static let checksumRate: Double = 120_000_000

    /// Drive start-up, lead-in and closing the disc.
    static let burnOverhead: TimeInterval = 75

    static func burnSeconds(bytes: Int64, media: Media, speed: Int) -> TimeInterval {
        Double(bytes) / writeRate(media, speed: speed) + burnOverhead
    }

    static func readBackSeconds(bytes: Int64, media: Media) -> TimeInterval {
        Double(bytes) / readRate(media)
    }

    static func checksumSeconds(bytes: Int64) -> TimeInterval {
        Double(bytes) / checksumRate
    }

    /// Everything for one disc: checksums, burn and read-back.
    static func discSeconds(bytes: Int64, media: Media, speed: Int) -> TimeInterval {
        checksumSeconds(bytes: bytes) + burnSeconds(bytes: bytes, media: media, speed: speed) + readBackSeconds(bytes: bytes, media: media)
    }

    /// "18.0 MB/s"
    static func rateText(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }

    /// "about 22 min", "about 1 h 05 min", "under a minute"
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "under a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "about \(minutes) min" }
        return String(format: "about %d h %02d min", minutes / 60, minutes % 60)
    }
}
