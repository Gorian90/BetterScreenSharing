import AppKit

// MARK: - Rita markering direkt på skärmen

/// Lägger ett genomskinligt lager över alla skärmar där användaren drar en rektangel
/// runt den yta som ska vara ljus. Resultatet ges i globala CG-koordinater (origo uppe till vänster).
@MainActor
final class RegionSelector {
    private static var active: RegionSelector?

    static var isActive: Bool { active != nil }

    /// Avbryter en pågående ritning, t.ex. från den globala Esc-genvägen.
    static func cancel() { active?.finish(nil) }

    private var windows: [NSWindow] = []
    private let completion: (CGRect?) -> Void
    private var previousApp: NSRunningApplication?

    /// `excludingDisplay`: den virtuella scenskärmen, som ingen ser och därför inte ska få ett lager.
    static func begin(excludingDisplay: CGDirectDisplayID?, completion: @escaping (CGRect?) -> Void) {
        guard active == nil else { return }
        let selector = RegionSelector(completion: completion)
        active = selector
        selector.show(excluding: excludingDisplay)
    }

    private init(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
    }

    private func show(excluding excluded: CGDirectDisplayID?) {
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens where screen.displayID != excluded {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .screenSaver
            w.sharingType = .none
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = OverlayView(selector: self)
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    fileprivate func finish(_ screenRect: CGRect?) {
        guard Self.active === self else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        Self.active = nil
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        guard let r = screenRect else { completion(nil); return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        completion(CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height))
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    private weak var selector: RegionSelector?
    private var start: CGPoint?
    private var current: CGPoint?

    init(selector: RegionSelector) {
        self.selector = selector
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let r = selection {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.systemYellow.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 2
            p.stroke()
        } else {
            let text = L("Drag a rectangle around the area to highlight · Esc cancels", "Dra en rektangel runt ytan som ska framhävas · Esc avbryter")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let r = selection, r.width > 8, r.height > 8, let window else {
            selector?.finish(nil)
            return
        }
        selector?.finish(window.convertToScreen(r))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { selector?.finish(nil) } // Esc
    }
}

// MARK: - Rita med Caps Lock

/// Ritlagret i Caps Lock-funktionsläget: ligger kvar tills Caps Lock slås av, och varje klick och dra blir en ny
/// markering. Lagret aktiverar inte appen och ligger under snabbpanelen, så att den går att klicka på.
@MainActor
final class DrawLayer {
    private var windows: [NSWindow] = []

    init(excludingDisplay excluded: CGDirectDisplayID?, onRect: @escaping (CGRect) -> Void) {
        for screen in NSScreen.screens where screen.displayID != excluded {
            let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            // Genomskinliga fönster släpper annars igenom klicken.
            w.ignoresMouseEvents = false
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            w.sharingType = .none
            w.hidesOnDeactivate = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.contentView = DrawLayerView { rect in
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                onRect(CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height))
            }
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

private final class DrawLayerView: NSView {
    private let onRect: (CGRect) -> Void
    private var start: CGPoint?
    private var current: CGPoint?

    init(onRect: @escaping (CGRect) -> Void) {
        self.onRect = onRect
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Fönstret blir aldrig nyckelfönster, så markören sätts via spårning i stället för cursor rects.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    private var selection: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Nästan genomskinligt, men en tunn bärnstensfärgad ram visar att ritläget är på.
        NSColor.black.withAlphaComponent(0.001).setFill()
        bounds.fill()
        let amber = NSColor(hex: "#FFB020") ?? .systemYellow
        amber.withAlphaComponent(0.8).setStroke()
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        frame.lineWidth = 3
        frame.stroke()
        if let r = selection {
            amber.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 2
            p.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        defer {
            start = nil
            current = nil
            needsDisplay = true
        }
        guard let r = selection, r.width > 8, r.height > 8, let window else { return }
        onRect(window.convertToScreen(r))
    }
}

// MARK: - HUD

/// Kort bekräftelse på skärmen vid växling. Syns aldrig i någon skärminspelning.
@MainActor
final class HUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 40, height: label.frame.height + 24)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        panel.setFrame(CGRect(x: vf.midX - size.width / 2, y: vf.minY + 90, width: size.width, height: size.height), display: true)
        label.frame.origin = CGPoint(x: 20, y: 12)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.sharingType = .none
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        effect.addSubview(label)
        p.contentView = effect
        panel = p
        return p
    }
}

// MARK: - Menyrad

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        if !key.isEmpty { toolTip = key }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
