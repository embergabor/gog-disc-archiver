import AppKit
import Foundation

/// Finds games in GOG's public catalog and fetches cover art, as the Steam Deck GOG installer does.
/// No login. Only exact title matches are used: a wrong cover is worse than none.
extension Array {
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}

struct GameInfoService: Sendable {
    /// `~/Archive/Info`: one JSON file per lookup, and art per GOG product id.
    var cacheRoot: URL

    var artRoot: URL { cacheRoot.appendingPathComponent("Art", isDirectory: true) }

    // MARK: - Lookup

    /// Looks up a game folder by, in order: its installer's file name, the product name inside the
    /// installer, and the folder name. GOG renames games ("Game of the Year Edition" became
    /// "Remastered"), so shorter search terms are tried too, but a match must still be exact.
    func lookup(setupFile: String?, productName: String? = nil, folderName: String) async -> GameInfo? {
        var names: [String] = []
        if let setupFile { names.append(InstallerName.parse(setupFile).name.replacingOccurrences(of: "_", with: " ")) }
        if let productName { names.append(productName) }
        names.append(folderName)
        names = names.filter { !InstallerName.normalize($0).isEmpty }
        for name in names {
            if let cached = cached(InstallerName.normalize(name)) { return cached }
        }
        let terms = names.flatMap(Self.searchTerms).uniqued(by: { $0.lowercased() })
        var found: GameInfo?
        // Exact title matches first everywhere; only then a GOG title whose main part (before ":" or " - ")
        // is exactly the installer's name ("Gabriel Knight 3" → "Gabriel Knight 3: Blood of the Sacred…").
        search: for relaxed in [false, true] {
            // 1. GOG's store catalog: games on sale today.
            for term in terms {
                if let hit = try? await catalogMatch(term: term, names: names, relaxed: relaxed) { found = hit; break search }
            }
            // 2. Delisted games are gone from the store search but still in your GOG library. GOG Database
            //    (gogdb.org) lists every product id; GOG's own game API still serves their box art by id.
            for term in terms {
                if let id = try? await gogDBMatch(term: term, names: names, relaxed: relaxed), let hit = try? await gameByID(id) {
                    found = hit
                    break search
                }
            }
        }
        guard var info = found else { return nil }
        info.summary = try? await summary(gogID: info.gogID)
        // The installer's product name and GOG's title are reliable; a title guessed from the setup file name
        // ("Baldurs Gate" for The Original Saga) is only used when the installer has no product name.
        var titles = [info.title]
        if let productName { titles.append(productName) } else if let setupFile { titles.append(InstallerName.title(setupFile)) }
        info.steamAppID = await steamMatch(titles: titles, editionOf: info.title)
        for n in names { store(info, key: InstallerName.normalize(n)) }
        return info
    }

    /// Product id from GOG Database's search, for an exact title match (delisted games included).
    func gogDBMatch(term: String, names: [String], relaxed: Bool = false) async throws -> String? {
        var parts = URLComponents(string: "https://www.gogdb.org/products")!
        parts.queryItems = [URLQueryItem(name: "search", value: term)]
        let html = String(decoding: try await Self.get(parts.url!), as: UTF8.self)
        let wanted = Set(names.map(InstallerName.normalize))
        let rows = Self.parseGogDB(html)
        if relaxed { return Self.single(rows.filter { Self.looseMatch($0.title, wanted) })?.id }
        return rows.first { wanted.contains(InstallerName.normalize($0.title)) }?.id
    }

    /// The only loose candidate, or none: "Fallout" loosely fits both "Fallout: New Vegas" and
    /// "Fallout: A Post Nuclear Role Playing Game", and a wrong cover is worse than none.
    static func single<T>(_ candidates: [T]) -> T? {
        candidates.count == 1 ? candidates[0] : nil
    }

    /// A store title whose part before " - " ("The Elder Scrolls IV: Oblivion") or before ":"
    /// ("Gabriel Knight 3") is exactly one of the wanted names.
    static func looseMatch(_ title: String, _ wanted: Set<String>) -> Bool {
        wanted.contains(InstallerName.normalize(baseTitle(title))) || wanted.contains(InstallerName.normalize(mainTitle(title)))
    }

    /// The main part of a store title: "Gabriel Knight 3: Blood of the Sacred" → "Gabriel Knight 3".
    static func mainTitle(_ title: String) -> String {
        var s = baseTitle(title)
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// (id, title) rows of a GOG Database product list.
    static func parseGogDB(_ html: String) -> [(id: String, title: String)] {
        let pattern = try! NSRegularExpression(
            pattern: #"<td class="col-id">\s*<a[^>]*href="/product/(\d+)"[^>]*>.*?<td class="col-name[^"]*">\s*<a[^>]*>\s*(.*?)\s*</a>"#,
            options: [.dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        return pattern.matches(in: html, range: range).compactMap { m in
            guard let id = Range(m.range(at: 1), in: html), let title = Range(m.range(at: 2), in: html) else { return nil }
            return (String(html[id]), plainText(String(html[title])))
        }
    }

    /// Game data and box art by GOG product id, from the API GOG Galaxy uses. Works for delisted games.
    func gameByID(_ id: String) async throws -> GameInfo {
        let data = try await Self.get(URL(string: "https://api.gog.com/v2/games/\(id)?locale=en-US")!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let links = root["_links"] as? [String: Any] ?? [:]
        let embedded = root["_embedded"] as? [String: Any] ?? [:]
        let product = embedded["product"] as? [String: Any] ?? [:]
        func href(_ key: String) -> String? { (links[key] as? [String: Any])?["href"] as? String }
        func names(_ key: String) -> [String] {
            (embedded[key] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        var release: String?
        if let date = (product["globalReleaseDate"] ?? product["gogReleaseDate"]) as? String, date.count >= 10 {
            release = String(date.prefix(10)).replacingOccurrences(of: "-", with: ".")
        }
        let publisher = (embedded["publisher"] as? [String: Any])?["name"] as? String
        let systems = (embedded["supportedOperatingSystems"] as? [[String: Any]] ?? [])
            .compactMap { ($0["operatingSystem"] as? [String: Any])?["name"] as? String }
        return GameInfo(gogID: id,
                        title: InstallerName.cleanStoreTitle(product["title"] as? String ?? ""),
                        developers: names("developers").map(InstallerName.cleanStoreTitle),
                        publishers: publisher.map { [InstallerName.cleanStoreTitle($0)] } ?? [],
                        releaseDate: release,
                        genres: Array(names("tags").prefix(3)),
                        operatingSystems: systems,
                        coverVertical: href("boxArtImage").flatMap(Self.verticalCover),
                        coverHorizontal: href("backgroundImage").flatMap(URL.init(string:)),
                        logo: href("logo").flatMap(URL.init(string:)))
    }

    /// GOG image URLs take a size suffix; the Galaxy vertical cover is the portrait box art (342×482).
    static func verticalCover(_ href: String) -> URL? {
        guard !href.contains("_glx_vertical_cover"), let dot = href.lastIndex(of: "."), href[dot...].count <= 5 else { return URL(string: href) }
        return URL(string: href[..<dot] + "_glx_vertical_cover" + href[dot...])
    }

    /// The full name, the part before the first " - " / ":" / "—", and the first four words.
    static func searchTerms(_ name: String) -> [String] {
        let clean = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        var terms = [clean]
        let base = Self.baseTitle(clean)
        if base != clean { terms.append(base) }
        let words = clean.split(separator: " ").filter { $0 != "-" }
        if words.count > 4 { terms.append(words.prefix(4).joined(separator: " ")) }
        return terms
    }

    /// "The Witcher 3: Wild Hunt — Remastered" → "The Witcher 3: Wild Hunt"; also cuts at " - " and " – ".
    static func baseTitle(_ title: String) -> String {
        var s = title
        for sep in [" — ", " – ", " - "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    struct CatalogProduct: Decodable {
        struct Named: Decodable { var name: String }
        var id: String
        var slug: String?
        var title: String?
        var developers: [String]?
        var publishers: [String]?
        var releaseDate: String?
        var genres: [Named]?
        var operatingSystems: [String]?
        var coverVertical: String?
        var coverHorizontal: String?
        var logo: String?
    }

    private struct CatalogPage: Decodable { var products: [CatalogProduct] }

    /// The product whose slug or title equals the name, ignoring case, spaces and punctuation.
    static func matchCatalog(_ name: String, products: [CatalogProduct]) -> CatalogProduct? {
        let want = InstallerName.normalize(name)
        guard !want.isEmpty else { return nil }
        return products.first { p in
            InstallerName.normalize(p.slug ?? "") == want || InstallerName.normalize(p.title ?? "") == want
        }
    }

    func catalogMatch(_ name: String) async throws -> GameInfo? {
        try await catalogMatch(term: name, names: [name], relaxed: false)
    }

    /// Searches GOG for `term` and returns the product whose slug or title exactly matches any of `names`.
    func catalogMatch(term: String, names: [String], relaxed: Bool) async throws -> GameInfo? {
        let name = term
        var parts = URLComponents(string: "https://catalog.gog.com/v1/catalog")!
        parts.queryItems = [
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "query", value: "like:" + name),
            URLQueryItem(name: "order", value: "desc:score"),
            URLQueryItem(name: "productType", value: "in:game,pack"),
        ]
        let data = try await Self.get(parts.url!)
        let page = try JSONDecoder().decode(CatalogPage.self, from: data)
        let exact = names.lazy.compactMap { Self.matchCatalog($0, products: page.products) }.first
        let wanted = Set(names.map(InstallerName.normalize))
        let loose = relaxed ? Self.single(page.products.filter { Self.looseMatch($0.title ?? "", wanted) }) : nil
        guard let p = relaxed ? loose : exact else { return nil }
        return GameInfo(gogID: p.id,
                        title: InstallerName.cleanStoreTitle(p.title ?? name),
                        developers: (p.developers ?? []).map(InstallerName.cleanStoreTitle),
                        publishers: (p.publishers ?? []).map(InstallerName.cleanStoreTitle),
                        releaseDate: p.releaseDate,
                        genres: (p.genres ?? []).map(\.name),
                        operatingSystems: p.operatingSystems ?? [],
                        coverVertical: p.coverVertical.flatMap(Self.verticalCover),
                        coverHorizontal: p.coverHorizontal.flatMap(URL.init(string:)),
                        logo: p.logo.flatMap(URL.init(string:)))
    }

    /// GOG's short description ("lead"), as plain text.
    func summary(gogID: String) async throws -> String? {
        let data = try await Self.get(URL(string: "https://api.gog.com/products/\(gogID)?expand=description")!)
        struct Product: Decodable {
            struct Description: Decodable { var lead: String? }
            var description: Description?
        }
        guard let lead = try JSONDecoder().decode(Product.self, from: data).description?.lead else { return nil }
        let text = Self.plainText(lead)
        return text.isEmpty ? nil : text
    }

    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Steam app id whose name exactly matches one of the titles, for its 600×900 portrait cover.
    /// Steam's search misses some full names ("Disco Elysium - The Final Cut"), so the part before
    /// " - " or ":" is searched too, but the match itself stays exact.
    func steamMatch(titles: [String], editionOf gogTitle: String? = nil) async -> Int? {
        // Editions share the base game's Steam page: GOG's "… — Remastered" also matches "The Witcher 3: Wild Hunt".
        // Only GOG's title is cut this way; cutting the installer's name would turn
        // "Baldur's Gate - The Original Saga" into "Baldur's Gate".
        let wanted = Set((titles + [gogTitle].compactMap { $0 }.map(Self.baseTitle)).map(InstallerName.normalize).filter { !$0.isEmpty })
        var terms: [String] = []
        for title in titles {
            terms.append(title)
            if let short = title.components(separatedBy: CharacterSet(charactersIn: ":–")).first?
                .components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces), !short.isEmpty {
                terms.append(short)
            }
        }
        let full = Set(titles.map(InstallerName.normalize).filter { !$0.isEmpty })
        let unique = terms.uniqued { $0.lowercased() }
        for term in unique {
            if let id = try? await steamApp(term: term, matching: wanted) { return id }
        }
        // "Fallout 2" → "Fallout 2: A Post Nuclear Role Playing Game", only after no exact match.
        for term in unique {
            if let id = try? await steamApp(term: term, matching: full, relaxed: true) { return id }
        }
        return nil
    }

    func steamApp(term: String, matching wanted: Set<String>, relaxed: Bool = false) async throws -> Int? {
        var parts = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        parts.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "l", value: "english"), URLQueryItem(name: "cc", value: "US")]
        let data = try await Self.get(parts.url!)
        struct Search: Decodable {
            struct Item: Decodable { var type: String?; var name: String?; var id: Int }
            var items: [Item]
        }
        let apps = try JSONDecoder().decode(Search.self, from: data).items.filter { $0.type == "app" }
        // Steam names often add a colon subtitle that is a different game ("Fallout" → "Fallout: New Vegas"),
        // so for Steam only an edition suffix after " - " or " — " may be dropped.
        if relaxed { return Self.single(apps.filter { wanted.contains(InstallerName.normalize(Self.baseTitle($0.name ?? ""))) })?.id }
        return apps.first { wanted.contains(InstallerName.normalize($0.name ?? "")) }?.id
    }

    // MARK: - Art

    struct Art: Sendable {
        /// Portrait box art (Steam 600×900, else GOG 342×482).
        var portrait: URL?
        /// GOG's wide key art with the logo, 1600×740.
        var wide: URL?
    }

    /// Downloads (once) and returns local copies of the art for a game.
    func art(for info: GameInfo) async -> Art {
        let folder = artRoot.appendingPathComponent(info.gogID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var art = Art()
        var portraitSources: [URL] = []
        if let steam = info.steamAppID {
            portraitSources.append(URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(steam)/library_600x900_2x.jpg")!)
        }
        if let gog = info.coverVertical {
            portraitSources.append(Self.verticalCover(gog.absoluteString) ?? gog)
            portraitSources.append(URL(string: gog.absoluteString.replacingOccurrences(of: "_glx_vertical_cover", with: "")) ?? gog)
        }
        art.portrait = await download(portraitSources, to: folder.appendingPathComponent(Self.portraitName(info)))
        if let wide = info.coverHorizontal {
            art.wide = await download([wide], to: folder.appendingPathComponent("wide"))
        }
        return art
    }

    /// The first source that gives a real image, saved as `<base>.jpg` or `.png`. Reuses an earlier download.
    private func download(_ sources: [URL], to base: URL) async -> URL? {
        for ext in ["jpg", "png"] {
            let existing = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: existing.path) { return existing }
        }
        for source in sources {
            guard let data = try? await Self.get(source), let ext = Self.imageExtension(data) else { continue }
            let url = base.appendingPathExtension(ext)
            if (try? data.write(to: url, options: .atomic)) != nil { return url }
        }
        return nil
    }

    /// "portrait-steam292030" or "portrait-gog": the file changes when the source does.
    static func portraitName(_ info: GameInfo) -> String {
        "portrait-" + (info.steamAppID.map { "steam\($0)" } ?? "gog")
    }

    static func imageExtension(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        return nil
    }

    // MARK: - Cache and HTTP

    /// Bumped when matching rules change, so older (possibly wrong) lookups are made again.
    static let cacheVersion = "v3"

    private func cacheFile(_ key: String) -> URL {
        cacheRoot.appendingPathComponent(Self.cacheVersion, isDirectory: true).appendingPathComponent(key + ".json")
    }

    private func cached(_ key: String) -> GameInfo? {
        guard let data = try? Data(contentsOf: cacheFile(key)) else { return nil }
        return try? JSONDecoder().decode(GameInfo.self, from: data)
    }

    private func store(_ info: GameInfo, key: String) {
        try? FileManager.default.createDirectory(at: cacheFile(key).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: cacheFile(key), options: .atomic) }
    }

    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 GOGDiscArchiver", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
