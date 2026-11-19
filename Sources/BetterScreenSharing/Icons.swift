import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Appikonen "Scenväxeln": två överlappande fönster och en växlingspil.
/// Ritas i kod, så att appen inte behöver några bildfiler. build.sh gör en .icns av den.
enum AppIcon {
    private static let ink = CGColor(srgbRed: 0x15 / 255, green: 0x17 / 255, blue: 0x1C / 255, alpha: 1)
    private static let back = CGColor(srgbRed: 0x3A / 255, green: 0x3F / 255, blue: 0x4B / 255, alpha: 1)
    private static let amber = CGColor(srgbRed: 1, green: 0xB0 / 255, blue: 0x20 / 255, alpha: 1)
    private static let amberDark = CGColor(srgbRed: 0xE0 / 255, green: 0x94 / 255, blue: 0, alpha: 1)
    private static let light = CGColor(srgbRed: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255, alpha: 1)

    /// Ritningen är gjord i enheter 0–100 med origo uppe till vänster; plattan går från 6 till 94.
    static func cgImage(pixels: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(pixels) / 1024
        // Apples rutnät: plattan är 824 av 1024 px och centrerad.
        let unit = 824 / 88 * s
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 100 * s - 6 * unit, y: 100 * s - 6 * unit)
        ctx.scaleBy(x: unit, y: unit)

        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 18 * s, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(rounded(6, 6, 88, 88, 21))
        ctx.setFillColor(ink)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(rounded(20, 22, 48, 34, 5))
        ctx.setFillColor(back)
        ctx.fillPath()

        let front = rounded(32, 40, 50, 36, 5)
        ctx.addPath(front)
        ctx.setFillColor(amber)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(front)
        ctx.clip()
        ctx.setFillColor(amberDark)
        ctx.fill(CGRect(x: 32, y: 40, width: 50, height: 8))
        ctx.restoreGState()

        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 22, y: 63))
        arrow.addCurve(to: CGPoint(x: 35, y: 76), control1: CGPoint(x: 22, y: 71), control2: CGPoint(x: 27, y: 76))
        arrow.move(to: CGPoint(x: 31, y: 70))
        arrow.addLine(to: CGPoint(x: 37, y: 76))
        arrow.addLine(to: CGPoint(x: 31, y: 82))
        ctx.addPath(arrow)
        ctx.setStrokeColor(light)
        ctx.setLineWidth(4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        return ctx.makeImage()
    }

    /// Skriver en .iconset-mapp som `iconutil -c icns` gör om till appens ikonfil.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                guard let image = cgImage(pixels: points * scale),
                      let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(dest, image, nil)
                guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}

/// Menyradssymbolen: samma två fönster som appikonen, med det främre i bärnsten.
/// Det bakre ritas i menyradens textfärg, så att symbolen fungerar i både ljust och mörkt läge.
/// När något delas får den en röd punkt, som en "live"-lampa.
enum MenuBarIcon {
    private static let amber = NSColor(srgbRed: 1, green: 0xB0 / 255, blue: 0x20 / 255, alpha: 1)
    private static let live = NSColor(srgbRed: 1, green: 0x4D / 255, blue: 0x3D / 255, alpha: 1)

    static func image(sharing: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.labelColor.setStroke()
            let back = NSBezierPath(roundedRect: CGRect(x: 1.5, y: 2, width: 10, height: 7.5), xRadius: 1.6, yRadius: 1.6)
            back.lineWidth = 1.4
            back.stroke()
            amber.setFill()
            NSBezierPath(roundedRect: CGRect(x: 6, y: 7.5, width: 10.5, height: 8), xRadius: 1.6, yRadius: 1.6).fill()
            if sharing {
                let center = CGPoint(x: 15.2, y: 3.2)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: CGRect(x: center.x - 3.3, y: center.y - 3.3, width: 6.6, height: 6.6)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                live.setFill()
                NSBezierPath(ovalIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)).fill()
            }
            return true
        }
        // Inte en mall: då skulle menyraden färga om det gula fönstret.
        image.isTemplate = false
        image.accessibilityDescription = sharing ? L("BetterScreenSharing – sharing", "BetterScreenSharing – delar") : "BetterScreenSharing"
        return image
    }
}
