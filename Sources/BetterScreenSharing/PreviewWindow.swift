import AppKit
import AVFoundation

/// Förhandsvisning av scenen – exakt det publiken ser. Behövs när scenen ligger på den virtuella skärmen.
/// Den sitter antingen dockad under den utfällda snabbpanelen vid notchen, som en snabb kontroll av vad som
/// delas, eller i ett eget flytande fönster som går att flytta och ändra storlek på.
/// Musen fungerar här som i scenen: dra kameran, rita markering, scrolla.
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let dockedPanel: NSPanel
    private let dockedContainer = DockedPreviewContainer()
    private let previewView = PreviewView()
    private let engine = CaptureEngine(maxDimension: 1280)
    private var captureDimension: CGFloat = 1280
    /// Senaste placeringen vid kanten, så att en dragning kan landa i närmaste läge.
    private var edgeDock: EdgeDock?
    private weak var controller: AppController?
    private var running = false
    private var currentSourceID: String?
    private var dockButtonAccessory: NSTitlebarAccessoryViewController?
    private(set) var frameCount = 0

    /// Bildens höjd i dockat läge: en snabb kontroll av vad som delas, inte en arbetsyta.
    private static let dockedImageHeight: CGFloat = 180
    /// Den lilla bildens höjd när den inte kan följa panelens höjd (runt notchen); ungefär som under notchen.
    private static let compactImageHeight: CGFloat = 98

    init(controller: AppController) {
        self.controller = controller
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 270),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        dockedPanel = DockedPreviewPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        // Förhandsvisningen ska aldrig själv synas i en delning.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.setFrameAutosaveName("Preview")
        if panel.frame.origin == .zero, let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: vf.maxX - 500, y: vf.minY + 20))
        }
        addDockButton()
        updateTexts()

        dockedPanel.level = .statusBar
        dockedPanel.isOpaque = false
        dockedPanel.backgroundColor = .clear
        dockedPanel.hasShadow = true
        dockedPanel.hidesOnDeactivate = false
        dockedPanel.sharingType = .none
        dockedPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        dockedPanel.contentView = dockedContainer
        dockedContainer.onDetach = { [weak controller] in controller?.state.previewDocked = false }
        dockedContainer.onToggleSize = { [weak controller] in controller?.state.previewCompact.toggle() }
        dockedContainer.onDragEnded = { [weak self] in self?.dragEnded() }

        previewView.controller = controller
        panel.contentView = previewView
        engine.onFrame = { [weak self] pb in
            self?.frameCount += 1
            self?.previewView.display(pb)
        }
    }

    var isVisible: Bool { panel.isVisible || dockedPanel.isVisible }

    func resetFrameCount() { frameCount = 0 }

    /// Flytande fönster.
    func show(source: Source, aspect: CGSize, canDock: Bool) {
        dockedPanel.orderOut(nil)
        if previewView.window !== panel {
            previewView.layer?.cornerRadius = 0
            panel.contentView = previewView
        }
        dockButtonAccessory?.isHidden = !canDock
        panel.contentAspectRatio = aspect
        var frame = panel.frame
        frame.size.height = frame.width * aspect.height / max(aspect.width, 1) + (frame.height - panel.contentLayoutRect.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        startEngine(source)
    }

    /// Dockat vid sidan om den utfällda snabbpanelen vid notchen (`anchor`), med överkanten mot skärmens överkant.
    /// Kompakt är den lika hög som panelen så att nederkanterna ligger i linje; stor är den högre.
    /// Höger sida om det får plats, annars vänster. Ligger under panelen i fönsterordningen så att de går ihop
    /// utan synlig skarv. Returnerar vilken sida det blev.
    @discardableResult
    func showDocked(source: Source, aspect: CGSize, beside anchor: CGRect, topInset: CGFloat, compact: Bool,
                    dockWindowNumber: Int) -> DockPreviewSide {
        panel.orderOut(nil)
        if previewView.window !== dockedPanel { dockedContainer.setPreview(previewView) }
        // Liten: bilden använder även den svarta ytan upp mot skärmkanten. Under notchen blir den lika hög som panelen,
        // så att nederkanterna ligger i linje. Runt notchen är panelen bara en menyrad hög; där får den lilla bilden
        // samma storlek som under notchen och sticker ut nedanför panelen. Stor: bilden börjar i höjd med knappraden.
        let topGap = compact ? 6 : topInset + 8
        let alignsWithPanel = compact && anchor.height >= 80
        let imageH = compact ? (alignsWithPanel ? max(40, anchor.height - topGap - 12) : Self.compactImageHeight) : Self.dockedImageHeight
        let image = CGSize(width: imageH * aspect.width / max(aspect.height, 1), height: imageH)
        var size = DockedPreviewContainer.size(image: image, topGap: topGap, compact: compact)
        size.height = alignsWithPanel ? anchor.height : max(size.height, anchor.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.frame ?? anchor
        let side: DockPreviewSide = anchor.maxX + size.width <= screen.maxX ? .right : .left
        let x = side == .right ? anchor.maxX : anchor.minX - size.width
        let frame = CGRect(x: x, y: anchor.maxY - size.height, width: size.width, height: size.height).integral
        dockedContainer.floating = false
        dockedContainer.topGap = topGap
        dockedContainer.compact = compact
        dockedContainer.alignedWithPanel = alignsWithPanel
        dockedContainer.side = side
        dockedContainer.imageSize = image
        if dockedPanel.frame != frame { dockedPanel.setFrame(frame, display: true) }
        dockedPanel.order(.below, relativeTo: dockWindowNumber)
        startEngine(source)
        return side
    }

    /// Dockat vid den utfällda panelen vid skärmens kant (`anchor`). Bredvid: inåt skärmen med överkanten i linje
    /// med panelens. Under: längs kanten under panelen, eller ovanför om det inte får plats under.
    /// Panelen har rundade hörn mot skärmen, så förhandsvisningen blir en egen rundad ruta med lite luft.
    func showDockedAtEdge(source: Source, aspect: CGSize, beside anchor: CGRect, panelOnRight: Bool, below: Bool,
                          offset: Double, compact: Bool, dockWindowNumber: Int) {
        panel.orderOut(nil)
        if previewView.window !== dockedPanel { dockedContainer.setPreview(previewView) }
        let topGap = DockedPreviewContainer.floatingTopGap(compact: compact)
        let imageH = compact ? Self.compactImageHeight : Self.dockedImageHeight
        let image = CGSize(width: imageH * aspect.width / max(aspect.height, 1), height: imageH)
        let size = DockedPreviewContainer.size(image: image, topGap: topGap, compact: compact, inner: DockedPreviewContainer.compactOuter)
        let edge = EdgeDock(anchor: anchor, panelOnRight: panelOnRight, size: size)
        edgeDock = edge
        let frame = edge.frame(alongEdge: below, offset: CGFloat(offset))
        dockedContainer.floating = true
        dockedContainer.topGap = topGap
        dockedContainer.compact = compact
        dockedContainer.alignedWithPanel = false
        dockedContainer.side = panelOnRight ? .left : .right
        dockedContainer.imageSize = image
        if dockedPanel.frame != frame { dockedPanel.setFrame(frame, display: true) }
        dockedPanel.order(.below, relativeTo: dockWindowNumber)
        startEngine(source)
    }

    /// Släppt efter en dragning vid kanten: förhandsvisningen landar på den höjd den släpptes. Med mitten i höjd
    /// med panelen hamnar den bredvid panelen, annars längs kanten ovanför eller under den.
    private func dragEnded() {
        guard let edge = edgeDock, let state = controller?.state else { return }
        let dropped = dockedPanel.frame
        let alongEdge = dropped.midY < edge.anchor.minY || dropped.midY > edge.anchor.maxY
        let offset = Double(dropped.maxY - edge.anchor.maxY)
        let target = edge.frame(alongEdge: alongEdge, offset: CGFloat(offset))
        // Sparas som det läge den faktiskt hamnar i, så att den står kvar där nästa gång.
        let landed = Double(target.maxY - edge.anchor.maxY)
        dockedPanel.setFrame(target, display: true, animate: true)
        if state.previewBelowAtEdge != alongEdge { state.previewBelowAtEdge = alongEdge }
        if state.previewEdgeOffset != landed { state.previewEdgeOffset = landed }
    }

    /// Fångar i ungefär den storlek bilden visas (i bildpunkter, avrundat uppåt), högst 1920.
    /// Den lilla dockade bilden behöver en bråkdel av bildpunkterna i en fångst på 1280.
    @discardableResult
    private func fitCaptureSize() -> Bool {
        let window = previewView.window
        let scale = window?.backingScaleFactor ?? 2
        let shown = previewView.window === dockedPanel ? dockedContainer.imageSize : (window?.contentLayoutRect.size ?? .zero)
        guard shown.width > 0, shown.height > 0 else { return false }
        let needed = (max(shown.width, shown.height) * scale / 128).rounded(.up) * 128
        let dimension = min(max(needed, 384), 1920)
        guard dimension != captureDimension else { return false }
        captureDimension = dimension
        return true
    }

    private func applyCaptureSize() {
        let dimension = captureDimension
        Task { await engine.setMaxDimension(dimension) }
    }

    func windowDidResize(_ notification: Notification) {
        if running && fitCaptureSize() { applyCaptureSize() }
    }

    func hide() {
        panel.orderOut(nil)
        dockedPanel.orderOut(nil)
        guard running else { return }
        running = false
        currentSourceID = nil
        Task { await engine.stop() }
    }

    /// Startar bara om strömmen när källan faktiskt ändrats; placeringen ändras ofta.
    private func startEngine(_ source: Source) {
        let resized = fitCaptureSize()
        guard !running || currentSourceID != source.id else {
            if resized { applyCaptureSize() }
            return
        }
        running = true
        currentSourceID = source.id
        // Samma takt som scenen, annars ser förhandsvisningen hackig ut fast scenen är jämn.
        let dimension = captureDimension
        Task {
            await engine.setMaxDimension(dimension)
            try? await engine.start(source, fps: 60)
        }
    }

    /// Normaliserad scenpunkt (origo nere till vänster) under musen, om musen är över förhandsvisningen.
    func stagePointUnderMouse() -> CGPoint? {
        let mouse = NSEvent.mouseLocation
        guard let window = previewView.window, window.isVisible,
              NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0) == window.windowNumber else { return nil }
        let local = previewView.convert(window.convertPoint(fromScreen: mouse), from: nil)
        return previewView.normalizedStagePoint(local)
    }

    func windowWillClose(_ notification: Notification) {
        controller?.state.showPreview = false
    }

    /// Knapp i det flytande fönstrets titelrad som dockar tillbaka vid snabbpanelen.
    private func addDockButton() {
        let button = NSButton(image: NSImage(systemSymbolName: "pip.enter", accessibilityDescription: nil)!,
                              target: self, action: #selector(dock))
        button.isBordered = false
        button.frame = CGRect(x: 0, y: 0, width: 28, height: 20)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = button
        accessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(accessory)
        dockButtonAccessory = accessory
    }

    /// Sätter alla texter på nytt, vid start och när språket byts.
    func updateTexts() {
        panel.title = L("Preview – what the audience sees", "Förhandsvisning – det publiken ser")
        if let button = dockButtonAccessory?.view as? NSButton {
            button.image?.accessibilityDescription = L("Dock next to the quick panel", "Docka vid snabbpanelen")
            button.toolTip = L("Dock next to the quick panel", "Docka bredvid snabbpanelen")
        }
        dockedContainer.updateTexts()
    }

    @objc private func dock() {
        controller?.state.previewDocked = true
    }
}

/// Var förhandsvisningen kan sitta vid den utfällda panelen vid skärmens kant.
private struct EdgeDock {
    let anchor: CGRect
    let panelOnRight: Bool
    let size: CGSize

    /// `offset` är överkantens läge relativt panelens överkant. Bredvid: inåt skärmen, på valfri höjd.
    /// Längs kanten: ovanför eller under panelen (den sida mitten ligger på), utan att täcka den;
    /// får den inte plats där hamnar den på andra sidan.
    func frame(alongEdge: Bool, offset: CGFloat) -> CGRect {
        let visible = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? anchor
        let gap: CGFloat = 8
        let h = size.height
        var y = anchor.maxY + offset - h
        let x: CGFloat
        if alongEdge {
            x = panelOnRight ? visible.maxX - size.width : visible.minX
            let below = min(y, anchor.minY - gap - h)
            let above = max(y, anchor.maxY + gap)
            let wantsBelow = y + h / 2 < anchor.midY
            let fitsBelow = below >= visible.minY
            let fitsAbove = above + h <= visible.maxY
            y = (wantsBelow && fitsBelow) || !fitsAbove ? below : above
        } else {
            x = panelOnRight ? anchor.minX - gap - size.width : anchor.maxX + gap
        }
        y = min(max(y, visible.minY), visible.maxY - h)
        return CGRect(x: x, y: y, width: size.width, height: h).integral
    }
}

private final class DockedPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Sitter ihop med snabbpanelen ända upp mot skärmkanten; AppKit får inte flytta ner den under menyraden.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum DockPreviewSide { case left, right }

/// Svart yta som fortsätter snabbpanelen åt sidan, med bilden och knapparna Frigör och Större/Mindre.
/// Kompakt: lika hög som panelen, så att nederkanterna ligger i linje, och knapparna i en smal kolumn bredvid bilden.
/// Stor: högre än panelen, med knapparna i en rad under bilden.
final class DockedPreviewContainer: NSView {
    static let padding: CGFloat = 14
    /// Kompakt läge: luft mot panelen, mot ytterkanten och knappkolumnens bredd.
    static let compactInner: CGFloat = 4
    static let compactOuter: CGFloat = 10
    static let compactButtons: CGFloat = 30
    static let footerHeight: CGFloat = 30

    /// Vid kanten: luft ovanför bilden, där draghandtaget sitter.
    static func floatingTopGap(compact: Bool) -> CGFloat { compact ? 18 : 22 }

    var topGap: CGFloat = 4 { didSet { needsLayout = true; needsDisplay = true } }
    var imageSize: CGSize = .zero { didSet { needsLayout = true } }
    var compact = true { didSet { updateButtons(); needsLayout = true; needsDisplay = true } }
    var side: DockPreviewSide = .right { didSet { needsLayout = true; needsDisplay = true } }
    /// Lika hög som panelen: då är hörnet mot panelen rakt, annars rundat.
    var alignedWithPanel = true { didSet { needsDisplay = true } }
    /// Vid skärmens kant: en fristående rundad ruta bredvid panelen i stället för en fortsättning på den.
    /// Vid kanten går rutan att dra i kanten runt bilden; den hamnar sedan bredvid eller under panelen.
    var floating = false { didSet { needsLayout = true; needsDisplay = true } }
    var onDragEnded: (() -> Void)?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    var onDetach: (() -> Void)?
    var onToggleSize: (() -> Void)?
    private weak var preview: NSView?
    private let label = NSTextField(labelWithString: "")
    private let detach = NSButton()
    private let resize = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(hex: "#A9AEB8")
        addSubview(label)
        for b in [detach, resize] {
            b.isBordered = false
            b.contentTintColor = NSColor(hex: "#E6E8EC")
            b.target = self
            addSubview(b)
        }
        detach.action = #selector(detachTapped)
        resize.action = #selector(resizeTapped)
        updateTexts()
    }

    func updateTexts() {
        label.stringValue = L("What the audience sees", "Det publiken ser")
        detach.toolTip = L("Detach: make the preview a separate window you can move and resize",
                           "Frigör: gör förhandsvisningen till ett eget fönster som går att flytta och ändra storlek på")
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Total storlek för en bild av storleken `image`.
    static func size(image: CGSize, topGap: CGFloat, compact: Bool, inner: CGFloat = compactInner) -> CGSize {
        compact
            ? CGSize(width: inner + image.width + 8 + compactButtons + compactOuter, height: topGap + image.height + 12)
            : CGSize(width: image.width + padding * 2, height: topGap + image.height + footerHeight + 6)
    }

    private func updateButtons() {
        let font = NSFont.systemFont(ofSize: 12)
        let color = NSColor(hex: "#E6E8EC")!
        detach.image = NSImage(systemSymbolName: "pip.exit", accessibilityDescription: L("Detach the preview", "Frigör förhandsvisningen"))
        resize.image = NSImage(systemSymbolName: compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                               accessibilityDescription: compact ? L("Larger preview", "Större förhandsvisning") : L("Smaller preview", "Mindre förhandsvisning"))
        resize.toolTip = compact ? L("Larger preview", "Större förhandsvisning") : L("Smaller preview, in line with the menu bar", "Mindre förhandsvisning, i linje med menyn")
        if compact {
            detach.title = ""
            resize.title = ""
            detach.imagePosition = .imageOnly
            resize.imagePosition = .imageOnly
        } else {
            detach.imagePosition = .imageLeading
            resize.imagePosition = .imageLeading
            detach.attributedTitle = NSAttributedString(string: L(" Detach", " Frigör"), attributes: [.foregroundColor: color, .font: font])
            resize.attributedTitle = NSAttributedString(string: L(" Smaller", " Mindre"), attributes: [.foregroundColor: color, .font: font])
        }
        label.isHidden = compact
    }

    /// Raka överhörn mot skärmkanten. Nederhörnet mot panelen är rakt i kompakt läge, där de är lika höga.
    override func draw(_ dirtyRect: NSRect) {
        if floating {
            NSColor(hex: "#1B1D23")!.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
            // Draghandtaget: visar att rutan går att flytta. Hela ytan runt bilden går att dra i.
            let grip = CGRect(x: bounds.midX - 18, y: bounds.maxY - topGap / 2 - 2.5, width: 36, height: 5)
            NSColor(hex: "#6B707C")!.setFill()
            NSBezierPath(roundedRect: grip, xRadius: 2.5, yRadius: 2.5).fill()
            return
        }
        let r: CGFloat = 22
        let b = bounds
        let squareLeft = alignedWithPanel && side == .right
        let squareRight = alignedWithPanel && side == .left
        let path = NSBezierPath()
        path.move(to: CGPoint(x: b.minX, y: b.maxY))
        path.line(to: CGPoint(x: b.maxX, y: b.maxY))
        if squareRight {
            path.line(to: CGPoint(x: b.maxX, y: b.minY))
        } else {
            path.line(to: CGPoint(x: b.maxX, y: b.minY + r))
            path.appendArc(withCenter: CGPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: 0, endAngle: 270, clockwise: true)
        }
        if squareLeft {
            path.line(to: CGPoint(x: b.minX, y: b.minY))
        } else {
            path.line(to: CGPoint(x: b.minX + r, y: b.minY))
            path.appendArc(withCenter: CGPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: 270, endAngle: 180, clockwise: true)
        }
        path.close()
        NSColor.black.setFill()
        path.fill()
    }

    func setPreview(_ view: NSView) {
        preview?.removeFromSuperview()
        addSubview(view, positioned: .below, relativeTo: label)
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        preview = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let imageTop = bounds.height - topGap
        detach.sizeToFit()
        resize.sizeToFit()
        if compact {
            // Bilden närmast panelen, knappkolumnen mot ytterkanten.
            let inner = floating ? Self.compactOuter : Self.compactInner
            let imageX = side == .right ? inner : bounds.width - inner - imageSize.width
            preview?.frame = CGRect(x: imageX, y: imageTop - imageSize.height, width: imageSize.width, height: imageSize.height)
            let columnX = side == .right ? imageX + imageSize.width + 8 : Self.compactOuter
            let midY = imageTop - imageSize.height / 2
            let size = CGSize(width: Self.compactButtons, height: 24)
            resize.frame = CGRect(origin: CGPoint(x: columnX, y: midY + 2), size: size)
            detach.frame = CGRect(origin: CGPoint(x: columnX, y: midY - 2 - size.height), size: size)
        } else {
            preview?.frame = CGRect(x: (bounds.width - imageSize.width) / 2, y: imageTop - imageSize.height,
                                    width: imageSize.width, height: imageSize.height)
            let footerY = imageTop - imageSize.height - Self.footerHeight
            label.sizeToFit()
            label.frame.origin = CGPoint(x: Self.padding + 2, y: footerY + (Self.footerHeight - label.frame.height) / 2)
            detach.frame.origin = CGPoint(x: bounds.width - Self.padding - detach.frame.width,
                                          y: footerY + (Self.footerHeight - detach.frame.height) / 2)
            resize.frame.origin = CGPoint(x: detach.frame.minX - 12 - resize.frame.width, y: detach.frame.minY)
        }
    }

    @objc private func detachTapped() { onDetach?() }
    @objc private func resizeTapped() { onToggleSize?() }

    // Bilden tar själv emot musen (kamera, markering), så dragningen sker i ytan runt den.

    override func mouseDown(with event: NSEvent) {
        guard floating, let window else { return super.mouseDown(with: event) }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return super.mouseDragged(with: event) }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return super.mouseUp(with: event) }
        dragStart = nil
        if window?.frame.origin != start.origin { onDragEnded?() }
    }
}

private final class PreviewView: NSView {
    weak var controller: AppController?
    private let imageLayer = CALayer()
    private var buffer: CVPixelBuffer?
    private var imageSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func display(_ pb: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        buffer = pb
        imageSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        CATransaction.commit()
    }

    /// Punkt i vyn → normaliserad punkt i scenen (origo nere till vänster), eller nil utanför bilden.
    func normalizedStagePoint(_ p: CGPoint) -> CGPoint? {
        let rect = imageSize == .zero ? bounds : AVMakeRect(aspectRatio: imageSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let n = CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return nil }
        return n
    }

    private func forward(_ event: NSEvent, _ handler: (CGPoint) -> Void) {
        let p = convert(event.locationInWindow, from: nil)
        let rect = imageSize == .zero ? bounds : AVMakeRect(aspectRatio: imageSize, insideRect: bounds)
        // Drag får fortsätta utanför bilden; punkten kläms då mot kanten.
        let n = CGPoint(x: min(max((p.x - rect.minX) / max(rect.width, 1), 0), 1),
                        y: min(max((p.y - rect.minY) / max(rect.height, 1), 0), 1))
        handler(n)
    }

    override func mouseDown(with event: NSEvent) { forward(event) { controller?.stagePointer(.down, at: $0) } }
    override func mouseDragged(with event: NSEvent) { forward(event) { controller?.stagePointer(.dragged, at: $0) } }
    override func mouseUp(with event: NSEvent) { forward(event) { controller?.stagePointer(.up, at: $0) } }

    override func scrollWheel(with event: NSEvent) {
        let step = event.hasPreciseScrollingDeltas ? 0.002 : 0.02
        forward(event) { controller?.stageScroll(at: $0, delta: Double(event.scrollingDeltaY) * step) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.makeQuickMenu()
    }
}
