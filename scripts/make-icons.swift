// Generates the app icon (.icns) and Chrome extension icons from vector shapes.
// Usage: swift scripts/make-icons.swift   (run from the repo root)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// Draws the mark into a square of `size`. `inset` is the transparent margin around the tile.
func drawIcon(size: CGFloat, inset: CGFloat, macTile: Bool) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let s = tile.width
    let radius = s * (macTile ? 0.225 : 0.22)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Tile: deep indigo → violet → warm coral, like a sunset behind album art.
    if macTile {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let colors = [NSColor(srgbRed: 0.16, green: 0.10, blue: 0.36, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.55, green: 0.20, blue: 0.62, alpha: 1).cgColor,
                  NSColor(srgbRed: 1.00, green: 0.52, blue: 0.42, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // Soft highlight.
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: tile.minX + s * 0.25, y: tile.maxY - s * 0.2), startRadius: 0,
                           endCenter: CGPoint(x: tile.minX + s * 0.25, y: tile.maxY - s * 0.2), endRadius: s * 0.7, options: [])
    ctx.restoreGState()

    // Mark: a floating "now playing" card — artwork square + two lyric lines — with a play glyph.
    let small = size <= 32
    let card = CGRect(x: tile.minX + s * 0.16, y: tile.minY + s * 0.26, width: s * 0.68, height: s * 0.48)
    let cardR = s * 0.09
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: cardR, cornerHeight: cardR, transform: nil))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor); ctx.fillPath()
    ctx.restoreGState()

    let pad = card.height * 0.17
    let art = CGRect(x: card.minX + pad, y: card.minY + pad, width: card.height - pad * 2, height: card.height - pad * 2)
    let artR = art.width * 0.2
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: art, cornerWidth: artR, cornerHeight: artR, transform: nil)); ctx.clip()
    let artGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.40, alpha: 1).cgColor,
                                      NSColor(srgbRed: 0.42, green: 0.17, blue: 0.62, alpha: 1).cgColor] as CFArray,
                             locations: [0, 1])!
    ctx.drawLinearGradient(artGrad, start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
    ctx.restoreGState()
    // Eighth note inside the artwork (deliberately not a play triangle: avoids resembling the YouTube logo).
    let u = art.width
    let head = CGRect(x: art.minX + u * 0.24, y: art.minY + u * 0.2, width: u * 0.3, height: u * 0.24)
    ctx.saveGState()
    ctx.translateBy(x: head.midX, y: head.midY); ctx.rotate(by: 0.35); ctx.translateBy(x: -head.midX, y: -head.midY)
    ctx.addEllipse(in: head); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    let stemX = head.maxX - u * 0.045
    let stem = CGRect(x: stemX, y: head.midY, width: u * 0.075, height: u * 0.5)
    ctx.addRect(stem); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    let flag = CGMutablePath()
    flag.move(to: CGPoint(x: stem.minX, y: stem.maxY))
    flag.addCurve(to: CGPoint(x: stem.maxX + u * 0.2, y: stem.maxY - u * 0.26),
                  control1: CGPoint(x: stem.maxX + u * 0.05, y: stem.maxY - u * 0.02),
                  control2: CGPoint(x: stem.maxX + u * 0.24, y: stem.maxY - u * 0.12))
    flag.addCurve(to: CGPoint(x: stem.maxX, y: stem.maxY - u * 0.16),
                  control1: CGPoint(x: stem.maxX + u * 0.14, y: stem.maxY - u * 0.18),
                  control2: CGPoint(x: stem.maxX + u * 0.06, y: stem.maxY - u * 0.15))
    flag.closeSubpath()
    ctx.addPath(flag); ctx.fillPath()

    // Lyric lines (the bright one is "now").
    let lx = art.maxX + pad * 0.9
    let lw = card.maxX - pad - lx
    let lh = max(1, card.height * (small ? 0.16 : 0.12))
    let lines: [(CGFloat, CGFloat, NSColor)] = small
        ? [(0.62, 1.0, NSColor(srgbRed: 0.30, green: 0.16, blue: 0.48, alpha: 1))]
        : [(0.64, 1.0, NSColor(srgbRed: 0.30, green: 0.16, blue: 0.48, alpha: 1)),
           (0.36, 0.7, NSColor(srgbRed: 0.30, green: 0.16, blue: 0.48, alpha: 0.35))]
    for (yFrac, wFrac, color) in lines {
        let r = CGRect(x: lx, y: card.minY + card.height * yFrac - lh / 2, width: lw * wFrac, height: lh)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: lh / 2, cornerHeight: lh / 2, transform: nil))
        ctx.setFillColor(color.cgColor); ctx.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Chrome extension icons. Web Store guidance: 128px icon with ~16px transparent padding.
for size in [16, 32, 48, 128] {
    let s = CGFloat(size)
    let inset: CGFloat = size == 128 ? 16 : (size >= 48 ? 4 : 1)
    writePNG(drawIcon(size: s, inset: inset, macTile: false), root.appendingPathComponent("extension/icons/icon\(size).png"))
}

// macOS app icon: 1024 grid with an ~100px margin (Big Sur+ template).
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let s = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(drawIcon(size: s, inset: s * 100 / 1024, macTile: true), iconset.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("app/Resources/AppIcon.icns")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print("wrote extension/icons/*.png and \(out.path)")
