import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case sourceGone
    var errorDescription: String? { L("The source no longer exists (the window has been closed).", "Källan finns inte längre (fönstret har stängts).") }
}

/// En enda SCStream som byter innehållsfilter vid växling, så att bytet går snabbt
/// och scenen kan visa sista bilden tills första bilden från den nya källan kommer.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: (@MainActor (CVPixelBuffer) -> Void)?
    var onStop: (@MainActor (Error?) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "bss.capture", qos: .userInteractive)
    private var pointSize: CGSize = .zero
    private var scale: CGFloat = 2
    private var fps = 30
    /// Utsnitt av skärmen (i punkter, origo uppe till vänster) när bara ett fönster på skärmen ska med.
    private var sourceRect: CGRect?
    private var maxDimension: CGFloat

    init(maxDimension: CGFloat = 3840) {
        self.maxDimension = maxDimension
        super.init()
    }

    var currentPointSize: CGSize { pointSize }

    func start(_ source: Source, fps: Int) async throws {
        self.fps = fps
        sourceRect = nil
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        switch source.kind {
        case .window:
            guard let w = content.windows.first(where: { $0.windowID == source.windowID }) else {
                throw CaptureError.sourceGone
            }
            filter = SCContentFilter(desktopIndependentWindow: w)
            pointSize = w.frame.size
        case .display:
            guard let d = content.displays.first(where: { $0.displayID == source.displayID }) else {
                throw CaptureError.sourceGone
            }
            // Visa aldrig våra egna fönster (scenen, kontrollpanelen) i en skärmdelning – undviker spegeltunnel.
            if source.stageOnDisplay {
                // Skärmfångst som bara tar med scenfönstret: stör inte mötesappens fångst av själva fönstret.
                guard let w = content.windows.first(where: { $0.windowID == source.windowID }) else { throw CaptureError.sourceGone }
                filter = SCContentFilter(display: d, including: [w])
                // Skärmen kan vara större än scenen (remsa för menyraden); fånga bara scenfönstrets del.
                let rect = w.frame.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
                if rect.size != d.frame.size { sourceRect = rect }
            } else {
                let ours = content.applications.filter { $0.processID == getpid() }
                filter = SCContentFilter(display: d, excludingApplications: ours, exceptingWindows: [])
            }
            pointSize = sourceRect?.size ?? d.frame.size
        }
        scale = CGFloat(filter.pointPixelScale)
        let config = makeConfiguration()

        if let stream {
            do {
                try await stream.updateContentFilter(filter)
                try await stream.updateConfiguration(config)
                return
            } catch {
                try? await stream.stopCapture()
                self.stream = nil
            }
        }
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    /// Anropas när källfönstret ändrat storlek, så att upplösningen följer med.
    func resize(to newSize: CGSize) async {
        guard let stream, abs(newSize.width - pointSize.width) > 1 || abs(newSize.height - pointSize.height) > 1 else { return }
        pointSize = newSize
        try? await stream.updateConfiguration(makeConfiguration())
    }

    /// Största sida i bildpunkter. Förhandsvisningen sätter den efter hur stor bilden visas, så att en liten
    /// dockad bild inte fångas i full storlek.
    func setMaxDimension(_ value: CGFloat) async {
        guard value != maxDimension else { return }
        maxDimension = value
        try? await stream?.updateConfiguration(makeConfiguration())
    }

    func setFPS(_ fps: Int) async {
        self.fps = fps
        try? await stream?.updateConfiguration(makeConfiguration())
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        var w = pointSize.width * scale
        var h = pointSize.height * scale
        let limit = min(1, maxDimension / max(w, h, 1))
        w *= limit
        h *= limit
        c.width = max(2, Int(w.rounded()))
        c.height = max(2, Int(h.rounded()))
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        if let sourceRect { c.sourceRect = sourceRect }
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.showsCursor = true
        c.scalesToFit = true
        c.preservesAspectRatio = true
        c.queueDepth = 6
        return c
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onFrame?(pixelBuffer) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            if self.stream === stream { self.stream = nil }
            MainActor.assumeIsolated { self.onStop?(error) }
        }
    }
}
