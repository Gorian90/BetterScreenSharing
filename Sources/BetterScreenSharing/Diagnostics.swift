import AppKit
import ScreenCaptureKit
import SwiftUI
import ImageIO

/// Mätläge för bildfrekvens: `open BetterScreenSharing.app --args --diagnose <loggfil> [--stage-mode window]`.
/// Animerar en testruta i scenen och räknar hur många färdiga bilder ScreenCaptureKit levererar,
/// dvs. ungefär vad mötesappen får när den delar scenen.
final class FrameCounter: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var times: [CFTimeInterval] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        lock.lock()
        times.append(CACurrentMediaTime())
        lock.unlock()
    }

    func reset() {
        lock.lock(); times = []; lock.unlock()
    }

    /// Bilder per sekund och längsta glapp i millisekunder.
    func summary(over seconds: Double) -> String {
        lock.lock(); let t = times; lock.unlock()
        let gaps = zip(t.dropFirst(), t).map { ($0 - $1) * 1000 }
        return String(format: "%.1f frames/s, longest gap %.0f ms", Double(t.count) / seconds, gaps.max() ?? 0)
    }
}

struct DiagnosticVariant {
    let name: String
    let apply: @MainActor () async -> Void
}

@MainActor
enum Diagnostics {
    static func run(stageWindow: NSWindow, stageView: StageView, virtualDisplayID: @escaping () -> CGDirectDisplayID?,
                    variants: [DiagnosticVariant], extraInfo: @escaping @MainActor () -> String,
                    logPath: String) async {
        var lines: [String] = []
        func log(_ s: String) {
            lines.append(s)
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath + ".part", atomically: true, encoding: .utf8)
        }

        // Testruta som flyttas 60 gånger per sekund.
        let square = CALayer()
        square.backgroundColor = NSColor.systemRed.cgColor
        square.frame = CGRect(x: 0, y: 40, width: 120, height: 120)
        stageView.layer?.addSublayer(square)
        var ticks = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                ticks += 1
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let w = max(stageView.bounds.width - 120, 1)
                square.frame.origin.x = CGFloat(ticks * 8).truncatingRemainder(dividingBy: w)
                CATransaction.commit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        for variant in variants {
            await variant.apply()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            log("== \(variant.name)")
            if let id = virtualDisplayID(), let mode = CGDisplayCopyDisplayMode(id) {
                log("   virtual display \(id): \(mode.pixelWidth)×\(mode.pixelHeight) px, \(mode.width)×\(mode.height) pt @ \(mode.refreshRate) Hz")
            }
            log("   stage on display \(stageWindow.screen?.displayID ?? 0), level \(stageWindow.level.rawValue), visible according to macOS: \(stageWindow.occlusionState.contains(.visible))")
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                var targets: [(String, SCContentFilter, CGSize)] = []
                if let id = virtualDisplayID(), let d = content.displays.first(where: { $0.displayID == id }) {
                    targets.append(("virtual display", SCContentFilter(display: d, excludingWindows: []), d.frame.size))
                }
                if let w = content.windows.first(where: { $0.windowID == CGWindowID(stageWindow.windowNumber) }) {
                    targets.append(("stage window", SCContentFilter(desktopIndependentWindow: w), w.frame.size))
                }
                for (name, filter, size) in targets {
                    let config = SCStreamConfiguration()
                    config.width = Int(size.width)
                    config.height = Int(size.height)
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                    config.queueDepth = 8
                    let counter = FrameCounter()
                    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                    try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: DispatchQueue(label: "diag"))
                    try await stream.startCapture()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    counter.reset()
                    let startTicks = ticks
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    log("   \(name): \(counter.summary(over: 3)) (animation \(Double(ticks - startTicks) / 3) steps/s)")
                    try await stream.stopCapture()
                }
                log("   \(extraInfo())")
            } catch {
                log("   Error: \(error.localizedDescription)")
            }
        }

        timer.invalidate()
        square.removeFromSuperlayer()
        try? FileManager.default.removeItem(atPath: logPath)
        try? FileManager.default.moveItem(atPath: logPath + ".part", toPath: logPath)
    }
}

/// Utvecklarläge: `--render-ui <mapp>` ritar snabbpanelen, menyradssymbolen och nedräkningen till PNG-filer
/// utan att visa något på skärmen. Kör den osignerade binären direkt, så används en egen inställningsdomän.
@MainActor
enum UIRender {
    static func run(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = AppState.shared
        state.pendingPersistedSlots = []
        state.slots = [.ownWindow(1), .ownWindow(2), .ownWindow(3)] + Array(repeating: nil, count: AppState.slotCount - 3)
        state.activeSource = state.slots[1]
        state.activeSlot = 1
        state.camera.enabled = true
        state.effects.mode = .spotlight

        let dock = QuickDock(state: state, controller: AppController.shared)
        for (name, position, expanded) in [("dock-side-collapsed", DockPosition.right, false), ("dock-side-expanded", .right, true),
                                           ("dock-left-expanded", .left, true),
                                           ("dock-notch-collapsed", .notch, false), ("dock-notch-expanded", .notch, true),
                                           ("dock-around-expanded", .aroundNotch, true)] {
            state.dockPosition = position
            dock.model.expanded = expanded
            dock.model.notchWidth = 190
            dock.model.topInset = 32
            let view = NSHostingView(rootView: DockRootView(state: state, model: dock.model, dock: dock).padding(20).background(Color(white: 0.45)))
            view.frame = CGRect(origin: .zero, size: view.fittingSize)
            try write(view, to: dir.appendingPathComponent("\(name).png"))
        }

        // Dockad förhandsvisning bredvid den utfällda notchpanelen, ihopsatt till en bild.
        state.dockPosition = .notch
        dock.model.expanded = true
        dock.setPreviewAttached(.right)
        state.textMode = true
        state.textMessage = "Questions? Write in the chat"
        state.textShown = true
        let top = NSHostingView(rootView: DockRootView(state: state, model: dock.model, dock: dock))
        top.frame = CGRect(origin: .zero, size: top.fittingSize)
        for compact in [true, false] {
        let container = DockedPreviewContainer(frame: .zero)
        let fake = NSView()
        fake.wantsLayer = true
        fake.layer?.backgroundColor = NSColor(hex: "#3A3F4B")?.cgColor
        container.setPreview(fake)
        container.topGap = compact ? 6 : dock.model.topInset + 8
        container.compact = compact
        container.side = .right
        let imageH = compact ? top.frame.height - container.topGap - 12 : 180
        container.imageSize = CGSize(width: imageH * 16 / 9, height: imageH)
        var size = DockedPreviewContainer.size(image: container.imageSize, topGap: container.topGap, compact: compact)
        size.height = compact ? top.frame.height : max(size.height, top.frame.height)
        let ch = size.height
        container.frame = CGRect(origin: .zero, size: size)
        let combined = NSView(frame: CGRect(x: 0, y: 0, width: top.frame.width + container.frame.width + 40, height: ch + 40))
        combined.wantsLayer = true
        combined.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
        top.removeFromSuperview()
        top.frame.origin = CGPoint(x: 20, y: 20 + ch - top.frame.height)
        container.frame.origin = CGPoint(x: 20 + top.frame.width, y: 20)
        combined.addSubview(container)
        combined.addSubview(top)
        try write(combined, to: dir.appendingPathComponent("dock-notch-preview-\(compact ? "small" : "large").png"))
        }

        // Dockad förhandsvisning bredvid den utfällda panelen vid höger kant.
        state.dockPosition = .right
        dock.setPreviewAttached(nil)
        let side = NSHostingView(rootView: DockRootView(state: state, model: dock.model, dock: dock))
        side.frame = CGRect(origin: .zero, size: side.fittingSize)
        for compact in [true, false] {
            let container = DockedPreviewContainer(frame: .zero)
            let fake = NSView()
            fake.wantsLayer = true
            fake.layer?.backgroundColor = NSColor(hex: "#3A3F4B")?.cgColor
            container.setPreview(fake)
            container.floating = true
            container.topGap = DockedPreviewContainer.floatingTopGap(compact: compact)
            container.compact = compact
            container.alignedWithPanel = false
            container.side = .left
            let imageH: CGFloat = compact ? 98 : 180
            container.imageSize = CGSize(width: imageH * 16 / 9, height: imageH)
            let size = DockedPreviewContainer.size(image: container.imageSize, topGap: container.topGap, compact: compact,
                                                   inner: DockedPreviewContainer.compactOuter)
            container.frame = CGRect(origin: .zero, size: size)
            let h = max(size.height, side.frame.height)
            let combined = NSView(frame: CGRect(x: 0, y: 0, width: size.width + 8 + side.frame.width + 20, height: h + 40))
            combined.wantsLayer = true
            combined.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
            side.removeFromSuperview()
            side.frame.origin = CGPoint(x: 20 + size.width + 8, y: 20 + h - side.frame.height)
            container.frame.origin = CGPoint(x: 20, y: 20 + h - size.height)
            combined.addSubview(container)
            combined.addSubview(side)
            try write(combined, to: dir.appendingPathComponent("dock-edge-preview-\(compact ? "small" : "large").png"))

            // Samma ruta under panelen, längs kanten.
            let below = NSView(frame: CGRect(x: 0, y: 0, width: size.width + 40, height: side.frame.height + 8 + size.height + 40))
            below.wantsLayer = true
            below.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
            side.removeFromSuperview()
            container.removeFromSuperview()
            side.frame.origin = CGPoint(x: 20 + size.width - side.frame.width, y: 20 + size.height + 8)
            container.frame.origin = CGPoint(x: 20, y: 20)
            below.addSubview(container)
            below.addSubview(side)
            try write(below, to: dir.appendingPathComponent("dock-edge-preview-below-\(compact ? "small" : "large").png"))
        }

        for (name, sharing, dark) in [("menubar-idle-light", false, false), ("menubar-sharing-light", true, false),
                                      ("menubar-idle-dark", false, true), ("menubar-sharing-dark", true, true)] {
            let image = MenuBarIcon.image(sharing: sharing)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: 36, height: 36)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            CGRect(x: 0, y: 0, width: 36, height: 36).fill()
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                if image.isTemplate {
                    // Menyraden färgar mallar själv; här efterliknas det.
                    let tinted = NSImage(size: image.size, flipped: false) { r in
                        image.draw(in: r)
                        (dark ? NSColor.white : NSColor.black).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: CGRect(x: 9, y: 9, width: 18, height: 18))
                } else {
                    image.draw(in: CGRect(x: 9, y: 9, width: 18, height: 18))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
        }

        state.countdown.subtitle = "There's coffee in the kitchen"
        state.countdown.mode = .untilTime
        print("§ key: code \(HotkeyAction.keyBelowEscape), function-mode key \(Shortcut.keyName(UInt32(HotkeyAction.keyBelowEscape)))")
        // En GIF med tre färgade bildrutor, för att testa avkodning och nedskalning av animerade bilder.
        let gif = NSMutableData()
        let dest = CGImageDestinationCreateWithData(gif, "com.compuserve.gif" as CFString, 3, nil)!
        for (i, hex) in ["#FFB020", "#5B8DEF", "#28C840"].enumerated() {
            let ctx = CGContext(data: nil, width: 2400, height: 1350, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor(hex: hex)!.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 1350))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2 + Double(i) * 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        let stored = AnimatedImage.encodedForSettings(gif as Data)!
        let decoded = AnimatedImage.decode(stored)!
        print("GIF: animated=\(AnimatedImage.isAnimated(gif as Data)) frames=\(decoded.frames.count) durations=\(decoded.durations) size=\(decoded.frames[0].width)x\(decoded.frames[0].height) bytes=\(stored.count)")
        var withText = IdleMessage(content: .image, title: "Back shortly", subtitle: "We'll continue in a little while", imageData: stored)
        withText.textOnImage = true
        withText.textPosition = .bottomLeft
        state.stoppedMessage = withText
        state.textMessage = "Questions? Write in the chat and we'll take them after the walkthrough"
        for section in [PanelSection.general, .countdown, .messages, .effects, .camera, .dock, .shortcuts] {
            state.panelSection = section
            if section == .shortcuts { state.capsLockAction = .functionLayer }
            if section == .camera {
                // "Bara jag" med egen storlek och position, för att se att inställningarna gäller.
                state.camera.fullscreen = true
                state.camera.fullSize = 0.6
                state.camera.fullCenterX = 0.3
                state.camera.borderWidth = 8
                state.camera.shape = .chamfered
            }
            let panelWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 1150), styleMask: [.titled], backing: .buffered, defer: false)
            let panel = NSHostingView(rootView: ControlPanelView(state: state, controller: AppController.shared))
            panelWindow.contentView = panel
            panel.frame = CGRect(x: 0, y: 0, width: 860, height: 1150)
            try write(panel, to: dir.appendingPathComponent("panel-\(section.rawValue).png"))
        }

        let wizard = PermissionWizardModel()
        let wizardSteps: [PermissionStep] = [.screenRecording, .accessibility, .camera]
        for (name, index, waiting, granted) in [("wizard-1-start", 0, false, false), ("wizard-1-waiting", 0, true, false),
                                                ("wizard-2-allowed", 1, false, true), ("wizard-3-camera", 2, false, false)] {
            wizard.preview(wizardSteps[index], index: index, of: wizardSteps, waiting: waiting, granted: granted)
            let view = NSHostingView(rootView: PermissionWizardView(model: wizard).background(Color(white: 0.2)))
            view.frame = CGRect(origin: .zero, size: view.fittingSize)
            try write(view, to: dir.appendingPathComponent("\(name).png"))
        }

        let guide = ShortcutGuideModel()
        state.capsLockAction = .spotlight
        for (name, tested) in [("shortcut-guide-start", [HotkeyAction]()), ("shortcut-guide-tested", [.shareFrontmost])] {
            guide.tested = Set(tested)
            guide.capsTested = !tested.isEmpty
            guide.capsOn = !tested.isEmpty
            let view = NSHostingView(rootView: ShortcutGuideView(model: guide, state: state).background(Color(white: 0.2)))
            view.frame = CGRect(origin: .zero, size: view.fittingSize)
            try write(view, to: dir.appendingPathComponent("\(name).png"))
        }

        for time in [1.0, 2.6, 4.25, 6.0, 9.85, 12.3, 15.5, 16.6, 19.8, 21.0, 23.7, 27.0] {
            try TutorialExport.writeStill(at: time, to: dir.appendingPathComponent(String(format: "tutorial-%05.2f.png", time)))
        }
        let player = NSHostingView(rootView: TutorialPlayerView(script: .standard, doneTitle: "Continue").background(Color(white: 0.2)))
        player.frame = CGRect(origin: .zero, size: player.fittingSize)
        try write(player, to: dir.appendingPathComponent("tutorial-player.png"))

        let stage = StageView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        stage.setBackground("#3A3F4B")
        for (name, display) in [
            ("countdown-full", CountdownDisplay(message: "Break – we'll be right back", subtitle: "There's coffee in the kitchen", time: "04:59", progress: 0.98, placement: .full)),
            ("countdown-colors", CountdownDisplay(message: "Lunch", subtitle: "See you at 13:00", time: "1:12:30", progress: 0.4, placement: .full,
                                                  messageColor: "#15171C", subtitleColor: "#3A3F4B", timeColor: "#0A7D4F", backgroundColor: "#F4F4F6",
                                                  footer: "We'll resume at 13:00", footerColor: "#0A7D4F")),
            ("countdown-corner", CountdownDisplay(message: "Break – we'll be right back", subtitle: "Coffee in the kitchen", time: "02:00", progress: 0.2, placement: .corner,
                                                  footer: "We'll resume at 13:00")),
            ("countdown-welcome", CountdownDisplay(message: "Welcome back", time: nil, progress: 0, placement: .full)),
        ] {
            stage.setCountdown(display)
            stage.layoutSubtreeIfNeeded()
            stage.layer?.layoutIfNeeded()
            try writeLayer(stage.layer!, size: stage.bounds.size, to: dir.appendingPathComponent("\(name).png"))
        }
    }

    private static func write(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static func writeLayer(_ layer: CALayer, size: CGSize, to url: URL) throws {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        layer.render(in: ctx)
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    }
}
