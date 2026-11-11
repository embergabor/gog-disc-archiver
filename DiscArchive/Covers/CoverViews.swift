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

    var spineText: String {
        guard games.count == 1 else { return "\(games.count) games" }
        return games[0].title + (games[0].edition.map { " · " + $0 } ?? "")
    }
}

enum CoverStyle {
    static let ink = Color(hex: 0x111111)
    static let paper = Color.white
    static let grey = Color(hex: 0x555555)
    static let rule = Color(hex: 0xBDBDBD)

    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .monospaced) }

    /// Gaussian blur for the backdrop, made once as a bitmap so the PDF needs no live effects.
    static func backdrop(from image: NSImage?) -> NSImage? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(max(cg.width, cg.height)) / 40).cropped(to: input.extent)
        guard let out = CIContext().createCGImage(blurred, from: input.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Front

/// Box art: one game large over its own blurred art, several games as a grid of covers.
struct FrontArt: View {
    var disc: CoverDisc
    var size: CGSize

    var body: some View {
        ZStack {
            CoverStyle.ink
            if let backdrop = disc.backdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                Color.black.opacity(0.35)
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
        if let portrait = game.portrait {
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
            if let portrait = game.portrait {
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

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .padding(width * 0.08)
            .frame(width: width, height: height)
            .background(Color(hex: 0x2A2A2A))
            .overlay(Rectangle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// The dark band with the disc ID at the bottom of every front.
struct IDBand: View {
    var disc: CoverDisc
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("GOG ARCHIVE")
                    .font(.system(size: 6.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(disc.idText)
                        .font(CoverStyle.mono(height * 0.42))
                        .tracking(1.5)
                    if let part = disc.partText {
                        Text(part).font(CoverStyle.mono(height * 0.3))
                    }
                }
                .foregroundStyle(.white)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(disc.media)
                Text(DateText.day(disc.burned))
            }
            .font(.system(size: 7.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, mm(5))
        .frame(width: width, height: height)
        .background(CoverStyle.ink)
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

    var body: some View {
        ZStack {
            CoverStyle.ink
            HStack(spacing: 8) {
                Text(disc.label).font(CoverStyle.mono(15)).tracking(1.5)
                Text(disc.spineText).font(.system(size: 8.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: BDWrap.panel.height - mm(12))
            .rotationEffect(.degrees(-90))
        }
        .frame(width: BDWrap.spine, height: BDWrap.panel.height)
        .clipped()
    }
}

struct BDBack: View {
    var disc: CoverDisc

    var body: some View {
        let single = disc.games.count == 1
        let thumbW: CGFloat = disc.games.count <= 4 ? mm(15) : (disc.games.count <= 7 ? mm(11) : mm(8))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(disc.label).font(CoverStyle.mono(17)).tracking(1.2)
                Spacer()
                Text("CONTENTS").font(.system(size: 6.5, weight: .semibold)).tracking(1.2).foregroundStyle(CoverStyle.grey)
            }
            Text(disc.subtitle)
                .font(.system(size: 7.5))
                .foregroundStyle(CoverStyle.grey)
                .padding(.top, 2)
            Rectangle().fill(CoverStyle.ink).frame(height: 1.5).padding(.top, 6).padding(.bottom, 2)
            ForEach(disc.games) { game in
                HStack(alignment: .top, spacing: mm(3)) {
                    Group {
                        if let portrait = game.portrait {
                            Image(nsImage: portrait).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color(hex: 0xE6E6E6)
                        }
                    }
                    .frame(width: thumbW, height: thumbW * 1.5)
                    .clipped()
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(game.title).font(.system(size: 9.5, weight: .bold)).lineLimit(2)
                        if !game.byline.isEmpty {
                            Text(game.byline).font(.system(size: 7.5)).foregroundStyle(CoverStyle.grey)
                        }
                        if !game.genres.isEmpty {
                            Text(game.genres.prefix(3).joined(separator: " · ")).font(.system(size: 7)).foregroundStyle(CoverStyle.grey)
                        }
                        Text(game.details).font(.system(size: 7)).foregroundStyle(CoverStyle.grey)
                        if single, let summary = game.summary {
                            Text(summary)
                                .font(.system(size: 7.5))
                                .lineSpacing(1)
                                .foregroundStyle(Color(hex: 0x222222))
                                .lineLimit(14)
                                .padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                Rectangle().fill(CoverStyle.rule).frame(height: 0.5)
            }
            Spacer(minLength: 6)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(Array(disc.facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.0).foregroundStyle(CoverStyle.grey)
                        Text(fact.1)
                    }
                }
            }
            .font(.system(size: 7))
        }
        .foregroundStyle(CoverStyle.ink)
        .padding(.horizontal, mm(7))
        .padding(.vertical, mm(6.5))
        .frame(width: BDWrap.panel.width, height: BDWrap.panel.height, alignment: .topLeading)
        .background(CoverStyle.paper)
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
    case jewel, bluRay
    var id: String { rawValue }

    var label: String {
        switch self {
        case .jewel: "Jewel case front"
        case .bluRay: "Blu-ray case 14 mm"
        }
    }

    /// A4 portrait for jewel fronts (two per sheet), landscape for the Blu-ray wrap.
    var pageSize: CGSize {
        switch self {
        case .jewel: CGSize(width: 595.28, height: 841.89)
        case .bluRay: CGSize(width: 841.89, height: 595.28)
        }
    }

    var perPage: Int { self == .jewel ? 2 : 1 }

    var note: String {
        switch self {
        case .jewel: "Jewel case front inserts · 120 × 120 mm · print at 100% on A4 · cut on the corner marks"
        case .bluRay: "Blu-ray case cover, 14 mm spine · 271.7 × 148.4 mm · print at 100% on A4 · cut on the corner marks, fold at the spine marks"
        }
    }
}

/// Corner marks outside the edges, plus optional fold marks at the given x positions.
struct CropMarks: View {
    var size: CGSize
    var folds: [CGFloat] = []

    var body: some View {
        Path { p in
            let gap: CGFloat = 6, len: CGFloat = 14
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
                VStack(spacing: mm(14)) {
                    ForEach(discs.prefix(2)) { disc in
                        JewelFront(disc: disc)
                            .overlay(CropMarks(size: JewelFront.size))
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
