import AppKit

/// Varningssignalen när en minut återstår: ett klockspel på ungefär tre sekunder.
/// Systemljuden är för korta för att höras säkert, så signalen syntetiseras här i stället för att ligga i en ljudfil.
@MainActor
enum Chime {
    private static var sound: NSSound?

    static func play() {
        if sound == nil, let data = wav() { sound = NSSound(data: data) }
        sound?.stop()
        sound?.play()
    }

    /// Tre stigande klocktoner följda av ett ackord som klingar ut.
    private static func wav() -> Data? {
        let rate = 44_100.0
        let length = 3.6
        let notes: [(start: Double, freq: Double, gain: Double)] = [
            (0.00, 659.25, 0.8), (0.32, 830.61, 0.8), (0.64, 987.77, 0.8),
            (1.20, 659.25, 0.6), (1.20, 830.61, 0.6), (1.20, 987.77, 0.6), (1.20, 1318.51, 0.4),
        ]
        var samples = [Double](repeating: 0, count: Int(rate * length))
        for note in notes {
            let first = Int(note.start * rate)
            let decay = note.start >= 1 ? 1.6 : 3.2
            for i in first..<samples.count {
                let t = Double(i - first) / rate
                let attack = min(1, t / 0.006)
                let env = attack * exp(-t * decay) * note.gain
                // Grundton plus svaga övertoner ger en klockliknande klang.
                let w = 2 * Double.pi * note.freq * t
                samples[i] += env * (sin(w) + 0.35 * sin(2 * w) + 0.12 * sin(3.01 * w))
            }
        }
        let peak = samples.map(abs).max() ?? 1
        let fadeStart = samples.count - Int(rate * 0.3)
        var pcm = Data(capacity: samples.count * 2)
        for (i, v) in samples.enumerated() {
            let fade = i > fadeStart ? Double(samples.count - i) / Double(samples.count - fadeStart) : 1
            var s = Int16(max(-1, min(1, v / peak * 0.7 * fade)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }

        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8)
        wav += le(UInt32(36 + pcm.count))
        wav += Data("WAVEfmt ".utf8)
        wav += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
        wav += le(UInt32(rate)) + le(UInt32(rate * 2)) + le(UInt16(2)) + le(UInt16(16))
        wav += Data("data".utf8) + le(UInt32(pcm.count)) + pcm
        return wav
    }
}
