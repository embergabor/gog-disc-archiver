import Foundation

/// What GOG's public catalog knows about a game. Stored in the catalogue so covers can be made later.
struct GameInfo: Codable, Hashable, Sendable {
    var gogID: String
    var title: String
    var developers: [String] = []
    var publishers: [String] = []
    /// "1998.09.30", as GOG writes it.
    var releaseDate: String?
    var genres: [String] = []
    var operatingSystems: [String] = []
    var coverVertical: URL?
    var coverHorizontal: URL?
    var logo: URL?
    var steamAppID: Int?
    /// GOG's short description, plain text.
    var summary: String?

    var year: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }

    /// "Interplay · 1998"
    var byline: String {
        var parts: [String] = []
        if let dev = developers.first { parts.append(dev) }
        if let year { parts.append(year) }
        return parts.joined(separator: " · ")
    }
}

/// GOG installer file names, parsed the same way as the Steam Deck GOG installer does.
enum InstallerName {
    /// setup_hollow_knight_1.5.12620_(64bit)_(89718).exe → ("hollow_knight", "1.5.12620")
    static func parse(_ file: String) -> (name: String, version: String) {
        var stem = (file as NSString).lastPathComponent
        stem = stem.replacingOccurrences(of: #"\.exe$"#, with: "", options: [.regularExpression, .caseInsensitive])
        stem = stem.replacingOccurrences(of: #"^setup_"#, with: "", options: [.regularExpression, .caseInsensitive])
        // Cut at the version, not at any number: keep the 2 in baldurs_gate_2_v2.6.
        let split = try! NSRegularExpression(pattern: #"_(?=v?\d+\.\d|v\d|\d{4,}|\()"#)
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = split.firstMatch(in: stem, range: range), let cut = Range(match.range, in: stem) else {
            return (stem, "")
        }
        let name = String(stem[..<cut.lowerBound])
        var version = String(stem[cut.upperBound...])
        // GOG's download number and the bitness aren't part of the build name.
        version = version.replacingOccurrences(of: #"_\((?:\d+|\d+bit)\)"#, with: "", options: .regularExpression)
        return (name, version)
    }

    /// setup_the_lord_of_the_rings_2.0_(1).exe → "The Lord of the Rings"
    static func title(_ file: String) -> String {
        let words = parse(file).name.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
        let small: Set<String> = ["a", "an", "and", "at", "for", "in", "of", "on", "or", "the", "to"]
        return words.enumerated().map { i, w in
            i == 0 || !small.contains(w) ? w.prefix(1).uppercased() + w.dropFirst() : w
        }.joined(separator: " ")
    }

    /// The base game's installer in a folder: the shortest `setup_*.exe` at the top level (DLC names are longer).
    static func setupFile(in relativePaths: [String]) -> String? {
        relativePaths
            .filter { !$0.contains("/") }
            .filter { $0.range(of: #"^setup_.*\.exe$"#, options: [.regularExpression, .caseInsensitive]) != nil }
            .min { ($0.count, $0) < ($1.count, $1) }
    }

    /// Letters and digits only, lower case: how titles are compared.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) && $0.isASCII || CharacterSet.decimalDigits.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// Store titles without ® and ™.
    static func cleanStoreTitle(_ s: String) -> String {
        s.replacingOccurrences(of: "[®™]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
