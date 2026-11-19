import AppKit
import Combine
import SwiftUI

/// Snabbpanelen: en flik vid skärmkanten (eller vid notchen) som fälls ut med snabbknappar.
/// Den syns aldrig i någon delning.
@MainActor
final class QuickDock {
    private let state: AppState
    private unowned let controller: AppController
    let model = DockModel()
    private var panel: NSPanel?
    private var hosting: NSView?
    private let tip = DockTip()
    private var cancellables = Set<AnyCancellable>()
    private var relayoutQueued = false
    private var shownTip: String?
    private var lastAnchor: CGRect?

    /// Snabbpanelens ram när den är utfälld – en dockad förhandsvisning sitter bredvid den.
    var dockedPreviewAnchor: CGRect? {
        guard state.dockPosition != .off, model.expanded, let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    var windowNumber: Int { panel?.windowNumber ?? 0 }

    /// Förhandsvisningen sitter bredvid panelen: rakt hörn mot den och ingen skugga som skulle synas som en skarv.
    func setPreviewAttached(_ side: DockPreviewSide?) {
        guard model.previewSide != side else { return }
        model.previewSide = side
        panel?.hasShadow = side == nil
    }

    var topInset: CGFloat { model.topInset }

    init(state: AppState, controller: AppController) {
        self.state = state
        self.controller = controller
        model.onHover = { [weak self] text, inside in self?.hover(text, inside: inside) }
        // Allt som kan ändra panelens storlek: platser, lägen och position.
        state.objectWillChange.sink { [weak self] in self?.queueRelayout() }.store(in: &cancellables)
        model.objectWillChange.sink { [weak self] in self?.queueRelayout() }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRelayout() }
        }
        queueRelayout()
    }

    // MARK: Åtgärder från vyn

    func toggle() {
        hideTip()
        guard !state.dockPinned else { return }
        model.expanded.toggle()
    }

    func expand() {
        guard !model.expanded else { return }
        hideTip()
        model.expanded = true
    }

    /// Fäller ut panelen och sätter markören i textfältet (vid kanten öppnas textrutan).
    func focusTextField() {
        expand()
        panel?.makeKey()
        if state.dockPosition == .notch {
            model.focusTextRequest += 1
        } else {
            model.textPopover = true
        }
    }

    /// Högerklick på timern: en ruta där längd eller klockslag skrivs in direkt.
    func openCountdownEditor() {
        hideTip()
        panel?.makeKey()
        let c = state.countdown
        let total = Int((c.minutes * 60).rounded())
        model.durationParts = [String(format: "%02d", min(total / 60, 99)), String(format: "%02d", total % 60)]
        model.clockParts = [String(format: "%02d", c.targetMinuteOfDay / 60), String(format: "%02d", c.targetMinuteOfDay % 60)]
        model.countdownField = c.mode == .untilTime ? .clock : .duration
        model.countdownPopover = true
    }

    func perform(_ action: () -> Void) {
        hideTip()
        action()
    }

    var controllerRef: AppController { controller }

    /// Flytta fliken längs kanten. `y` är skärmkoordinat för pekaren.
    func dragTab(toMouseY y: CGFloat) {
        guard let vf = sideScreen()?.visibleFrame, vf.height > 0 else { return }
        state.dockY = min(max(Double((y - vf.minY) / vf.height), 0.05), 0.95)
    }

    private func hideTip() {
        tip.hide()
        shownTip = nil
    }

    // MARK: Placering

    private func queueRelayout() {
        guard !relayoutQueued else { return }
        relayoutQueued = true
        // objectWillChange kommer innan värdet ändrats; vänta till nästa varv.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.relayoutQueued = false
                self.relayout()
            }
        }
    }

    private func relayout() {
        if state.dockPinned && !model.expanded { model.expanded = true }
        guard state.dockPosition != .off else {
            panel?.orderOut(nil)
            hideTip()
            notifyAnchor()
            return
        }
        let panel = self.panel ?? makePanel()
        updateNotchGeometry()
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        // Hela punkter för både storlek och läge: annars blir fönstret avrundat större än innehållet och en
        // genomskinlig strimma syns mot skärmkanten och mot en dockad förhandsvisning.
        let frame = frame(for: CGSize(width: ceil(size.width), height: ceil(size.height)))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        notifyAnchor()
    }

    /// Talar om för förhandsvisningen när platsen under panelen ändras (fälls ut/in, byter storlek).
    private func notifyAnchor() {
        let anchor = dockedPreviewAnchor
        guard anchor != lastAnchor else { return }
        lastAnchor = anchor
        controller.dockLayoutChanged()
    }

    private func frame(for size: CGSize) -> CGRect {
        switch state.dockPosition {
        case .notch, .aroundNotch:
            let (screen, centerX) = notchScreen()
            return CGRect(x: (centerX - size.width / 2).rounded(), y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        default:
            let vf = sideScreen()?.visibleFrame ?? .zero
            let cy = vf.minY + CGFloat(state.dockY) * vf.height
            let y = min(max(cy - size.height / 2, vf.minY), vf.maxY - size.height).rounded()
            let x = state.dockPosition == .right ? vf.maxX - size.width : vf.minX
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    /// Skärmen med menyraden; den virtuella scenskärmen blir aldrig huvudskärm.
    private func sideScreen() -> NSScreen? {
        NSScreen.screens.first
    }

    /// Skärmen med notch om det finns en, annars huvudskärmen. Ger också notchens mittpunkt.
    private func notchScreen() -> (NSScreen, CGFloat) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first ?? NSScreen.main!
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = screen.frame.width - left.width - right.width
            return (screen, screen.frame.minX + left.width + notch / 2)
        }
        return (screen, screen.frame.midX)
    }

    private func updateNotchGeometry() {
        let (screen, _) = notchScreen()
        // Menyraden kan vara en halv punkt hög (37,5); avrunda uppåt så att panelen fyller sitt fönster exakt.
        var top = ceil(screen.safeAreaInsets.top)
        var width: CGFloat = 180
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = (screen.frame.width - left.width - right.width).rounded()
        } else {
            top = ceil(max(24, screen.frame.maxY - screen.visibleFrame.maxY))
        }
        if model.topInset != top { model.topInset = top }
        if model.notchWidth != width { model.notchWidth = width }
    }

    private func makePanel() -> NSPanel {
        let p = DockPanel(contentRect: CGRect(x: 0, y: 0, width: 60, height: 80),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.sharingType = .none
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        // Efter isFloatingPanel, som annars sätter tillbaka nivån till .floating – då ligger panelen under
        // menyraden och klicken bredvid notchen går till menyraden i stället.
        p.level = .statusBar
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = FirstMouseHostingView(rootView: DockRootView(state: state, model: model, dock: self))
        p.contentView = view
        hosting = view
        panel = p
        return p
    }

    // MARK: Hjälptext vid pekaren

    /// Visas direkt när pekaren kommer in. Vid utträde döljs etiketten bara om den hör till samma knapp,
    /// eftersom nästa knapps "in" kan komma före förra knappens "ut".
    private func hover(_ text: String, inside: Bool) {
        guard inside else {
            if shownTip == text { tip.hide(); shownTip = nil }
            return
        }
        guard let panel, panel.isVisible else { return }
        shownTip = text
        let mouse = NSEvent.mouseLocation
        let size = tip.prepare(text)
        let f = panel.frame
        let origin: CGPoint
        switch state.dockPosition {
        case .left: origin = CGPoint(x: f.maxX + 8, y: mouse.y - size.height / 2)
        case .notch, .aroundNotch: origin = CGPoint(x: mouse.x - size.width / 2, y: f.minY - size.height - 8)
        default: origin = CGPoint(x: f.minX - size.width - 8, y: mouse.y - size.height / 2)
        }
        tip.show(at: origin)
    }
}

@MainActor
final class DockModel: ObservableObject {
    @Published var expanded = false
    @Published var topInset: CGFloat = 32
    @Published var notchWidth: CGFloat = 180
    /// Sidan där en dockad förhandsvisning sitter ihop med panelen; det hörnet blir rakt.
    @Published var previewSide: DockPreviewSide?
    /// Ökas för att be vyn sätta markören i textfältet.
    @Published var focusTextRequest = 0
    /// Vid kanten skrivs texten i en ruta bredvid knappen.
    @Published var textPopover = false
    @Published var countdownPopover = false
    /// Det som skrivs i timerrutan (minuter och sekunder, timmar och minuter), och vilken rad markören ska stå i när den öppnas.
    // Inte @Published: varje tangent skulle annars rita om panelen och popovern, och fältet tappa det som skrivs.
    var durationParts = ["", ""]
    var clockParts = ["", ""]
    @Published var countdownField: CountdownField = .duration
    enum CountdownField: Hashable { case duration, clock }
    var onHover: ((String, Bool) -> Void)?

    func hover(_ text: String, _ inside: Bool) { onHover?(text, inside) }
    // Pågående dragning av fliken (vyerna kan inte ha eget @State utan Xcode).
    var dragStartMouseY: CGFloat?
    var dragMoved = false
}

/// Blir nyckelfönster bara när textfältet används (becomesKeyOnlyIfNeeded), så att knapparna inte tar
/// fokus från appen du arbetar i. Panelen aktiverar aldrig appen.
private final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// AppKit flyttar annars ner fönstret under menyraden när det visas, så att den ihopfällda fliken
    /// hamnar under notchen i stället för i menyraden bredvid den.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Första klicket ska utföra knappen även när appen inte är aktiv.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Liten mörk etikett med knappens namn och kortkommando.
@MainActor
private final class DockTip {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func prepare(_ text: String) -> CGSize {
        let p = panel ?? make()
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 22, height: label.frame.height + 14)
        label.frame.origin = CGPoint(x: 11, y: 7)
        p.setContentSize(size)
        return size
    }

    func show(at origin: CGPoint) {
        guard let panel else { return }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.sharingType = .none
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(hex: "#1B1D23")?.cgColor
        box.layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(hex: "#F2F3F5")
        box.addSubview(label)
        p.contentView = box
        panel = p
        return p
    }
}

// MARK: - Vyer

private enum DockColor {
    static let panel = Color(nsColor: NSColor(hex: "#1B1D23")!)
    static let button = Color(nsColor: NSColor(hex: "#2E323B")!)
    static let notchButton = Color(nsColor: NSColor(hex: "#26292F")!)
    static let divider = Color(nsColor: NSColor(hex: "#353943")!)
    static let icon = Color(nsColor: NSColor(hex: "#E6E8EC")!)
    static let muted = Color(nsColor: NSColor(hex: "#A9AEB8")!)
    static let amber = Color(nsColor: NSColor(hex: "#FFB020")!)
    static let red = Color(nsColor: NSColor(hex: "#FF6B5E")!)
}

/// En knapp i panelen: en siffra (plats) eller en symbol.
private struct DockItem: Identifiable {
    enum Face { case number(Int), symbol(String) }
    let id: String
    let face: Face
    let tip: String
    var active = false
    var destructive = false
    let action: () -> Void
}

struct DockRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: DockModel
    let dock: QuickDock
    @FocusState private var textFocused: Bool

    private var controller: AppController { dock.controllerRef }
    private var sharing: Bool { state.activeSource != nil }

    var body: some View {
        Group {
            switch state.dockPosition {
            case .notch: model.expanded ? AnyView(notchExpanded) : AnyView(notchCollapsed)
            case .aroundNotch: model.expanded ? AnyView(aroundExpanded) : AnyView(notchCollapsed)
            default: model.expanded ? AnyView(sideExpanded) : AnyView(sideTab)
            }
        }
        .fixedSize()
    }

    private func tip(_ text: String, _ action: HotkeyAction?) -> String {
        guard let action, let keys = state.keys(action) else { return text }
        return "\(text) (\(keys))"
    }

    private var slotItems: [DockItem] {
        state.slots.indices.compactMap { i in
            guard let s = state.slots[i] else { return nil }
            return DockItem(id: "slot\(i)", face: .number(i + 1), tip: tip("\(i + 1) · \(s.displayName)", .showSlot(i)),
                            active: state.activeSlot == i) {
                // Den plats som redan delas: ett klick slutar dela.
                if state.activeSlot == i { controller.stopSharing() } else { controller.activateSlot(i) }
            }
        }
    }

    private var screenActive: Bool { state.activeSource?.kind == .display && state.activeSlot == nil }

    private var screenItem: DockItem {
        DockItem(id: "screen", face: .symbol("display"), tip: tip(L("Share entire screen", "Dela hela skärmen"), .shareScreen),
                 active: screenActive) {
            if screenActive { controller.stopSharing() } else { controller.shareScreenUnderMouse() }
        }
    }

    /// Knappen för ett verktyg (platserna hanteras för sig).
    private func item(_ tool: DockTool) -> DockItem? {
        let cam = state.camera
        switch tool {
        case .slots, .divider, .notch, .lamp:
            return nil
        case .screen:
            return screenItem
        case .camera:
            return DockItem(id: "camera", face: .symbol(cam.enabled ? "video.fill" : "video"), tip: tip(cam.enabled ? L("Camera on", "Kamera på") : L("Camera off", "Kamera av"), .toggleCamera),
                            active: cam.enabled) { controller.toggleCamera() }
        case .onlyMe:
            return DockItem(id: "onlyMe", face: .symbol("person"), tip: tip(L("Just me", "Bara jag"), .cameraFullscreen),
                            active: cam.enabled && cam.fullscreen) { controller.toggleCameraFullscreen() }
        case .spotlight:
            return DockItem(id: "spotlight", face: .symbol("sun.max"), tip: tip("Spotlight", .toggleSpotlight),
                            active: state.effects.mode == .spotlight) { controller.toggleSpotlight() }
        case .highlight:
            return DockItem(id: "highlight", face: .symbol("rectangle.dashed"),
                            tip: tip(state.effects.mode == .rect ? L("Remove the highlight", "Ta bort markeringen") : L("Draw highlight", "Rita markering"), .drawHighlight),
                            active: state.effects.mode == .rect) {
                if state.effects.mode == .rect {
                    state.effects.mode = .off
                    state.effects.rect = nil
                } else {
                    controller.beginRegionSelect()
                }
            }
        case .clear:
            return DockItem(id: "clear", face: .symbol("eraser"), tip: tip(L("Clear the stage", "Rensa scenen"), .clearEffects)) { controller.clearEffects() }
        case .freeze:
            return DockItem(id: "freeze", face: .symbol("pause"), tip: tip(state.frozen ? L("Picture frozen", "Bilden är fryst") : L("Freeze picture", "Frys bilden"), .toggleFreeze),
                            active: state.frozen) { controller.toggleFreeze() }
        case .countdown:
            return DockItem(id: "countdown", face: .symbol("timer"), tip: countdownTip,
                            active: state.countdownStatus != .idle) {
                // Aktiv nedräkning: ett klick tar bort den (genvägen pausar och fortsätter).
                if state.countdownStatus == .idle { controller.startCountdown() } else { controller.cancelCountdown() }
            }
        case .text:
            return DockItem(id: "text", face: .symbol("text.bubble"),
                            tip: tip(state.textMode || state.textShown ? L("Close text mode", "Stäng textläget") : L("Text mode: type a text to show on the stage", "Textläge: skriv en text att visa på scenen"), .toggleText),
                            active: state.textMode || state.textShown) {
                // Under notchen visas textfältet i panelen; annars öppnas en ruta att skriva i.
                if state.dockPosition == .notch {
                    controller.toggleTextMode()
                } else if state.textShown {
                    state.textShown = false
                    model.textPopover = false
                } else {
                    model.textPopover.toggle()
                }
            }
        case .stop:
            return DockItem(id: "stop", face: .symbol("stop.fill"), tip: tip(L("Stop sharing", "Sluta dela"), .stopSharing), destructive: true) { controller.stopSharing() }
        case .preview:
            return DockItem(id: "preview", face: .symbol("eye"), tip: L("Preview", "Förhandsvisning"), active: state.showPreview) { state.showPreview.toggle() }
        case .panel:
            return DockItem(id: "panel", face: .symbol("slider.horizontal.3"), tip: L("Open the control panel", "Öppna kontrollpanelen")) { controller.showPanel() }
        }
    }

    /// En rad i panelen: en knapp, platserna eller en avdelare.
    fileprivate enum Entry: Identifiable {
        case item(DockItem), slots([DockItem]), divider(Int), lamp
        var id: String {
            switch self {
            case .item(let i): i.id
            case .lamp: "lamp"
            case .slots: "slots"
            case .divider(let n): "divider\(n)"
            }
        }
        var isDivider: Bool { if case .divider = self { true } else { false } }
    }

    /// Verktygen i användarens ordning. Avdelare i början, i slutet eller två i rad visas inte.
    private func entries(_ tools: [DockTool]) -> [Entry] {
        var result: [Entry] = []
        for (n, tool) in tools.enumerated() {
            switch tool {
            case .notch: continue
            case .lamp: result.append(.lamp)
            case .divider:
                if let last = result.last, !last.isDivider { result.append(.divider(n)) }
            case .slots:
                let slots = slotItems
                if !slots.isEmpty { result.append(.slots(slots)) }
            default:
                if let i = item(tool) { result.append(.item(i)) }
            }
        }
        while result.last?.isDivider == true { result.removeLast() }
        return result
    }

    private var countdownTip: String {
        switch state.countdownStatus {
        case .idle: tip(L("Start countdown, \(state.countdown.shortDescription)", "Starta nedräkning, \(state.countdown.shortDescription)"), .toggleCountdown)
            + L(" · right-click for length", " · högerklick för längd")
        case .running: tip(L("Remove the countdown, \(CountdownSettings.formatTime(state.countdownRemaining)) left", "Ta bort nedräkningen, \(CountdownSettings.formatTime(state.countdownRemaining)) kvar"), .toggleCountdown)
        case .paused: tip(L("Remove the paused countdown", "Ta bort den pausade nedräkningen"), .toggleCountdown)
        case .finished: tip(L("Remove the countdown", "Ta bort nedräkningen"), .toggleCountdown)
        }
    }

    // MARK: Kant

    private var right: Bool { state.dockPosition != .left }

    private var sideShape: UnevenRoundedRectangle {
        let r: CGFloat = model.expanded ? 16 : 12
        return right
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0)
            : UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r)
    }

    private var sideTab: some View {
        VStack(spacing: 8) {
            Circle().fill(sharing ? DockColor.amber : DockColor.divider).frame(width: 7, height: 7)
            Image(systemName: right ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DockColor.icon)
        }
        .frame(width: 30, height: 72)
        .background(sideShape.fill(DockColor.panel))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    let y = NSEvent.mouseLocation.y
                    if model.dragStartMouseY == nil { model.dragStartMouseY = y; model.dragMoved = false }
                    if let start = model.dragStartMouseY, abs(y - start) > 3 { model.dragMoved = true }
                    if model.dragMoved { dock.dragTab(toMouseY: y) }
                }
                .onEnded { _ in
                    let moved = model.dragMoved
                    model.dragStartMouseY = nil
                    model.dragMoved = false
                    if !moved { dock.toggle() }
                }
        )
        .overlay(HoverTracker { model.hover(sharing ? L("Sharing: \(shareName) · click for the quick panel", "Delar: \(shareName) · klicka för snabbpanelen") : L("Quick panel · drag to move", "Snabbpanel · dra för att flytta"), $0) })
        .accessibilityLabel(L("Expand the quick panel", "Fäll ut snabbpanelen"))
    }

    private var shareName: String {
        state.activeSource.map { s in (state.activeSlot.map { "\($0 + 1) · " } ?? "") + s.displayName } ?? L("nothing", "ingenting")
    }

    private func slotGrid(_ slots: [DockItem]) -> some View {
        let twoColumns = slots.count > 4
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(twoColumns ? 22 : 40), spacing: 4), count: twoColumns ? 2 : 1), spacing: 4) {
            ForEach(slots) { item in
                button(item, size: CGSize(width: twoColumns ? 22 : 40, height: twoColumns ? 28 : 34), notch: false)
            }
        }
    }

    private var sideExpanded: some View {
        VStack(spacing: 4) {
            ForEach(entries(state.dockLayout)) { entry in
                switch entry {
                case .slots(let slots): slotGrid(slots)
                case .divider: sideDivider
                case .item(let item): button(item, size: CGSize(width: 44, height: 44), notch: false)
                case .lamp: lamp(size: CGSize(width: 44, height: 24))
                }
            }
            if !state.dockPinned { collapseButton }
        }
        .padding(.vertical, 10)
        .frame(width: 60)
        .background(sideShape.fill(DockColor.panel))
    }

    private var collapseButton: some View {
            Button(action: { dock.toggle() }) {
                Image(systemName: right ? "chevron.right" : "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DockColor.icon)
                    .frame(width: 44, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(HoverTracker { model.hover(L("Collapse the quick panel", "Fäll in snabbpanelen"), $0) })
            .accessibilityLabel(L("Collapse the quick panel", "Fäll in snabbpanelen"))
    }

    private var sideDivider: some View {
        Rectangle().fill(DockColor.divider).frame(width: 32, height: 1).padding(.vertical, 4)
    }

    // MARK: Notch

    private var notchCollapsed: some View {
        HStack {
            Spacer()
            lampDot
        }
        .padding(.trailing, 10)
        .frame(width: model.notchWidth + 40, height: model.topInset)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black))
        .contentShape(Rectangle())
        .onTapGesture { dock.toggle() }
        .overlay(HoverTracker { model.hover(sharing ? L("Sharing: \(shareName) · click for the quick panel", "Delar: \(shareName) · klicka för snabbpanelen") : L("Click for BetterScreenSharing", "Klicka för BetterScreenSharing"), $0) })
        .accessibilityLabel(L("Expand the quick panel", "Fäll ut snabbpanelen"))
    }

    private var lampDot: some View {
        Circle().fill(sharing ? DockColor.amber : DockColor.divider).frame(width: 8, height: 8)
    }

    /// Delningslampan som verktyg i den utfällda panelen, lika stor yta som en knapp så att raden håller takten.
    private func lamp(size: CGSize) -> some View {
        lampDot
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .overlay(HoverTracker { model.hover(sharing ? L("Sharing: \(shareName)", "Delar: \(shareName)") : L("Nothing is being shared right now", "Inget delas just nu"), $0) })
            .accessibilityLabel(sharing ? L("Sharing: \(shareName)", "Delar: \(shareName)") : L("Nothing is being shared right now", "Inget delas just nu"))
    }

    private var notchExpanded: some View {
        VStack(spacing: 8) {
            Color.black
                .frame(height: model.topInset)
                .contentShape(Rectangle())
                .onTapGesture { dock.toggle() }
                .accessibilityLabel(L("Collapse the quick panel", "Fäll in snabbpanelen"))
            HStack(spacing: 4) {
                ForEach(entries(state.dockLayout)) { entry in
                    switch entry {
                    case .slots(let slots): ForEach(slots) { button($0, size: CGSize(width: 36, height: 32), notch: true) }
                    case .divider: notchDivider
                    case .item(let item): button(item, size: CGSize(width: 40, height: 40), notch: true)
                    case .lamp: lamp(size: CGSize(width: 24, height: 40))
                    }
                }
            }
            if state.textMode { textRow }
            Text(sharing ? L("Sharing: \(shareName)", "Delar: \(shareName)") : L("Nothing is being shared right now", "Inget delas just nu"))
                .font(.system(size: 12))
                .foregroundStyle(DockColor.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(minWidth: model.notchWidth + 40)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: model.previewSide == .left ? 0 : 22,
                                           bottomTrailingRadius: model.previewSide == .right ? 0 : 22).fill(Color.black))
    }

    // MARK: Runt notchen

    /// Knapparna till vänster och höger om notchen, i menyradens höjd. Notchens del är tom och fäller in panelen.
    private var aroundExpanded: some View {
        let layout = state.dockLayout
        let split = layout.firstIndex(of: .notch) ?? layout.count / 2
        let left = entries(Array(layout[..<split]))
        let rightSide = entries(Array(layout[split...]))
        // Lika breda sidor, så att den tomma mitten hamnar exakt över notchen.
        let side = max(rowWidth(left), rowWidth(rightSide))
        return HStack(spacing: 0) {
            aroundRow(left).frame(width: side, alignment: .trailing)
            Color.black
                .frame(width: model.notchWidth, height: model.topInset)
                .contentShape(Rectangle())
                .onTapGesture { dock.toggle() }
                .accessibilityLabel(L("Collapse the quick panel", "Fäll in snabbpanelen"))
            aroundRow(rightSide).frame(width: side, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: model.topInset)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: model.previewSide == .left ? 0 : 12,
                                           bottomTrailingRadius: model.previewSide == .right ? 0 : 12).fill(Color.black))
    }

    private var aroundButton: CGSize {
        let h = max(22, model.topInset - 6)
        return CGSize(width: h + 4, height: h)
    }

    private func aroundRow(_ row: [Entry]) -> some View {
        HStack(spacing: 2) {
            ForEach(row) { entry in
                switch entry {
                case .slots(let slots):
                    ForEach(slots) { button($0, size: CGSize(width: aroundButton.height, height: aroundButton.height - 4), notch: true, iconSize: 14) }
                case .divider:
                    Rectangle().fill(DockColor.divider).frame(width: 1, height: aroundButton.height * 0.6).padding(.horizontal, 3)
                case .item(let item):
                    button(item, size: aroundButton, notch: true, iconSize: 14)
                case .lamp:
                    lamp(size: CGSize(width: 20, height: aroundButton.height))
                }
            }
        }
    }

    private func rowWidth(_ row: [Entry]) -> CGFloat {
        row.reduce(0) { width, entry in
            switch entry {
            case .slots(let slots): width + CGFloat(slots.count) * (aroundButton.height + 2)
            case .divider: width + 9
            case .item: width + aroundButton.width + 2
            case .lamp: width + 22
            }
        }
    }

    // MARK: Nedräkning

    /// Högerklick på timern: en egen tid eller ett klockslag skrivs in direkt, och Retur startar.
    private var countdownPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Countdown", "Nedräkning")).font(.system(size: 13, weight: .semibold))
            countdownRow(L("Set custom time (MM:SS)", "Sätt egen tid (MM:SS)"), parts: $model.durationParts, field: .duration)
            countdownRow(L("Until a time (HH:MM)", "Till klockslag (HH:MM)"), parts: $model.clockParts, field: .clock)
            HStack {
                Spacer()
                Button(L("More settings…", "Fler inställningar…")) {
                    model.countdownPopover = false
                    controller.showPanel(section: .countdown)
                }
                .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 300)
        .environment(\.colorScheme, .dark)
        .background(DockColor.panel)
    }

    private func countdownRow(_ title: String, parts: Binding<[String]>, field: DockModel.CountdownField) -> some View {
        return HStack(spacing: 8) {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 4)
            TimePairField(parts: parts, placeholders: field == .clock ? ("HH", "MM") : ("MM", "SS"),
                          autofocus: model.countdownField == field) { startCountdown(parts.wrappedValue, field) }
                .fixedSize()
            Button(L("Start", "Starta")) { startCountdown(parts.wrappedValue, field) }
                .buttonStyle(.borderedProminent)
                .tint(DockColor.amber)
        }
    }

    /// Sekunder för en egen tid eller minut på dygnet för ett klockslag. Ett tomt fält räknas som 0.
    private func parseCountdown(_ parts: [String], _ field: DockModel.CountdownField) -> Int? {
        guard parts.contains(where: { !$0.isEmpty }), let a = Int(parts[0].isEmpty ? "0" : parts[0]),
              let b = Int(parts[1].isEmpty ? "0" : parts[1]), (0..<60).contains(b) else { return nil }
        switch field {
        case .duration:
            let seconds = a * 60 + b
            return seconds > 0 ? seconds : nil
        case .clock:
            return a < 24 ? a * 60 + b : nil
        }
    }

    private func startCountdown(_ parts: [String], _ field: DockModel.CountdownField) {
        guard let value = parseCountdown(parts, field) else { NSSound.beep(); return }
        switch field {
        case .duration:
            state.countdown.mode = .duration
            state.countdown.minutes = Double(value) / 60
        case .clock:
            state.countdown.mode = .untilTime
            state.countdown.targetMinuteOfDay = value
        }
        controller.cancelCountdown()
        controller.startCountdown()
        model.countdownPopover = false
    }

    // MARK: Text

    /// Skriv texten direkt i panelen. Scenen ändras först när du klickar Visa; visas texten redan uppdateras den medan du skriver.
    private var textField: some View {
        TextField("", text: $state.textMessage, prompt: Text(L("Type a text to show on the stage…", "Skriv en text att visa på scenen…")).foregroundStyle(DockColor.muted))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(DockColor.icon)
            .focused($textFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(DockColor.notchButton))
            .onChange(of: model.focusTextRequest) { _ in textFocused = true }
    }

    private var textToggle: some View {
        Button(action: {
            dock.perform {
                if state.textShown {
                    state.textShown = false
                } else if !state.textMessage.trimmingCharacters(in: .whitespaces).isEmpty {
                    state.textShown = true
                }
            }
        }) {
            // Samma ord hela tiden; gul betyder att texten visas på scenen.
            Text(L("Show", "Visa"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.textShown ? Color.black : DockColor.icon)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(state.textShown ? DockColor.amber : DockColor.notchButton))
        }
        .buttonStyle(.plain)
        .overlay(HoverTracker { model.hover(tip(state.textShown ? L("Text is showing · click to remove it", "Texten visas · klicka för att ta bort den") : L("Show the text on the stage", "Visa texten på scenen"), .toggleText), $0) })
    }

    private var textRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14))
                .foregroundStyle(state.textShown ? DockColor.amber : DockColor.muted)
            textField
                .frame(width: 380)
            textToggle
                .disabled(state.textMessage.trimmingCharacters(in: .whitespaces).isEmpty && !state.textShown)
        }
        // Raden skapas när textläget slås på; då ska markören hamna i fältet direkt.
        .onAppear { DispatchQueue.main.async { textFocused = true } }
    }

    private var textPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Text on stage", "Text på scenen")).font(.system(size: 13, weight: .semibold)).foregroundStyle(DockColor.icon)
            HStack(spacing: 8) {
                textField.frame(width: 300)
                textToggle
            }
        }
        .padding(14)
        .background(DockColor.panel)
        .onAppear { DispatchQueue.main.async { textFocused = true } }
    }

    private var notchDivider: some View {
        Rectangle().fill(DockColor.divider).frame(width: 1, height: 24).padding(.horizontal, 6)
    }

    // MARK: Knapp

    /// Var rutor från en knapp öppnas: mot skärmens mitt vid kanten, nedåt vid notchen.
    private var popoverEdge: Edge {
        state.dockPosition.atNotch ? .bottom : (right ? .leading : .trailing)
    }

    private func button(_ item: DockItem, size: CGSize, notch: Bool, iconSize: CGFloat = 17) -> some View {
        let fg: Color
        let bg: Color
        switch item.face {
        case .number:
            fg = item.active ? Color.black : DockColor.icon
            bg = item.active ? DockColor.amber : (notch ? DockColor.notchButton : DockColor.button)
        case .symbol:
            fg = item.destructive ? DockColor.red : (item.active ? DockColor.amber : DockColor.icon)
            bg = .clear
        }
        return Button(action: { dock.perform(item.action) }) {
            Group {
                switch item.face {
                case .number(let n):
                    Text("\(n)").font(.system(size: size.width < 30 ? 12 : 14, weight: item.active ? .bold : .semibold))
                case .symbol(let name):
                    Image(systemName: name).font(.system(size: iconSize, weight: .regular))
                }
            }
            .foregroundStyle(fg)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: notch ? 10 : 9).fill(bg))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(HoverTracker(onChange: { model.hover(item.tip, $0) }, onRightClick: rightClickAction(item)))
        .accessibilityLabel(item.tip)
        .popover(isPresented: item.id == "text" && state.dockPosition != .notch ? $model.textPopover : .constant(false),
                 arrowEdge: popoverEdge) {
            textPopoverContent
        }
        .popover(isPresented: item.id == "countdown" ? $model.countdownPopover : .constant(false), arrowEdge: popoverEdge) {
            countdownPopoverContent
        }
    }

    /// Högerklick: en plats tas bort direkt, timern öppnar rutan för längd och klockslag.
    private func rightClickAction(_ item: DockItem) -> (() -> Void)? {
        if case .number(let n) = item.face {
            return { dock.perform { controller.removeSlot(n - 1) } }
        }
        if item.id == "countdown" {
            return { dock.openCountdownEditor() }
        }
        return nil
    }

}

// MARK: - Hjälptext direkt vid hovring

/// Spårar pekaren över en knapp även när appen inte är aktiv (SwiftUI:s onHover gör inte alltid det i en
/// panel som inte tar fokus). Släpper igenom alla klick till knappen under.
private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void
    var onRightClick: (() -> Void)?

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onChange = onChange
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: HoverTrackingView, context: Context) {
        view.onChange = onChange
        view.onRightClick = onRightClick
    }
}

private final class HoverTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    var onRightClick: (() -> Void)?

    /// Vänsterklick går alltid vidare till knappen under; högerklick (eller ⌃-klick) fångas bara om det finns en åtgärd.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onRightClick != nil, let event = NSApp.currentEvent,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    override func mouseDown(with event: NSEvent) { onRightClick?() } // ⌃-klick

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}
