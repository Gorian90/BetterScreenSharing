import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Animerade bilder (GIF, animerad PNG, animerad WebP) för meddelandena när inget delas.
/// Bildrutorna spelas upp med Core Animation, så animationen syns i scenen, förhandsvisningarna och mötet.
struct AnimatedImage {
    let frames: [CGImage]
    /// Visningstid per bildruta i sekunder.
    let durations: [Double]

    var totalDuration: Double { durations.reduce(0, +) }

    /// Högst så många bildrutor avkodas, så att en mycket lång GIF inte fyller minnet.
    private static let maxFrames = 600

    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Nil om bilden inte är animerad.
    static func decode(_ data: Data) -> AnimatedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), maxFrames)
        guard count > 1 else { return nil }
        var frames: [CGImage] = []
        var durations: [Double] = []
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(image)
            durations.append(frameDuration(source, i))
        }
        return frames.count > 1 ? AnimatedImage(frames: frames, durations: durations) : nil
    }

    /// Bildrutans tid enligt filen. Mycket korta tider (under 0,02 s) tolkas som 0,1 s, som i webbläsare.
    private static func frameDuration(_ source: CGImageSource, _ index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dict, unclamped, clamped) in dictionaries {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            let value = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
            return value < 0.02 ? 0.1 : value
        }
        return 0.1
    }

    /// Animation som byter lagrets innehåll bildruta för bildruta, i oändlig loop.
    func contentsAnimation() -> CAKeyframeAnimation {
        let total = max(totalDuration, 0.01)
        var keyTimes: [NSNumber] = [0]
        var elapsed = 0.0
        for d in durations {
            elapsed += d
            keyTimes.append(NSNumber(value: min(elapsed / total, 1)))
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        // Diskret läge: en tidpunkt mer än antalet bildrutor.
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Gör en animerad bild lagom stor för inställningarna: små filer sparas som de är, större skalas ned
    /// till högst `maxPixels` och sparas om som GIF med samma tider.
    static func encodedForSettings(_ data: Data, maxPixels: CGFloat = 1280, maxBytes: Int = 8_000_000) -> Data? {
        guard let animation = decode(data), let first = animation.frames.first else { return nil }
        let largest = CGFloat(max(first.width, first.height))
        if data.count <= maxBytes && largest <= 1920 { return data }
        let scale = min(1, maxPixels / largest)
        let w = max(1, Int(CGFloat(first.width) * scale)), h = max(1, Int(CGFloat(first.height) * scale))
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, animation.frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (frame, duration) in zip(animation.frames, animation.durations) {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            CGImageDestinationAddImage(dest, scaled, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
