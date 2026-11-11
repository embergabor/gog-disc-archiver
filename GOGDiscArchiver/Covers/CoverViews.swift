import AppKit
import CoreImage
import SwiftUI

/// Millimetres to PDF points.
func mm(_ value: CGFloat) -> CGFloat { value * 72 / 25.4 }

/// One game as it appears on a cover.
struct CoverGame: Identifiable {
    var id: String
    var title: String
    var edition: String?
    var byline: String
    var genres: [String]
    var details: String
    var summary: String?
    var portrait: NSImage?
    var wide: NSImage?
    /// The box art lifted for print (see `CoverStyle.printReady`).
    var printPortrait: NSImage? = nil

    /// The art to draw: lifted for print when that option is on.
    func art(_ theme: CoverTheme) -> NSImage? {
        theme.brightenArt ? (printPortrait ?? portrait) : portrait
    }
}

/// One disc's cover content.
struct CoverDisc: Identifiable {
    var id: String
    /// "GOG-014" (the set's ID for a set disc) and "2/5" for a set disc.
    var idText: String
    var partText: String?
    var label: String { partText.map { "\(idText) \($0)" } ?? idText }
    var media: String
    var burned: Date
    var subtitle: String
    var facts: [(String, String)]
    var games: [CoverGame]
    /// Blurred, darkened art behind the front.
    var backdrop: NSImage?
    /// Black-and-white art for the duotone backdrop.
    var grayArt: NSImage? = nil

    var spineText: String {
        guard games.count == 1 else { return "\(games.count) games" }
        return games[0].title + (games[0].edition.map { " · " + $0 } ?? "")
    }
}

/// The cover's colours and what sits behind the box art on the front.
struct CoverTheme: Equatable {
    enum Backdrop: String, CaseIterable { case blur, flat, rings, duotone }

    /// The spine: always solid, so the ID reads on the shelf.
    var spineBase: Color
    var spineText: Color
    /// The front around the box art, and its ID band.
    var frontBase: Color
    var frontText: Color
    /// A thin line above the ID band, for a white front.
    var bandLine: Color?
    /// Disc-groove rings on the front.
    var ringColor: Color
    var ringOpacity: Double
    /// Lighter shade used to tint the duotone backdrop.
    var baseLight: Color
    /// Title cards for games with no box art.
    var tileBackground: Color
    var tileText: Color
    /// Back panel: ID, titles and the rule under the header.
    var backAccent: Color
    var backdrop: Backdrop
    /// Draw box art lifted for print.
    var brightenArt = false

    static let purpleBase = Color(hex: 0x4B2A7F)
    static let purpleLight = Color(hex: 0xC3B4E6)

    /// The chosen design (user, 2026-11-11): purple spine with white text, disc-groove rings around the
    /// box art, purple on white on the back. `inkSaver` turns the front white with purple text and rings.
    static func purple(inkSaver: Bool, brighten: Bool = true) -> CoverTheme {
        var theme = purpleBaseTheme(inkSaver: inkSaver)
        theme.brightenArt = brighten
        return theme
    }

    private static func purpleBaseTheme(inkSaver: Bool) -> CoverTheme {
        inkSaver
            ? CoverTheme(spineBase: purpleBase, spineText: .white,
                         frontBase: .white, frontText: purpleBase, bandLine: purpleBase,
                         ringColor: purpleBase, ringOpacity: 0.18, baseLight: purpleLight,
                         tileBackground: Color(hex: 0xEEE9F8), tileText: purpleBase,
                         backAccent: purpleBase, backdrop: .rings)
            : CoverTheme(spineBase: purpleBase, spineText: .white,
                         frontBase: purpleBase, frontText: .white, bandLine: nil,
                         ringColor: .white, ringOpacity: 0.12, baseLight: purpleLight,
                         tileBackground: Color(hex: 0x2E1A4F), tileText: .white,
                         backAccent: purpleBase, backdrop: .rings)
    }

    /// Ink saver is a remembered choice, read wherever covers are drawn or printed.
    static let inkSaverKey = "coverInkSaver"
    /// Brighten box art for print: on unless turned off.
    static let brightenKey = "coverBrightenArt"
    /// The cover type last chosen, shared by the enlarged preview and Print covers.
    static let kindKey = "coverKind"
    static var brightenSetting: Bool { UserDefaults.standard.object(forKey: brightenKey) as? Bool ?? true }
    static var current: CoverTheme {
        purple(inkSaver: UserDefaults.standard.bool(forKey: inkSaverKey), brighten: brightenSetting)
    }

    /// The first look: black spine and band, blurred art behind the covers. Kept for comparison.
    static let classic = CoverTheme(spineBase: Color(hex: 0x111111), spineText: .white,
                                    frontBase: Color(hex: 0x111111), frontText: .white, bandLine: nil,
                                    ringColor: .white, ringOpacity: 0.12, baseLight: Color(hex: 0x888888),
                                    tileBackground: Color(hex: 0x2A2A2A), tileText: .white,
                                    backAccent: Color(hex: 0x111111), backdrop: .blur)
}

private struct CoverThemeKey: EnvironmentKey {
    static var defaultValue: CoverTheme { CoverTheme.current }
}

extension EnvironmentValues {
    var coverTheme: CoverTheme {
        get { self[CoverThemeKey.self] }
        set { self[CoverThemeKey.self] = newValue }
    }
}

enum CoverStyle {
    static let ink = Color(hex: 0x111111)
    static let paper = Color.white
    static let grey = Color(hex: 0x555555)
    static let rule = Color(hex: 0xBCBCBC)

    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .monospaced) }

    /// Gaussian blur for the backdrop, made once as a bitmap so the PDF needs no live effects.
    static func backdrop(from image: NSImage?) -> NSImage? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(max(cg.width, cg.height)) / 40).cropped(to: input.extent)
        guard let out = CIContext().createCGImage(blurred, from: input.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Box art lifted for print so dark covers don't turn into solid ink (user's pick, option A):
    /// a gamma lift brightens shadows and midtones and keeps highlights, plus a little vibrance
    /// so the colours don't look washed out. Applied to cover art only, never to text or the purple.
    static func printReady(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let input = CIImage(cgImage: cg)
        let lifted = input
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.72])
            .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.15])
            .cropped(to: input.extent)
        guard let out = CIContext().createCGImage(lifted, from: input.extent) else { return image }
        return NSImage(cgImage: out, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Black-and-white, softened copy of the art for the duotone backdrop, made once as a bitmap.
    static func grayArt(from image: NSImage?) -> NSImage? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let gray = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 0.85])
        guard let out = CIContext().createCGImage(gray, from: input.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Thin concentric rings, like the grooves of a disc, drawn as vector lines.
struct DiscRings: View {
    var size: CGSize
    var color: Color
    var opacity: Double = 0.12

    var body: some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = hypot(size.width, size.height) / 2
        Path { p in
            var r: CGFloat = 14
            while r < maxR {
                p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                r += 3.2
            }
        }
        .stroke(color.opacity(opacity), lineWidth: 0.5)
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - Front

/// Box art: one game large over its own blurred art, several games as a grid of covers.
struct FrontArt: View {
    var disc: CoverDisc
    var size: CGSize
    @Environment(\.coverTheme) private var theme

    var body: some View {
        ZStack {
            theme.frontBase
            switch theme.backdrop {
            case .blur:
                if let backdrop = disc.backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .contentShape(Rectangle())
                    Color.black.opacity(0.35)
                }
            case .flat:
                EmptyView()
            case .rings:
                DiscRings(size: size, color: theme.ringColor, opacity: theme.ringOpacity)
            case .duotone:
                if let gray = disc.grayArt {
                    Image(nsImage: gray)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .colorMultiply(theme.baseLight)
                        .opacity(0.4)
                }
            }
            content
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder private var content: some View {
        let games = disc.games
        if games.count == 1 {
            single(games[0])
        } else {
            grid(games)
        }
    }

    @ViewBuilder private func single(_ game: CoverGame) -> some View {
        let inset = mm(6)
        if let portrait = game.art(theme) {
            Image(nsImage: portrait)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: size.width - 2 * inset, maxHeight: size.height - 2 * inset)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
        } else {
            TitleTile(title: game.title, width: size.width - 2 * inset, height: size.height - 2 * inset, fontSize: 22)
        }
    }

    /// Every game's cover, in the column count that makes the covers largest.
    static func gridLayout(count: Int, size: CGSize, gap: CGFloat) -> (cols: Int, rows: Int, tileW: CGFloat) {
        var best = (cols: 1, rows: count, tileW: CGFloat(0))
        for cols in 1...max(1, count) {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let w = min((size.width - CGFloat(cols + 1) * gap) / CGFloat(cols),
                        (size.height - CGFloat(rows + 1) * gap) / CGFloat(rows) / 1.5)
            if w > best.tileW { best = (cols, rows, w) }
        }
        return best
    }

    private func grid(_ games: [CoverGame]) -> some View {
        let count = games.count
        let gap = count > 12 ? mm(1.5) : mm(3)
        let layout = Self.gridLayout(count: count, size: size, gap: gap)
        let cols = layout.cols, rows = layout.rows
        let tileW = layout.tileW
        let tileH = tileW * 1.5
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(Array(games.enumerated()).filter { $0.offset / cols == r }, id: \.offset) { item in
                        tile(item.element, w: tileW, h: tileH)
                    }
                }
            }
        }
    }

    @ViewBuilder private func tile(_ game: CoverGame, w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            if let portrait = game.art(theme) {
                Image(nsImage: portrait)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)
                    .clipped()
            } else {
                TitleTile(title: game.title, width: w, height: h, fontSize: max(6, w / 9))
            }
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1.5)
    }
}

/// Stand-in when a game has no art: its title on a dark card.
struct TitleTile: View {
    var title: String
    var width: CGFloat
    var height: CGFloat
    var fontSize: CGFloat
    @Environment(\.coverTheme) private var theme

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(theme.tileText)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .padding(width * 0.08)
            .frame(width: width, height: height)
            .background(theme.tileBackground)
            .overlay(Rectangle().stroke(theme.tileText.opacity(0.25), lineWidth: 0.5))
    }
}

/// The dark band with the disc ID at the bottom of every front.
struct IDBand: View {
    var disc: CoverDisc
    var width: CGFloat
    var height: CGFloat
    @Environment(\.coverTheme) private var theme

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("GOG ARCHIVE")
                    .font(.system(size: 6.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.frontText.opacity(0.75))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(disc.idText)
                        .font(CoverStyle.mono(height * 0.42))
                        .tracking(1.5)
                    if let part = disc.partText {
                        Text(part).font(CoverStyle.mono(height * 0.3))
                    }
                }
                .foregroundStyle(theme.frontText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(disc.media)
                Text(DateText.day(disc.burned))
            }
            .font(.system(size: 7.5, weight: .medium))
            .foregroundStyle(theme.frontText.opacity(0.85))
        }
        .padding(.horizontal, mm(5))
        .frame(width: width, height: height)
        .background(theme.frontBase)
        .overlay(alignment: .top) {
            if let line = theme.bandLine {
                Rectangle().fill(line).frame(height: 1.5).padding(.horizontal, mm(5))
            }
        }
    }
}

/// Jewel case front insert, 120 × 120 mm.
struct JewelFront: View {
    var disc: CoverDisc
    static let size = CGSize(width: mm(120), height: mm(120))

    var body: some View {
        VStack(spacing: 0) {
            FrontArt(disc: disc, size: CGSize(width: Self.size.width, height: mm(98)))
            IDBand(disc: disc, width: Self.size.width, height: mm(22))
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

// MARK: - Blu-ray case wrap (14 mm spine)

enum BDWrap {
    static let panel = CGSize(width: mm(128.85), height: mm(148.4))
    static let spine = mm(14)
    static var size: CGSize { CGSize(width: panel.width * 2 + spine, height: panel.height) }
}

struct BDFront: View {
    var disc: CoverDisc

    var body: some View {
        VStack(spacing: 0) {
            FrontArt(disc: disc, size: CGSize(width: BDWrap.panel.width, height: mm(124)))
            IDBand(disc: disc, width: BDWrap.panel.width, height: mm(24.4))
        }
        .frame(width: BDWrap.panel.width, height: BDWrap.panel.height)
    }
}

/// Reads bottom to top, as on European cases.
struct BDSpine: View {
    var disc: CoverDisc
    @Environment(\.coverTheme) private var theme

    var body: some View {
        ZStack {
            theme.spineBase
            // The title starts as large as the ID and shrinks only as far as it must to fit the spine.
            HStack(spacing: 10) {
                Text(disc.label).font(CoverStyle.mono(15)).tracking(1.5)
                    .fixedSize()
                    .layoutPriority(1)
                Text(disc.spineText)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.spineText)
            .frame(width: BDWrap.panel.height - mm(12))
            .rotationEffect(.degrees(-90))
        }
        .frame(width: BDWrap.spine, height: BDWrap.panel.height)
        .clipped()
    }
}

/// The back of a cover: the game list and the disc's details. Used for the Blu-ray case back
/// (128.85 × 148.4 mm) and the inside of the jewel booklet (120 × 120 mm). The more games, and the
/// smaller the panel, the more compact the rows, so everything fits.
struct BackPanel: View {
    var disc: CoverDisc
    var size: CGSize
    @Environment(\.coverTheme) private var theme

    /// How much room there is compared with the Blu-ray back.
    private var room: CGFloat { size.height / BDWrap.panel.height }
    private var count: Int { disc.games.count }

    /// From roomiest to tightest. The first layout that fits the panel with the real titles is used.
    private enum Style { case full, medium, twoLine, wrappedLine, wrappedSmall, oneLine }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content(.full)
            content(.medium)
            content(.twoLine)
            content(.wrappedLine)
            content(.wrappedSmall)
            content(.oneLine)
        }
        .foregroundStyle(CoverStyle.ink)
        .padding(.horizontal, mm(room < 0.9 ? 6 : 7))
        .padding(.vertical, mm(room < 0.9 ? 5.5 : 6.5))
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(CoverStyle.paper)
        .clipped()
    }

    private func content(_ style: Style) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(disc.label).font(CoverStyle.mono(room < 0.9 ? 15 : 17)).tracking(1.2)
                    .foregroundStyle(theme.backAccent)
                Spacer()
                Text("CONTENTS").font(.system(size: 6.5, weight: .semibold)).tracking(1.2).foregroundStyle(CoverStyle.grey)
            }
            Text(disc.subtitle)
                .font(.system(size: 7.5))
                .foregroundStyle(CoverStyle.grey)
                .padding(.top, 2)
            Rectangle().fill(theme.backAccent).frame(height: 1.5).padding(.top, 6).padding(.bottom, 2)
            ForEach(disc.games) { game in
                switch style {
                case .oneLine: lineRow(game, wrap: false, small: true)
                case .wrappedLine: lineRow(game, wrap: true, small: false)
                case .wrappedSmall: lineRow(game, wrap: true, small: true)
                case .twoLine: twoLineRow(game)
                case .full, .medium: richRow(game, style: style)
                }
                Rectangle().fill(CoverStyle.rule).frame(height: 1)
            }
            Spacer(minLength: 6)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(Array(disc.facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.0).foregroundStyle(CoverStyle.grey)
                        Text(fact.1).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 7))
        }
    }

    /// Cover thumbnail, title, developer and year, genres, details; the description too when alone.
    private func richRow(_ game: CoverGame, style: Style) -> some View {
        let thumbW: CGFloat = style == .full ? mm(room < 0.9 ? 12 : 15) : mm(8.5)
        return HStack(alignment: .top, spacing: mm(3)) {
            Group {
                if let portrait = game.art(theme) {
                    Image(nsImage: portrait).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(hex: 0xE6E6E6)
                }
            }
            .frame(width: thumbW, height: thumbW * 1.5)
            .clipped()
            VStack(alignment: .leading, spacing: 1.5) {
                Text(game.title).font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(theme.backAccent)
                    .fixedSize(horizontal: false, vertical: true)
                if style == .full {
                    if !game.byline.isEmpty {
                        Text(game.byline).font(.system(size: 7.5)).foregroundStyle(CoverStyle.grey)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !game.genres.isEmpty {
                        Text(game.genres.prefix(3).joined(separator: " · ")).font(.system(size: 7)).foregroundStyle(CoverStyle.grey)
                    }
                } else {
                    Text(([game.byline] + game.genres.prefix(2)).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 7)).foregroundStyle(CoverStyle.grey)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(game.details).font(.system(size: 7)).foregroundStyle(CoverStyle.grey)
                    .fixedSize(horizontal: false, vertical: true)
                if count == 1, let summary = game.summary {
                    Text(summary)
                        .font(.system(size: 7.5))
                        .lineSpacing(1)
                        .foregroundStyle(Color(hex: 0x222222))
                        .lineLimit(Int(14 * room))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, style == .full ? 4 : 3)
    }

    /// Title on one line, everything else below it, wrapping as needed. No thumbnail.
    private func twoLineRow(_ game: CoverGame) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(game.title).font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(theme.backAccent)
                .fixedSize(horizontal: false, vertical: true)
            Text([game.byline, game.details].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 6.5)).foregroundStyle(CoverStyle.grey)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2.5)
    }

    /// Title in bold followed by the details; wraps onto further lines, or is cut to one line as a last resort.
    private func lineRow(_ game: CoverGame, wrap: Bool, small: Bool) -> some View {
        (Text(game.title).font(.system(size: small ? 7 : 7.5, weight: .bold)).foregroundColor(theme.backAccent)
         + Text("  " + [game.byline, game.details].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.system(size: small ? 6 : 6.5)).foregroundColor(CoverStyle.grey))
            .lineLimit(wrap ? nil : 1)
            .fixedSize(horizontal: false, vertical: wrap)
            .padding(.vertical, small ? 1.2 : 2)
    }
}

/// The Blu-ray case back.
struct BDBack: View {
    var disc: CoverDisc
    var body: some View { BackPanel(disc: disc, size: BDWrap.panel) }
}

/// Jewel case tray inlay, 151 × 118 mm: the back panel (games and details) between two 6.5 mm spines
/// that fold up along the sides of the tray. Both spines read bottom to top from outside the case.
struct JewelTray: View {
    var disc: CoverDisc
    static let spine = mm(6.5)
    static let size = CGSize(width: mm(151), height: mm(118))

    var body: some View {
        HStack(spacing: 0) {
            TraySpine(disc: disc)
            BackPanel(disc: disc, size: CGSize(width: Self.size.width - 2 * Self.spine, height: Self.size.height))
            TraySpine(disc: disc)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// A narrow jewel case spine: ID and title, the title shrinking only as far as it must.
struct TraySpine: View {
    var disc: CoverDisc
    @Environment(\.coverTheme) private var theme

    var body: some View {
        ZStack {
            theme.spineBase
            HStack(spacing: 7) {
                Text(disc.label).font(CoverStyle.mono(8.5)).tracking(0.8)
                    .fixedSize()
                    .layoutPriority(1)
                Text(disc.spineText)
                    .font(.system(size: 8.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.spineText)
            .frame(width: JewelTray.size.height - mm(8))
            .rotationEffect(.degrees(-90))
        }
        .frame(width: JewelTray.spine, height: JewelTray.size.height)
        .clipped()
    }
}

/// Jewel case booklet, printed flat: the inside panel (games and details) left, the front right.
/// Fold in half along the middle so the front faces out.
struct JewelBooklet: View {
    var disc: CoverDisc
    static let size = CGSize(width: JewelFront.size.width * 2, height: JewelFront.size.height)

    var body: some View {
        HStack(spacing: 0) {
            BackPanel(disc: disc, size: JewelFront.size)
            Rectangle().fill(Color(hex: 0xD0D0D0)).frame(width: 0.8)
            JewelFront(disc: disc)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

struct BDWrapView: View {
    var disc: CoverDisc

    var body: some View {
        HStack(spacing: 0) {
            BDBack(disc: disc)
            BDSpine(disc: disc)
            BDFront(disc: disc)
        }
        .frame(width: BDWrap.size.width, height: BDWrap.size.height)
    }
}

// MARK: - Print sheets (A4)

enum CoverKind: String, CaseIterable, Identifiable {
    case jewel, jewelTray, bluRay
    var id: String { rawValue }

    var label: String {
        switch self {
        case .jewel: "Jewel case booklet"
        case .jewelTray: "Jewel case front + tray"
        case .bluRay: "Blu-ray case 14 mm"
        }
    }

    /// One line for the Print covers sheet.
    var explanation: String {
        switch self {
        case .jewel: "Folding booklet, 240 × 120 mm: games and details inside, box art and ID on the front. Fold in half, no double-sided printing."
        case .jewelTray: "Front insert (120 × 120 mm) and the tray card behind the disc (151 × 118 mm) with games and details, and the ID on both spines."
        case .bluRay: "Box art and ID on the front, ID on the spine, games and disc details on the back."
        }
    }

    var fileWord: String {
        switch self {
        case .jewel: "jewel booklet"
        case .jewelTray: "jewel front and tray"
        case .bluRay: "bluray"
        }
    }

    /// The whole printed piece, for previews.
    var pieceSize: CGSize {
        switch self {
        case .jewel: JewelBooklet.size
        case .jewelTray: CGSize(width: JewelFront.size.width + mm(12) + JewelTray.size.width, height: JewelFront.size.height)
        case .bluRay: BDWrap.size
        }
    }

    /// Short name for pickers.
    var shortLabel: String {
        switch self {
        case .jewel: "Jewel booklet"
        case .jewelTray: "Jewel front + tray"
        case .bluRay: "Blu-ray case"
        }
    }

    /// A4 landscape: one folding jewel booklet (240 × 120 mm) or one Blu-ray wrap per sheet.
    var pageSize: CGSize { CGSize(width: 841.89, height: 595.28) }

    var perPage: Int { 1 }

    var note: String {
        switch self {
        case .jewel: "Jewel case booklet · 240 × 120 mm, folds to 120 × 120 · print at 100% on A4 · cut along the dotted lines, fold at the middle marks so the front faces out"
        case .jewelTray: "Jewel case front 120 × 120 mm and tray inlay 151 × 118 mm (6.5 mm spines) · print at 100% on A4 · cut along the dotted lines, fold the tray's spines at the marks"
        case .bluRay: "Blu-ray case cover, 14 mm spine · 271.7 × 148.4 mm · print at 100% on A4 · cut along the dotted lines, fold at the spine marks"
        }
    }
}

/// Corner marks outside the edges, optional fold marks at the given x positions, and a thin
/// dotted cut line along the trim edge.
struct CropMarks: View {
    var size: CGSize
    var folds: [CGFloat] = []
    var gap: CGFloat = 6
    var len: CGFloat = 14

    var body: some View {
        ZStack {
            // Dotted cut line on the trim edge; light enough to disappear in a slightly inside cut.
            Rectangle()
                .stroke(Color(hex: 0x808080), style: StrokeStyle(lineWidth: 0.6, dash: [1.5, 2.5]))
                .frame(width: size.width, height: size.height)
            marks
        }
        .frame(width: size.width, height: size.height)
    }

    private var marks: some View {
        Path { p in
            let w = size.width, h = size.height
            for (x, y, dx, dy) in [(0.0, 0.0, -1.0, -1.0), (w, 0.0, 1.0, -1.0), (0.0, h, -1.0, 1.0), (w, h, 1.0, 1.0)] {
                p.move(to: CGPoint(x: x + dx * gap, y: y)); p.addLine(to: CGPoint(x: x + dx * (gap + len), y: y))
                p.move(to: CGPoint(x: x, y: y + dy * gap)); p.addLine(to: CGPoint(x: x, y: y + dy * (gap + len)))
            }
            for x in folds {
                p.move(to: CGPoint(x: x, y: -gap)); p.addLine(to: CGPoint(x: x, y: -(gap + len)))
                p.move(to: CGPoint(x: x, y: h + gap)); p.addLine(to: CGPoint(x: x, y: h + gap + len))
            }
        }
        .stroke(Color.black, lineWidth: 0.5)
        .frame(width: size.width, height: size.height)
    }
}

struct CoverSheet: View {
    var kind: CoverKind
    var discs: [CoverDisc]

    var body: some View {
        let page = kind.pageSize
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            switch kind {
            case .jewel:
                if let disc = discs.first {
                    JewelBooklet(disc: disc)
                        .overlay(CropMarks(size: JewelBooklet.size, folds: [JewelFront.size.width]))
                }
            case .jewelTray:
                if let disc = discs.first {
                    // Shorter marks so the two pieces fit side by side on A4.
                    HStack(alignment: .center, spacing: mm(12)) {
                        JewelFront(disc: disc)
                            .overlay(CropMarks(size: JewelFront.size, gap: 4, len: 10))
                        JewelTray(disc: disc)
                            .overlay(CropMarks(size: JewelTray.size, folds: [JewelTray.spine, JewelTray.size.width - JewelTray.spine], gap: 4, len: 10))
                    }
                }
            case .bluRay:
                if let disc = discs.first {
                    BDWrapView(disc: disc)
                        .overlay(CropMarks(size: BDWrap.size, folds: [BDWrap.panel.width, BDWrap.panel.width + BDWrap.spine]))
                }
            }
            Spacer(minLength: 0)
            Text(kind.note)
                .font(.system(size: 7))
                .foregroundStyle(CoverStyle.grey)
                .padding(.bottom, mm(10))
        }
        .frame(width: page.width, height: page.height)
        .background(Color.white)
    }
}

/// A portrait cover for games with no store cover: their wide art cropped to 2:3, with the title on a band.
/// The same idea as the Steam Deck GOG installer's generated covers.
enum MadeCover {
    @MainActor
    static func from(wide: NSImage, title: String) -> NSImage? {
        let size = CGSize(width: 600, height: 900)
        let view = ZStack(alignment: .bottomLeading) {
            Image(nsImage: wide)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
            Text(title)
                .font(.system(size: 64, weight: .heavy))
                .foregroundStyle(Color(hex: 0xF4EFFF))
                .lineLimit(4)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 40)
                .padding(.vertical, 44)
                .frame(width: size.width, alignment: .leading)
                .background(Color(hex: 0x1C0F36).opacity(0.92))
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage
    }
}
