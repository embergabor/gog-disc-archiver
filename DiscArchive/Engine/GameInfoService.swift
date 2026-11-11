import AppKit
import Foundation

/// Finds games in GOG's public catalog and fetches cover art, as the Steam Deck GOG installer does.
/// No login. Only exact title matches are used: a wrong cover is worse than none.
struct GameInfoService: Sendable {
    /// `~/Archive/Info`: one JSON file per lookup, and art per GOG product id.
    var cacheRoot: URL

    var artRoot: URL { cacheRoot.appendingPathComponent("Art", isDirectory: true) }

    // MARK: - Lookup

    /// Looks up a game folder: first by its installer's name, then by the folder name.
    func lookup(setupFile: String?, folderName: String) async -> GameInfo? {
        var names: [String] = []
        if let setupFile { names.append(InstallerName.parse(setupFile).name.replacingOccurrences(of: "_", with: " ")) }
        names.append(folderName)
        for name in names {
            let key = InstallerName.normalize(name)
            guard !key.isEmpty else { continue }
            if let cached = cached(key) { return cached }
            if let found = try? await catalogMatch(name) {
                var info = found
                info.summary = try? await summary(gogID: info.gogID)
                var titles = [info.title]
                if let setupFile { titles.append(InstallerName.title(setupFile)) }
                info.steamAppID = await steamMatch(titles: titles)
                store(info, key: key)
                return info
            }
        }
        return nil
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
        var parts = URLComponents(string: "https://catalog.gog.com/v1/catalog")!
        parts.queryItems = [
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "query", value: "like:" + name),
            URLQueryItem(name: "order", value: "desc:score"),
            URLQueryItem(name: "productType", value: "in:game,pack"),
        ]
        let data = try await Self.get(parts.url!)
        let page = try JSONDecoder().decode(CatalogPage.self, from: data)
        guard let p = Self.matchCatalog(name, products: page.products) else { return nil }
        return GameInfo(gogID: p.id,
                        title: InstallerName.cleanStoreTitle(p.title ?? name),
                        developers: (p.developers ?? []).map(InstallerName.cleanStoreTitle),
                        publishers: (p.publishers ?? []).map(InstallerName.cleanStoreTitle),
                        releaseDate: p.releaseDate,
                        genres: (p.genres ?? []).map(\.name),
                        operatingSystems: p.operatingSystems ?? [],
                        coverVertical: p.coverVertical.flatMap(URL.init(string:)),
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
    func steamMatch(titles: [String]) async -> Int? {
        let wanted = Set(titles.map(InstallerName.normalize).filter { !$0.isEmpty })
        var terms: [String] = []
        for title in titles {
            terms.append(title)
            if let short = title.components(separatedBy: CharacterSet(charactersIn: ":–")).first?
                .components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces), !short.isEmpty {
                terms.append(short)
            }
        }
        var seen = Set<String>()
        for term in terms where seen.insert(term.lowercased()).inserted {
            if let id = try? await steamApp(term: term, matching: wanted) { return id }
        }
        return nil
    }

    func steamApp(term: String, matching wanted: Set<String>) async throws -> Int? {
        var parts = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        parts.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "l", value: "english"), URLQueryItem(name: "cc", value: "US")]
        let data = try await Self.get(parts.url!)
        struct Search: Decodable {
            struct Item: Decodable { var type: String?; var name: String?; var id: Int }
            var items: [Item]
        }
        return try JSONDecoder().decode(Search.self, from: data).items
            .first { $0.type == "app" && wanted.contains(InstallerName.normalize($0.name ?? "")) }?.id
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
        if let gog = info.coverVertical { portraitSources.append(gog) }
        art.portrait = await download(portraitSources, to: folder.appendingPathComponent("portrait"))
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

    static func imageExtension(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        return nil
    }

    // MARK: - Cache and HTTP

    private func cacheFile(_ key: String) -> URL {
        cacheRoot.appendingPathComponent(key + ".json")
    }

    private func cached(_ key: String) -> GameInfo? {
        guard let data = try? Data(contentsOf: cacheFile(key)) else { return nil }
        return try? JSONDecoder().decode(GameInfo.self, from: data)
    }

    private func store(_ info: GameInfo, key: String) {
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: cacheFile(key), options: .atomic) }
    }

    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 DiscArchive", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
