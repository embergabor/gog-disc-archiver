// Draws the app icon. Run: swift scripts/make-icon.swift GOGDiscArchiver/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

// App icon: a light disc with groove rings on the purple of the covers (#4B2A7F), macOS icon grid.
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Rounded square, 824 pt inside the 1024 canvas, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0x4B2A7F)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x6A45A6), rgb(0x3B1F66)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Disc.
    let c = CGPoint(x: 512, y: 512)
    let r: CGFloat = 300
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: rgb(0x1A0B33, 0.45))
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(rgb(0xF3EEFB)); ctx.fillPath()
    ctx.restoreGState()

    // Data area, a shade darker, with grooves (left out when too small to see).
    let dataR: CGFloat = 288, innerR: CGFloat = 118
    ctx.addEllipse(in: CGRect(x: c.x - dataR, y: c.y - dataR, width: 2 * dataR, height: 2 * dataR))
    ctx.addEllipse(in: CGRect(x: c.x - innerR, y: c.y - innerR, width: 2 * innerR, height: 2 * innerR))
    ctx.setFillColor(rgb(0xDCD1EE)); ctx.fillPath(using: .evenOdd)
    if px >= 64 {
        ctx.setStrokeColor(rgb(0x4B2A7F, 0.22)); ctx.setLineWidth(3)
        var gr = innerR + 22
        while gr < dataR - 8 {
            ctx.addEllipse(in: CGRect(x: c.x - gr, y: c.y - gr, width: 2 * gr, height: 2 * gr)); ctx.strokePath()
            gr += 22
        }
        // A light sheen across the disc.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - dataR, y: c.y - dataR, width: 2 * dataR, height: 2 * dataR)); ctx.clip()
        ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: -.pi / 4)
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: -70, y: 0), end: CGPoint(x: 70, y: 0), options: [])
        ctx.restoreGState()
    }

    // Hub: clear ring, then the hole showing the purple behind.
    let hubR: CGFloat = 88, holeR: CGFloat = 40
    ctx.addEllipse(in: CGRect(x: c.x - hubR, y: c.y - hubR, width: 2 * hubR, height: 2 * hubR))
    ctx.setStrokeColor(rgb(0x4B2A7F, 0.35)); ctx.setLineWidth(px >= 64 ? 4 : 10); ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: c.x - holeR, y: c.y - holeR, width: 2 * holeR, height: 2 * holeR))
    ctx.setFillColor(rgb(0x4B2A7F)); ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    render(px, to: out.appendingPathComponent("icon_\(px).png"))
}
