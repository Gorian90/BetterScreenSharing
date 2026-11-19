import AppKit

/// Samma dimning som på scenen, ritad över det delade fönstret eller skärmen hos presentatören. Fönstret undantas
/// från inspelning: skärmdelningen utesluter appens egna fönster, och ett delat fönster spelas in för sig.
/// Klicken släpps igenom, utom i den dimmade ytan runt en markering: där tar ett klick bort markeringen.
@MainActor
final class PresenterDim {
    private var panel: NSPanel?
    private let dim = CALayer()
    private let mask = CALayer()
    private let outline = CAShapeLayer()
    private var maskKey: String?
    /// Markeringens ljusa yta i skärmkoordinater (AppKit); nil när ingen markering visas.
    private var hole: CGRect?
    private var monitors: [Any] = []

    /// Anropas vid klick i den dimmade ytan runt en markering.
    var onDimClick: (() -> Void)?
    /// Av medan Caps Lock-ritlagret ligger uppe, så att nya markeringar går att rita över dimningen.
    var clickToDismiss = true { didSet { refreshMouse() } }

    /// `bounds` i globala CG-koordinater (origo uppe till vänster); `spotCenter` normaliserad i källan.
    func update(bounds: CGRect?, effects: EffectSettings, spotCenter: CGPoint?) {
        guard let bounds, bounds.width > 0, bounds.height > 0 else { hide(); return }
        let panel = self.panel ?? makePanel()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        let local = CGRect(origin: .zero, size: frame.size)
        dim.frame = local
        mask.frame = local
        outline.frame = local

        let aspect = frame.width / frame.height
        var image: CGImage?
        var key: String?
        switch effects.mode {
        case .off:
            break
        case .rect:
            if let r = effects.rect {
                key = "rect \(r) \(aspect)"
                if key != maskKey { image = EffectMask.rect(aspect: aspect, rect: r) }
            }
        case .spotlight:
            if let c = spotCenter {
                key = "spot \(c) \(aspect) \(effects.spotlightRadius) \(effects.feather)"
                if key != maskKey { image = EffectMask.spotlight(aspect: aspect, center: c, radius: effects.spotlightRadius, feather: effects.feather) }
            }
        }
        if let image {
            mask.contents = image
            maskKey = key
        }
        if effects.mode == .rect, let r = effects.rect {
            let rr = CGRect(x: r.minX * local.width, y: (1 - r.maxY) * local.height, width: r.width * local.width, height: r.height * local.height)
            let radius = min(10 * local.width / 800, rr.width / 2, rr.height / 2)
            outline.path = CGPath(roundedRect: rr, cornerWidth: radius, cornerHeight: radius, transform: nil)
            outline.isHidden = false
            hole = rr.offsetBy(dx: frame.minX, dy: frame.minY)
        } else {
            outline.isHidden = true
            hole = nil
        }
        CATransaction.commit()

        let target: Float = key != nil ? Float(effects.dimOpacity) : 0
        if dim.opacity != target {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            dim.opacity = target
            CATransaction.commit()
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        setMonitors(hole != nil)
        refreshMouse()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.ignoresMouseEvents = true
        dim.opacity = 0
        maskKey = nil
        hole = nil
        setMonitors(false)
    }

    /// Fönstret fångar klick bara när pekaren är i den dimmade ytan, så att allt annat når apparna under.
    private func refreshMouse() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let catches = clickToDismiss && panel.isVisible && hole.map { panel.frame.contains(mouse) && !$0.contains(mouse) } == true
        if panel.ignoresMouseEvents == catches { panel.ignoresMouseEvents = !catches }
    }

    /// Den globala övervakningen ser pekaren över andra appar; över dimningen själv kommer rörelserna via spårningen i vyn.
    /// Musövervakning kräver ingen behörighet.
    private func setMonitors(_ on: Bool) {
        guard on != !monitors.isEmpty else { return }
        if on {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMouse() }
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.refreshMouse() }
                return event
            }) { monitors.append(local) }
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        // Över vanliga fönster men under snabbpanelen och den dockade förhandsvisningen.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        p.sharingType = .none
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = DimView()
        view.onMove = { [weak self] in self?.refreshMouse() }
        view.onClick = { [weak self] in self?.onDimClick?() }
        view.wantsLayer = true
        view.layer?.isGeometryFlipped = false
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = 0
        dim.mask = mask
        mask.contentsGravity = .resize
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        outline.lineWidth = 2
        view.layer?.addSublayer(dim)
        view.layer?.addSublayer(outline)
        p.contentView = view
        panel = p
        return p
    }
}

private final class DimView: NSView {
    var onMove: (() -> Void)?
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseMoved(with event: NSEvent) { onMove?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Panelen blir aldrig nyckelfönster, så rörelserna kommer via en spårning som alltid är aktiv.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved], owner: self))
    }
}
