import AppKit
import AVFoundation
import Carbon
import Combine
import ScreenCaptureKit
import SwiftUI

/// Binder ihop tillstånd, fångst, kamera, scen, kortkommandon och menyrad.
@MainActor
final class AppController: NSObject, NSMenuDelegate, NSWindowDelegate {
    static let shared = AppController()
    static var stageTitle: String { L("BetterScreenSharing – Stage", "BetterScreenSharing – Scen") }

    let state = AppState.shared
    private let capture = CaptureEngine()
    private let camera = CameraController()
    private let hud = HUD()

    private var stageWindow: NSWindow!
    private var stageView: StageView!
    private var panelWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var spotlightTimer: Timer?
    private var boundsTimer: Timer?
    private var sourceBounds: CGRect? { didSet { updatePresenterDim() } }
    private let presenterDim = PresenterDim()
    /// Spotlightens mitt i källan, som scenen använder; dimningen hos presentatören följer samma punkt.
    private var spotCenter: CGPoint?
    /// Pekarens läge och källans ram vid förra spotlight-varvet; oförändrade behöver inget räknas om.
    private var lastSpotInput: (mouse: CGPoint, bounds: CGRect?)?
    private var presenterTimer: Timer?
    private var lastExternalApp: NSRunningApplication?
    private var lastCamera = CameraSettings()
    private var captureBusy = false
    private var pendingSource: Source?
    private var activity: NSObjectProtocol?
    private var hotkeysSuspended = false
    /// En markering ritas på skärmen: då gör Esc bara en sak, avbryter ritningen.
    private var regionSelecting = false
    private var recordMonitor: Any?
    private var sourceFrameCount = 0
    private var fpsTimer: Timer?
    private var idleReason: IdleReason? = .stopped
    /// Kameran startades bara för meddelandet "Bara jag" och ska stängas när delningen börjar igen.
    private var idleCameraRunning = false
    private let virtualDisplay = VirtualDisplayManager()
    private let shepherd = WindowShepherd()
    private let cursorFence = CursorFence()
    /// Falskt medan guiden för behörigheter visas vid start: då finns ännu inga andra fönster att visa.
    private var started = false
    private var strayWindowHintShown = false
    private var preview: PreviewWindowController!
    private var dock: QuickDock!
    private var countdownTimer: Timer?
    private var countdownEnd: Date?
    private var countdownTotal: TimeInterval = 0
    private var countdownWarned = false
    private var bareClearRegistered = false
    private var capsTimer: Timer?
    private var capsWasOn = false
    /// Funktionslägets enskilda tangenter är registrerade.
    private var capsLayerActive = false
    private var capsDrawLayer: DrawLayer?
    /// Markeringen ritades i Caps Lock-läget och tas bort när Caps Lock slås av.
    private var capsDrawnHighlight: CGRect?

    // MARK: - Start

    func start() {
        // Utan detta kan App Nap strypa uppdateringen när scenen ligger bakom andra fönster.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Screen sharing")
        // Ett klick i den dimmade ytan runt markeringen tar bort den.
        presenterDim.onDimClick = { [weak self] in
            guard let self, self.state.effects.mode == .rect else { return }
            self.state.effects.mode = .off
            self.state.effects.rect = nil
        }

        if !CGPreflightScreenCaptureAccess() { state.screenPermissionMissing = true }
        PermissionWizard.shared.onSkip = { [weak self] step in self?.state.skippedPermissions.insert(step) }
        // Diagnostiken körs utan någon som kan klicka sig igenom guiden.
        let steps = CommandLine.arguments.contains("--diagnose") ? [] : permissionsToAskFor()
        guard !steps.isEmpty else { startAfterPermissions(); return }
        // Resten väntar på guiden: fångsten och kameran kan annars få systemet att fråga före förklaringen.
        PermissionWizard.shared.run(steps) { [weak self] in self?.startAfterPermissions() }
    }

    /// Skärminspelning krävs och efterfrågas alltid. De valfria efterfrågas tills användaren har hoppat över dem.
    /// En nekad kamera ingår inte: den efterfrågas inte igen förrän den behövs, och då visas ett felmeddelande.
    private func permissionsToAskFor() -> [PermissionStep] {
        var steps: [PermissionStep] = []
        if !PermissionStep.screenRecording.isGranted { steps.append(.screenRecording) }
        if state.stageMode == .virtualDisplay, state.moveStrayWindows, !PermissionStep.accessibility.isGranted,
           !state.skippedPermissions.contains(.accessibility) {
            steps.append(.accessibility)
        }
        if PermissionStep.camera.asksDirectly, !state.skippedPermissions.contains(.camera) {
            steps.append(.camera)
        }
        return steps
    }

    private func startAfterPermissions() {
        started = true
        makeStageWindow()
        preview = PreviewWindowController(controller: self)
        virtualDisplay.onTerminated = { [weak self] in
            guard let self, self.state.stageMode == .virtualDisplay else { return }
            self.state.statusMessage = L("The system removed the virtual display. Switching to window mode.", "Den virtuella skärmen togs bort av systemet. Växlar till fönsterläge.")
            self.state.stageMode = .window
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        capture.onFrame = { [weak self] pb in
            // Bilder som redan var på väg när delningen stoppades får inte dölja meddelandet.
            guard let self, !self.state.frozen, self.state.activeSource != nil else { return }
            self.sourceFrameCount += 1
            self.stageView.display(pb)
        }
        capture.onStop = { [weak self] error in self?.captureStopped(error) }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }

        // Byts tangentbordslayout kan tangenten för § ändras; registrera om genvägarna.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                HotkeyAction.cachedSectionKey = nil
                self?.registerHotkeys()
            }
        }
        applyStageMode()
        bindState()
        registerHotkeys()
        setupStatusItem()
        dock = QuickDock(state: state, controller: self)
        updatePreview()
        startCapsLockWatch()
        refreshCameraDevices()
        showPanel()
        if !CommandLine.arguments.contains("--diagnose") {
            // Först videon om hur man delar, sedan guiden där genvägarna kan provas.
            if !state.tutorialShown {
                let guideNext = !state.shortcutGuideShown
                TutorialVideo.shared.show(state: state, next: guideNext ? L("Continue", "Fortsätt") : nil) { [weak self] in
                    if guideNext { self?.showShortcutGuide() }
                }
            } else if !state.shortcutGuideShown {
                showShortcutGuide()
            }
        }

        Task { await refreshSources() }

        // Tolerans låter systemet samla väckningar och spara energi; de här behöver inte vara exakta.
        boundsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollSourceBounds()
                self?.shepherdWindows()
                self?.cursorFence.enforce()
            }
        }
        boundsTimer?.tolerance = 0.1
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFPS() }
        }
        fpsTimer?.tolerance = 0.2
        runDiagnosticsIfRequested()
    }

    private func updateFPS() {
        let stats = state.frameStats
        let source = Double(sourceFrameCount)
        let previewFPS = preview.isVisible ? Double(preview.frameCount) : 0
        if stats.source != source { stats.source = source }
        if stats.preview != previewFPS { stats.preview = previewFPS }
        sourceFrameCount = 0
        preview.resetFrameCount()
    }

    /// `--diagnose <loggfil> [--stage-mode window]`: mät bildfrekvensen, skriv loggen och avsluta.
    /// Läge och förhandsvisning ändras bara under mätningen och återställs sedan.
    private func runDiagnosticsIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--diagnose"), i + 1 < args.count else { return }
        let logPath = args[i + 1]
        let savedMode = state.stageMode
        let savedPreview = state.showPreview
        state.showPreview = true
        if let m = args.firstIndex(of: "--stage-mode"), m + 1 < args.count, let mode = StageMode(rawValue: args[m + 1]) {
            state.stageMode = mode
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let variants = [DiagnosticVariant(name: state.stageMode == .virtualDisplay ? "Virtual display" : "Window mode") {}]
            await Diagnostics.run(stageWindow: stageWindow, stageView: stageView,
                                  virtualDisplayID: { [weak self] in
                                      guard let self, self.state.stageMode == .virtualDisplay else { return nil }
                                      return self.virtualDisplay.displayID
                                  },
                                  variants: variants,
                                  extraInfo: { [weak self] in "preview: \(Int(self?.state.frameStats.preview ?? 0)) frames/s" },
                                  logPath: logPath)
            state.stageMode = savedMode
            state.showPreview = savedPreview
            NSApp.terminate(nil)
        }
    }

    private func makeStageWindow() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = Self.stageTitle
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.collectionBehavior = [.fullScreenPrimary, .managed]
        stageView = StageView(frame: w.contentLayoutRect)
        stageView.controller = self
        w.contentView = stageView
        w.center()
        stageWindow = w

        stageView.setBackground(state.stageBackground)
        stageView.apply(camera: state.camera, animated: false)
        stageView.apply(effects: state.effects)
        stageView.attachPreview(camera.previewLayer)
        // Kameran är inte igång vid start. Med "av" här startar bindState den om den var påslagen förra gången.
        lastCamera = state.camera
        lastCamera.enabled = false
        showIdle(.stopped)
    }

    // MARK: - Scenläge

    /// Lägger scenen på den virtuella skärmen eller i ett vanligt fönster.
    private func applyStageMode() {
        switch state.stageMode {
        case .virtualDisplay:
            guard virtualDisplay.ensure(size: virtualDisplaySize) else {
                state.statusMessage = L("This version of macOS doesn't support virtual displays. The stage is shown in a window instead.", "Virtuell skärm stöds inte i den här macOS-versionen. Scenen visas i ett fönster i stället.")
                state.stageMode = .window
                return
            }
            let w = stageWindow!
            w.styleMask = [.borderless]
            w.title = Self.stageTitle
            w.hasShadow = false
            switch state.shareTarget {
            case .window:
                // Vanlig fönsternivå: då listar mötesappen scenen bland fönstren och kan dela den.
                // Fönstret ligger under skärmens menyrad (se virtualDisplaySize), så menyraden kommer inte med
                // när mötesappen fångar fönstret som ett utsnitt av skärmen.
                w.level = .normal
            case .screen:
                // Över menyrad och Dock, så att inget annat syns när hela skärmen delas.
                w.level = .screenSaver
            }
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            w.isExcludedFromWindowsMenu = true
            cursorFence.stageDisplay = virtualDisplay.displayID
            placeStageOnVirtualDisplay()
        case .window:
            cursorFence.stageDisplay = nil
            virtualDisplay.destroy()
            let w = stageWindow!
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = Self.stageTitle
            w.hasShadow = true
            w.level = .normal
            w.collectionBehavior = [.fullScreenPrimary, .managed]
            w.isExcludedFromWindowsMenu = false
            if let vf = NSScreen.main?.visibleFrame {
                let size = CGSize(width: min(1280, vf.width * 0.8), height: min(720, vf.height * 0.8))
                w.setFrame(CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
            w.makeKeyAndOrderFront(nil)
        }
        updatePreview()
    }

    private func placeStageOnVirtualDisplay() {
        guard state.stageMode == .virtualDisplay, let id = virtualDisplay.displayID,
              let screen = NSScreen.screen(for: id) else { return } // Skärmen dyker upp strax; screensChanged gör om placeringen.
        // Fönsterdelning: scenen nederst, under menyraden. Skärmdelning: hela skärmen, ovanpå menyraden.
        let size = state.virtualResolution.size
        let frame = state.shareTarget == .window
            ? CGRect(x: screen.frame.minX, y: screen.frame.minY, width: size.width, height: size.height)
            : screen.frame
        if stageWindow.frame != frame {
            stageWindow.setFrame(frame, display: true)
        }
        stageWindow.orderFrontRegardless()
    }

    /// Den virtuella skärmens menyrad ligger över fönster på vanlig nivå, och mötesappar som fångar ett fönster
    /// som ett utsnitt av skärmen får då med den. Vid fönsterdelning görs skärmen därför högre än scenen, så att
    /// menyraden hamnar i en remsa ovanför fönstret i stället för ovanpå det.
    static let menuBarAllowance: CGFloat = 44

    private var virtualDisplaySize: CGSize {
        let size = state.virtualResolution.size
        return state.shareTarget == .window ? CGSize(width: size.width, height: size.height + Self.menuBarAllowance) : size
    }

    /// Hämtar tillbaka fönster som hamnat på scenskärmen, där de annars varken går att se eller nå.
    private func shepherdWindows() {
        let realScreens = NSScreen.screens.filter { $0.displayID != virtualDisplay.displayID }
        guard state.stageMode == .virtualDisplay, state.moveStrayWindows, let id = virtualDisplay.displayID,
              let stageScreen = NSScreen.screen(for: id), let primary = NSScreen.screens.first, !realScreens.isEmpty else {
            if state.strayWindowCount != 0 { state.strayWindowCount = 0 }
            return
        }
        let mouse = NSEvent.mouseLocation
        let home = (realScreens.first { $0.frame.contains(mouse) } ?? realScreens.first!).visibleFrame
        // Ett pågående drag ska inte avbrytas, även om fönstret för stunden råkar ligga på scenskärmen.
        let move = NSEvent.pressedMouseButtons == 0

        // Appens egna fönster kan återställas dit via sparad position. De flyttas utan Hjälpmedel.
        if move {
            for w in NSApp.windows where w !== stageWindow && w.isVisible && w.styleMask.contains(.titled) {
                guard stageScreen.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) else { continue }
                let size = CGSize(width: min(w.frame.width, home.width), height: min(w.frame.height, home.height))
                w.setFrame(CGRect(x: home.midX - size.width / 2, y: home.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
        }

        // visibleFrame har origo nere till vänster, men Accessibility och CGWindow uppe till vänster.
        let target = CGRect(x: home.minX, y: primary.frame.height - home.maxY, width: home.width, height: home.height)
        shepherd.check(stage: CGDisplayBounds(id), target: target, move: move) { [weak self] report in
            guard let self else { return }
            if self.state.accessibilityGranted != report.trusted { self.state.accessibilityGranted = report.trusted }
            if self.state.strayWindowCount != report.strays { self.state.strayWindowCount = report.strays }
            if report.strays > 0 && !report.trusted && !self.strayWindowHintShown {
                self.strayWindowHintShown = true
                self.hud.show(L("A window landed on the stage display. Allow Accessibility in the control panel to get windows back automatically.",
                                "Ett fönster hamnade på scenskärmen. Tillåt Hjälpmedel i kontrollpanelen så hämtas fönster tillbaka automatiskt."))
            }
        }
    }

    func requestAccessibilityPermission() {
        PermissionWizard.shared.run([.accessibility]) {}
    }

    private func screensChanged() {
        guard state.stageMode == .virtualDisplay else { return }
        virtualDisplay.arrange()
        placeStageOnVirtualDisplay()
        updatePreview()
    }

    /// Snabbpanelen fälldes ut/in eller ändrade storlek.
    func dockLayoutChanged() {
        updatePreview()
    }

    private func updatePreview() {
        guard let dock else { return }
        guard state.showPreview else {
            dock.setPreviewAttached(nil)
            preview.hide()
            return
        }
        let aspect = state.stageMode == .virtualDisplay ? state.virtualResolution.size : stageWindow.contentLayoutRect.size
        // På den virtuella skärmen fångas skärmen i stället för scenfönstret: samma bild som mötesappen får,
        // och två strömmar mot samma fönster gör båda långsammare.
        let source: Source
        if state.stageMode == .virtualDisplay, let id = virtualDisplay.displayID {
            source = .stageDisplay(id, window: CGWindowID(stageWindow.windowNumber))
        } else {
            source = .ownWindow(CGWindowID(stageWindow.windowNumber))
        }
        if state.previewDocked && state.dockPosition != .off {
            // Dockad vid sidan om panelen: syns bara när den är utfälld, som en snabb kontroll av vad som delas.
            if let anchor = dock.dockedPreviewAnchor, state.dockPosition.atNotch {
                let side = preview.showDocked(source: source, aspect: aspect, beside: anchor, topInset: dock.topInset,
                                              compact: state.previewCompact, dockWindowNumber: dock.windowNumber)
                dock.setPreviewAttached(side)
            } else if let anchor = dock.dockedPreviewAnchor {
                // Vid kanten sitter panelen på höjden; förhandsvisningen hamnar inåt skärmen bredvid den eller under den.
                dock.setPreviewAttached(nil)
                preview.showDockedAtEdge(source: source, aspect: aspect, beside: anchor, panelOnRight: state.dockPosition == .right,
                                         below: state.previewBelowAtEdge, offset: state.previewEdgeOffset, compact: state.previewCompact,
                                         dockWindowNumber: dock.windowNumber)
            } else {
                dock.setPreviewAttached(nil)
                preview.hide()
            }
        } else {
            dock.setPreviewAttached(nil)
            preview.show(source: source, aspect: aspect, canDock: state.dockPosition != .off)
        }
    }

    /// Mushändelser från förhandsvisningen, med normaliserad scenpunkt (origo nere till vänster).
    enum PointerPhase { case down, dragged, up }

    func stagePointer(_ phase: PointerPhase, at n: CGPoint) {
        let p = CGPoint(x: n.x * stageView.bounds.width, y: n.y * stageView.bounds.height)
        switch phase {
        case .down: stageView.pointerDown(at: p)
        case .dragged: stageView.pointerDragged(to: p)
        case .up: stageView.pointerUp(at: p)
        }
    }

    func stageScroll(at n: CGPoint, delta: Double) {
        stageView.scroll(at: CGPoint(x: n.x * stageView.bounds.width, y: n.y * stageView.bounds.height), delta: delta)
    }

    private func bindState() {
        state.$camera.removeDuplicates().sink { [weak self] cam in self?.cameraChanged(cam) }.store(in: &cancellables)
        // AppKit-texter som inte ritas om av sig själva. Publiceras före ändringen, så vänta tills språket är satt.
        state.$language.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.languageChanged()
        }.store(in: &cancellables)
        state.$effects.removeDuplicates().sink { [weak self] e in self?.effectsChanged(e) }.store(in: &cancellables)
        Publishers.Merge(state.$presenterDim.map { _ in () }, state.$activeSource.map { _ in () }).dropFirst(2).sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updatePresenterDim() } }
        }.store(in: &cancellables)
        state.$stageMode.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyStageMode() } }
        }.store(in: &cancellables)
        state.$shareTarget.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyStageMode() } }
        }.store(in: &cancellables)
        state.$virtualResolution.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyStageMode() } }
        }.store(in: &cancellables)
        Publishers.Merge6(state.$showPreview.dropFirst().removeDuplicates().map { _ in () },
                          state.$previewDocked.dropFirst().removeDuplicates().map { _ in () },
                          state.$previewCompact.dropFirst().removeDuplicates().map { _ in () },
                          state.$previewBelowAtEdge.dropFirst().removeDuplicates().map { _ in () },
                          state.$previewEdgeOffset.dropFirst().removeDuplicates().map { _ in () },
                          state.$dockPosition.dropFirst().removeDuplicates().map { _ in () })
            .sink { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updatePreview() } }
            }.store(in: &cancellables)
        // Ändrade meddelanden syns direkt om inget delas.
        Publishers.Merge(state.$stoppedMessage.dropFirst().map { _ in () }, state.$lostMessage.dropFirst().map { _ in () })
            .sink { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let reason = self.idleReason, self.state.activeSource == nil else { return }
                        self.showIdle(reason)
                    }
                }
            }.store(in: &cancellables)
        state.$stageBackground.sink { [weak self] hex in self?.stageView.setBackground(hex) }.store(in: &cancellables)
        state.$fps.dropFirst().sink { [weak self] fps in
            guard let self else { return }
            Task { await self.capture.setFPS(fps) }
        }.store(in: &cancellables)
        state.$countdown.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.renderCountdown() } }
        }.store(in: &cancellables)
        state.$activeSource.map { $0 != nil }.removeDuplicates().sink { [weak self] sharing in
            self?.statusItem?.button?.image = MenuBarIcon.image(sharing: sharing)
            self?.panelWindow?.sharingType = sharing ? .none : .readOnly
        }.store(in: &cancellables)
        Publishers.Merge(state.$textShown.map { _ in () }, state.$textMessage.map { _ in () }).sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.renderTextCard() } }
        }.store(in: &cancellables)
        Publishers.Merge3(state.$effects.map { _ in () }, state.$countdownStatus.map { _ in () }, state.$textShown.map { _ in () }).sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateBareClearShortcut() } }
        }.store(in: &cancellables)
        // @Published skickar innan värdet satts, därför körs omregistreringen på nästa varv.
        state.$shortcuts.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.registerHotkeys() } }
        }.store(in: &cancellables)
    }

    // MARK: - Källor och platser

    func refreshSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            state.screenPermissionMissing = false
            let ourBundle = Bundle.main.bundleIdentifier
            state.availableWindows = content.windows
                .filter {
                    $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60
                        && !($0.title ?? "").isEmpty
                        && $0.owningApplication != nil
                        && $0.owningApplication?.processID != getpid()
                        && $0.owningApplication?.bundleIdentifier != ourBundle
                }
                .map(Source.init(window:))
                .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
            // Den virtuella scenskärmen är inget att visa i scenen.
            state.availableDisplays = content.displays
                .filter { $0.displayID != virtualDisplay.displayID }
                .enumerated().map { Source(display: $1, index: $0) }
            restorePersistedSlotsIfNeeded()
        } catch {
            state.screenPermissionMissing = true
        }
    }

    private func restorePersistedSlotsIfNeeded() {
        guard let saved = state.pendingPersistedSlots else { return }
        var slots: [Source?] = Array(repeating: nil, count: AppState.slotCount)
        for (i, p) in saved.prefix(AppState.slotCount).enumerated() {
            guard let p else { continue }
            switch p.kind {
            case .window:
                slots[i] = state.availableWindows.first { $0.bundleID == p.bundleID && $0.title == p.title }
                    ?? state.availableWindows.first { $0.bundleID == p.bundleID && !slots.contains($0) }
            case .display:
                slots[i] = state.availableDisplays.first { $0.displayID == p.displayID }
            }
        }
        state.pendingPersistedSlots = nil
        state.slots = slots
    }

    /// Det främsta vanliga fönstret i den app som senast var aktiv (inte vår egen).
    private func frontmostSource() async -> Source? {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == getpid() ? lastExternalApp : front
        guard let pid = app?.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let match = info.first { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { return false }
            return r.width > 80 && r.height > 60
        }
        guard let wid = match?[kCGWindowNumber as String] as? CGWindowID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let w = content.windows.first(where: { $0.windowID == wid }) else { return nil }
        return Source(window: w)
    }

    /// Delar det aktiva fönstret. Med `toggle` slutar ett tryck på fönstret som redan delas att dela, så att
    /// genvägen slår av och på; står du i ett annat fönster flyttas delningen dit.
    func shareFrontmost(toggle: Bool = false) {
        Task {
            guard let s = await frontmostSource() else { hud.show(L("No active window found", "Hittade inget aktivt fönster")); NSSound.beep(); return }
            // Jämför fönstret, inte titeln, som kan ha ändrats sedan delningen började (t.ex. en ny flik).
            if toggle, let active = state.activeSource, active.id == s.id {
                stopSharing()
                return
            }
            show(s, slot: state.slots.firstIndex(of: s))
        }
    }

    func assignFrontmost(toSlot i: Int) {
        Task {
            guard let s = await frontmostSource() else { hud.show(L("No active window found", "Hittade inget aktivt fönster")); NSSound.beep(); return }
            assign(s, toSlot: i)
            hud.show(L("Slot \(i + 1): \(s.displayName)", "Plats \(i + 1): \(s.displayName)"))
        }
    }

    func assign(_ source: Source, toSlot i: Int) {
        var slots = state.slots
        if let old = slots.firstIndex(of: source) { slots[old] = nil }
        slots[i] = source
        state.slots = slots
        if state.activeSource == source { state.activeSlot = i }
    }

    func addSlot(_ source: Source) {
        guard !state.slots.contains(source) else { return }
        guard let free = state.slots.firstIndex(where: { $0 == nil }) else {
            state.statusMessage = L("All nine slots are taken.", "Alla nio platser är upptagna.")
            return
        }
        assign(source, toSlot: free)
    }

    func removeSlot(_ i: Int) {
        guard state.slots[i] != nil else { return }
        state.slots[i] = nil
        hud.show(L("Slot \(i + 1) removed", "Plats \(i + 1) borttagen"))
        if state.activeSlot == i { state.activeSlot = nil }
    }

    func moveSlot(_ i: Int, by delta: Int) {
        let j = i + delta
        guard state.slots.indices.contains(j) else { return }
        state.slots.swapAt(i, j)
        if state.activeSlot == i { state.activeSlot = j } else if state.activeSlot == j { state.activeSlot = i }
    }

    func activateSlot(_ i: Int) {
        guard let s = state.slots[i] else { hud.show(L("Slot \(i + 1) is empty", "Plats \(i + 1) är tom")); NSSound.beep(); return }
        show(s, slot: i)
    }

    func cycleSlot(_ delta: Int) {
        let filled = state.slots.indices.filter { state.slots[$0] != nil }
        guard !filled.isEmpty else { hud.show(L("No slots are assigned", "Inga platser är tilldelade")); return }
        let current = state.activeSlot.flatMap { filled.firstIndex(of: $0) }
        let next = current.map { ($0 + delta + filled.count) % filled.count } ?? (delta > 0 ? 0 : filled.count - 1)
        activateSlot(filled[next])
    }

    func show(_ source: Source, slot: Int?) {
        let switching = state.activeSource != source
        state.activeSource = source
        state.activeSlot = slot
        state.frozen = false
        idleReason = nil
        stopIdleCamera()
        // Att dela något flyttar fokus från nedräkningen: en nedräkning över hela scenen (eller ett slutmeddelande)
        // tas bort så att det delade syns. En liten nedräkning i hörnet fortsätter.
        if state.countdownStatus == .finished || (state.countdownStatus != .idle && state.countdown.placement == .full) {
            cancelCountdown()
        }
        state.textShown = false
        if switching {
            // En markering gäller bara det fönster den ritades på.
            if state.effects.mode == .rect || state.effects.rect != nil {
                state.effects.rect = nil
                if state.effects.mode == .rect { state.effects.mode = .off }
            }
            stageView.prepareForSwitch()
        }
        sourceBounds = bounds(for: source)
        hud.show("\(slot.map { "\($0 + 1) · " } ?? "")\(source.displayName)")
        requestCapture(source)
    }

    /// Serialiserar växlingar så att snabba tryck i följd alltid landar på det senaste valet.
    private func requestCapture(_ source: Source) {
        pendingSource = source
        guard !captureBusy else { return }
        captureBusy = true
        Task {
            while let next = pendingSource {
                pendingSource = nil
                do {
                    try await capture.start(next, fps: state.fps)
                } catch where pendingSource == nil {
                    captureFailed(error)
                } catch {}
            }
            // Stoppades delningen medan en växling pågick ska strömmen inte fortsätta.
            if state.activeSource == nil { await capture.stop() }
            captureBusy = false
        }
    }

    private func captureFailed(_ error: Error) {
        state.activeSource = nil
        state.activeSlot = nil
        showIdle(.lost)
        hud.show(error.localizedDescription)
        Task { await refreshSources() }
    }

    private func captureStopped(_ error: Error?) {
        guard state.activeSource != nil else { return }
        state.activeSource = nil
        state.activeSlot = nil
        showIdle(.lost)
        if let error { hud.show(L("Sharing was interrupted: \(error.localizedDescription)", "Delningen avbröts: \(error.localizedDescription)")) }
    }

    func stopSharing() {
        stopSharing(reason: .stopped)
    }

    private func stopSharing(reason: IdleReason) {
        let wasSharing = state.activeSource != nil
        state.activeSource = nil
        state.activeSlot = nil
        pendingSource = nil
        // Pågår en växling stoppar den strömmen själv när den är klar.
        if !captureBusy { Task { await capture.stop() } }
        showIdle(reason)
        // "Sluta dela" tömmer scenen helt, även en nedräkning. Försvinner bara källan står nedräkningen kvar.
        let hadCountdown = state.countdownStatus != .idle
        let hadText = state.textShown
        if reason == .stopped && hadCountdown { cancelCountdown() }
        if reason == .stopped { state.textShown = false }
        if reason == .stopped && (wasSharing || hadCountdown || hadText) { hud.show(L("Sharing stopped", "Delningen stoppad")) }
    }

    /// Visar det inställda meddelandet för när ingen källa delas.
    private func showIdle(_ reason: IdleReason) {
        idleReason = reason
        let message = state.idleMessage(for: reason)
        if message.content == .camera, !state.camera.enabled, !idleCameraRunning {
            idleCameraRunning = true
            camera.start(deviceID: state.camera.deviceID) { _ in }
        } else if message.content != .camera {
            stopIdleCamera()
        }
        stageView.showIdle(message)
    }

    private func stopIdleCamera() {
        guard idleCameraRunning else { return }
        idleCameraRunning = false
        if !state.camera.enabled { camera.stop() }
    }

    func chooseIdleImage(for reason: IdleReason) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = L("Choose an image, logo or animated GIF to show when nothing is shared", "Välj en bild, logga eller animerad GIF att visa när inget delas")
        guard panel.runModal() == .OK, let url = panel.url, let original = try? Data(contentsOf: url) else { return }
        // Animerade bilder (GIF m.fl.) behålls animerade; övriga skalas ned och sparas som PNG.
        let data: Data?
        if AnimatedImage.isAnimated(original) {
            data = AnimatedImage.encodedForSettings(original)
        } else {
            data = NSImage(data: original).flatMap(Self.encodedForSettings)
        }
        guard let data else {
            state.statusMessage = L("Couldn't read the image.", "Kunde inte läsa bilden.")
            return
        }
        var message = state.idleMessage(for: reason)
        message.imageData = data
        message.content = .image
        state.setIdleMessage(message, for: reason)
    }

    /// Skalar ner till högst 1920 px och kodar som PNG, så att inställningarna hålls små.
    private static func encodedForSettings(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1920 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }

    // MARK: - Export och import av inställningar

    func exportSettings() {
        guard let id = Bundle.main.bundleIdentifier,
              let stored = UserDefaults.standard.persistentDomain(forName: id) else { return }
        let domain = stored.filter { !$0.key.hasPrefix(PermissionStep.askedKeyPrefix) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("BetterScreenSharing-settings.plist", "BetterScreenSharing-inställningar.plist")
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
            try data.write(to: url)
            hud.show(L("Settings exported", "Inställningarna exporterades"))
        } catch {
            state.statusMessage = L("Couldn't export: \(error.localizedDescription)", "Kunde inte exportera: \(error.localizedDescription)")
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle.main.bundleIdentifier else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let domain = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                state.statusMessage = L("The file doesn't contain any settings.", "Filen innehåller inga inställningar.")
                return
            }
            UserDefaults.standard.setPersistentDomain(domain, forName: id)
            relaunch()
        } catch {
            state.statusMessage = L("Couldn't import: \(error.localizedDescription)", "Kunde inte importera: \(error.localizedDescription)")
        }
    }

    /// Startar om appen så att importerade inställningar läses in från början.
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        UserDefaults.standard.synchronize()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func shareScreenUnderMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) && $0.displayID != virtualDisplay.displayID }
            ?? NSScreen.main
        guard let id = screen?.displayID else { return }
        Task {
            if state.availableDisplays.first(where: { $0.displayID == id }) == nil { await refreshSources() }
            guard let source = state.availableDisplays.first(where: { $0.displayID == id }) else {
                hud.show(L("No display found to share", "Hittade ingen skärm att dela"))
                return
            }
            show(source, slot: state.slots.firstIndex(of: source))
        }
    }

    private func bounds(for source: Source) -> CGRect? {
        switch source.kind {
        case .display:
            return CGDisplayBounds(source.displayID)
        case .window:
            guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], source.windowID) as? [[String: Any]],
                  let b = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: b)
        }
    }

    private func pollSourceBounds() {
        guard let source = state.activeSource else { sourceBounds = nil; return }
        guard let b = bounds(for: source) else {
            stopSharing(reason: .lost)
            hud.show(L("The shared window was closed", "Det delade fönstret stängdes"))
            return
        }
        sourceBounds = b
        if !captureBusy {
            Task { await capture.resize(to: b.size) }
        }
    }

    // MARK: - Kamera

    private func cameraChanged(_ cam: CameraSettings) {
        let animated = !stageView.isInteracting
        stageView.apply(camera: cam, animated: animated)
        if cam.enabled && (!lastCamera.enabled || cam.deviceID != lastCamera.deviceID) {
            camera.start(deviceID: cam.deviceID) { [weak self] error in
                guard let self, let error else { return }
                self.state.camera.enabled = false
                self.state.statusMessage = error
                self.hud.show(error)
            }
        } else if !cam.enabled && lastCamera.enabled && !idleCameraRunning {
            camera.stop()
        }
        lastCamera = cam
    }

    /// Scenens höjd i punkter, så att förhandsvisningar kan skala ram och skugga rätt.
    var stageHeight: CGFloat { stageView?.bounds.height ?? 1080 }

    func makeCameraPreviewLayer() -> AVCaptureVideoPreviewLayer {
        camera.makePreviewLayer()
    }

    func refreshCameraDevices() {
        state.cameraDevices = CameraController.devices().map { ($0.uniqueID, $0.localizedName) }
    }

    func toggleCamera() {
        state.camera.enabled.toggle()
        if !state.camera.enabled { state.camera.fullscreen = false }
        hud.show(state.camera.enabled ? L("Camera on", "Kamera på") : L("Camera off", "Kamera av"))
    }

    func toggleCameraFullscreen() {
        if !state.camera.enabled {
            state.camera.enabled = true
            state.camera.fullscreen = true
        } else {
            state.camera.fullscreen.toggle()
        }
        hud.show(state.camera.fullscreen ? L("Just me", "Bara jag") : L("Back to sharing", "Tillbaka till delningen"))
    }

    static let corners: [(CGFloat, CGFloat, Phrase)] = [
        (1, 1, Phrase(en: "bottom right", sv: "nere till höger")), (0, 1, Phrase(en: "bottom left", sv: "nere till vänster")),
        (0, 0, Phrase(en: "top left", sv: "uppe till vänster")), (1, 0, Phrase(en: "top right", sv: "uppe till höger")),
    ]

    /// Flyttar bubblan till ett hörn; i "Bara jag" flyttas den stora bubblan.
    func setCameraCorner(_ i: Int) {
        let c = Self.corners[i]
        setCameraCenter(x: c.0, y: c.1)
    }

    func setCameraCenter(x: Double, y: Double) {
        if state.camera.enabled && state.camera.fullscreen {
            state.camera.fullCenterX = x
            state.camera.fullCenterY = y
        } else {
            state.camera.centerX = x
            state.camera.centerY = y
        }
    }

    func cycleCameraCorner() {
        if !state.camera.enabled { state.camera.enabled = true }
        let cx = state.camera.centerX, cy = state.camera.centerY
        let nearest = Self.corners.indices.min { a, b in
            hypot(Self.corners[a].0 - cx, Self.corners[a].1 - cy) < hypot(Self.corners[b].0 - cx, Self.corners[b].1 - cy)
        } ?? 0
        let next = (nearest + 1) % Self.corners.count
        setCameraCorner(next)
        hud.show(L("Camera \(Self.corners[next].2.text)", "Kamera \(Self.corners[next].2.text)"))
    }

    func cycleCameraShape() {
        let all = CameraShape.allCases
        let next = all[((all.firstIndex(of: state.camera.shape) ?? 0) + 1) % all.count]
        state.camera.shape = next
        hud.show(L("Shape: \(next.label)", "Form: \(next.label)"))
    }

    // MARK: - Effekter

    private func effectsChanged(_ e: EffectSettings) {
        stageView.apply(effects: e)
        if e.mode == .spotlight {
            if spotlightTimer == nil {
                spotlightTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trackSpotlight() }
                }
            }
        } else {
            spotlightTimer?.invalidate()
            spotlightTimer = nil
            lastSpotInput = nil
            stageView.setSpotlight(center: nil)
            spotCenter = nil
        }
        // Värdet i state är fortfarande det gamla här (sink körs innan det sparas).
        updatePresenterDim(effects: e)
    }

    /// Dimningen på presentatörens skärm. Medan den syns följs källans läge ofta, så att den sitter kvar
    /// över fönstret när det flyttas.
    private func updatePresenterDim(effects: EffectSettings? = nil) {
        let effects = effects ?? state.effects
        // Under guiden visas dimningen även om den annars är avslagen, eftersom det är den som provas.
        let active = effects.mode != .off && (state.activeSource == nil ? spotlightDemo : state.presenterDim)
        guard active else {
            presenterDim.hide()
            presenterTimer?.invalidate()
            presenterTimer = nil
            return
        }
        presenterDim.update(bounds: effectBounds, effects: effects, spotCenter: spotCenter)
        guard let source = state.activeSource else { return }
        if presenterTimer == nil, source.kind == .window {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let source = self.state.activeSource, let b = self.bounds(for: source) else { return }
                    if b != self.sourceBounds { self.sourceBounds = b }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            presenterTimer = timer
        } else if presenterTimer != nil, source.kind != .window {
            presenterTimer?.invalidate()
            presenterTimer = nil
        }
    }

    /// Medan guiden för kortkommandon är öppen och inget delas visas spotlighten (och dimningen) som om hela
    /// skärmen under pekaren delades, så att Caps Lock går att prova.
    private var spotlightDemo = false

    func setSpotlightDemo(_ on: Bool) {
        spotlightDemo = on
        lastSpotInput = nil
        updatePresenterDim()
    }

    /// Ytan som dimningen och spotlighten gäller: det som delas, eller skärmen under pekaren under guiden.
    private var effectBounds: CGRect? {
        if state.activeSource != nil { return sourceBounds }
        guard spotlightDemo else { return nil }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        return CGDisplayBounds(id)
    }

    /// Spotlight följer musen – både över källfönstret och över själva scenen.
    private func trackSpotlight() {
        let mouse = NSEvent.mouseLocation
        let effectBounds = self.effectBounds
        // Varje varv frågar fönsterservern vilket fönster som ligger under pekaren; hoppa över när inget rört sig.
        if let last = lastSpotInput, last.mouse == mouse, last.bounds == effectBounds { return }
        lastSpotInput = (mouse, effectBounds)
        var point: CGPoint?
        if let n = preview.stagePointUnderMouse() {
            point = stageView.contentPoint(forStagePoint: CGPoint(x: n.x * stageView.bounds.width, y: n.y * stageView.bounds.height))
        } else if let r = stageView.contentRectOnScreen(), r.contains(mouse),
           NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0) == stageWindow.windowNumber {
            point = CGPoint(x: (mouse.x - r.minX) / r.width, y: (r.maxY - mouse.y) / r.height)
        } else if let b = effectBounds, b.width > 0, b.height > 0 {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let p = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
            if b.contains(p) {
                point = CGPoint(x: (p.x - b.minX) / b.width, y: (p.y - b.minY) / b.height)
            }
        }
        stageView.setSpotlight(center: point)
        if point != spotCenter {
            spotCenter = point
            updatePresenterDim()
        }
    }

    func setHighlight(_ normalizedRect: CGRect) {
        state.effects.rect = normalizedRect
        state.effects.mode = .rect
    }

    func toggleSpotlight() {
        state.effects.mode = state.effects.mode == .spotlight ? .off : .spotlight
        hud.show(state.effects.mode == .spotlight ? L("Spotlight on", "Spotlight på") : L("Spotlight off", "Spotlight av"))
    }

    /// Rensar scenen: markering, spotlight och en nedräkning som visas.
    func clearEffects() {
        state.effects.mode = .off
        state.effects.rect = nil
        if state.countdownStatus != .idle {
            cancelCountdown()
            hud.show(L("Countdown removed", "Nedräkningen borttagen"))
        }
        state.textShown = false
    }

    // MARK: - Textläge

    /// Visar eller döljer texten över scenen. Utan text fälls snabbpanelen ut så att du kan skriva den.
    func toggleText() {
        if state.textShown {
            state.textShown = false
            hud.show(L("Text hidden", "Texten dold"))
            return
        }
        state.textMode = true
        guard !state.textMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dock.focusTextField()
            hud.show(L("Type the text in the quick panel", "Skriv texten i snabbpanelen"))
            return
        }
        state.textShown = true
    }

    /// Pratbubblan i snabbpanelen: visar eller döljer textfältet. Stängs läget tas även texten bort från scenen.
    func toggleTextMode() {
        if state.textMode || state.textShown {
            state.textMode = false
            state.textShown = false
        } else {
            state.textMode = true
            dock.focusTextField()
        }
    }

    private func renderTextCard() {
        let text = state.textMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        stageView.setTextCard(state.textShown && !text.isEmpty ? text : nil)
    }

    func beginRegionSelect() {
        guard let source = state.activeSource, let b = bounds(for: source), b.width > 0, b.height > 0 else {
            hud.show(L("Choose a source first", "Välj en källa först"))
            NSSound.beep()
            return
        }
        guard !RegionSelector.isActive else { return }
        regionSelecting = true
        registerHotkeys()
        RegionSelector.begin(excludingDisplay: virtualDisplay.displayID) { [weak self] rect in
            guard let self else { return }
            self.regionSelecting = false
            self.registerHotkeys()
            if let rect { self.applyDrawnRegion(rect) }
        }
    }

    /// En rektangel i globala CG-koordinater blir markering, räknat i den delade källan.
    private func applyDrawnRegion(_ rect: CGRect) {
        guard let source = state.activeSource, let b = bounds(for: source), b.width > 0, b.height > 0 else {
            hud.show(L("Choose a source first", "Välj en källa först"))
            NSSound.beep()
            return
        }
        let n = CGRect(x: (rect.minX - b.minX) / b.width, y: (rect.minY - b.minY) / b.height,
                       width: rect.width / b.width, height: rect.height / b.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !n.isNull, n.width > 0.005, n.height > 0.005 else {
            hud.show(L("The highlight ended up outside the shared window", "Markeringen hamnade utanför det delade fönstret"))
            return
        }
        setHighlight(n)
    }

    func toggleFreeze() {
        state.frozen.toggle()
        hud.show(state.frozen ? L("Picture frozen", "Bilden är fryst") : L("Live again", "Live igen"))
    }

    // MARK: - Nedräkning

    /// Startar, pausar och återupptar. En avslutad nedräkning tas bort.
    func toggleCountdown() {
        switch state.countdownStatus {
        case .idle: startCountdown()
        case .running: pauseCountdown()
        case .paused: resumeCountdown()
        case .finished: cancelCountdown()
        }
    }

    func startCountdown() {
        countdownTotal = state.countdown.seconds()
        countdownWarned = countdownTotal <= 60
        state.countdownRemaining = countdownTotal
        resumeCountdown()
        hud.show(state.countdown.mode == .untilTime
                 ? L("Countdown to \(state.countdown.targetTimeText)", "Nedräkning till \(state.countdown.targetTimeText)")
                 : L("Countdown \(CountdownSettings.formatTime(countdownTotal))", "Nedräkning \(CountdownSettings.formatTime(countdownTotal))"))
    }

    static let countdownPresets: [Double] = [1, 5, 10, 15, 20, 30, 45, 60]

    func setCountdownLength(minutes: Double) {
        state.countdown.mode = .duration
        state.countdown.minutes = minutes
        hud.show(L("Countdown: \(Int(minutes)) min", "Nedräkning: \(Int(minutes)) min"))
    }

    func pauseCountdown() {
        guard state.countdownStatus == .running else { return }
        countdownTick()
        // Exakt kvarvarande tid, så att en fortsättning inte tappar eller lägger till en bråkdel av en sekund.
        if let end = countdownEnd { state.countdownRemaining = max(0, end.timeIntervalSinceNow) }
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownEnd = nil
        state.countdownStatus = .paused
        hud.show(L("Countdown paused", "Nedräkningen pausad"))
    }

    func resumeCountdown() {
        countdownEnd = Date().addingTimeInterval(state.countdownRemaining)
        state.countdownStatus = .running
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownTick() }
        }
        renderCountdown()
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownEnd = nil
        state.countdownStatus = .idle
        state.countdownRemaining = 0
        renderCountdown()
    }

    private func countdownTick() {
        guard let end = countdownEnd else { return }
        let remaining = max(0, end.timeIntervalSinceNow)
        // Panelerna visar hela sekunder; att publicera varje tick skulle rita om dem fem gånger i sekunden.
        // Scenens förloppsring följer det exakta värdet.
        if remaining.rounded(.up) != state.countdownRemaining.rounded(.up) { state.countdownRemaining = remaining }
        if state.countdown.chime, !countdownWarned, remaining <= 60 {
            countdownWarned = true
            Chime.play()
        }
        if remaining <= 0 {
            finishCountdown()
        } else {
            renderCountdown()
        }
    }

    private func finishCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownEnd = nil
        state.countdownRemaining = 0
        if state.countdown.endAction == .resume {
            cancelCountdown()
            hud.show(L("Countdown finished", "Nedräkningen är klar"))
        } else {
            state.countdownStatus = .finished
            renderCountdown()
        }
    }

    private func renderCountdown() {
        let c = state.countdown
        let display: CountdownDisplay?
        switch state.countdownStatus {
        case .idle:
            display = nil
        case .running, .paused:
            let remaining = countdownEnd.map { max(0, $0.timeIntervalSinceNow) } ?? state.countdownRemaining
            display = c.display(remaining: remaining, progress: countdownTotal > 0 ? remaining / countdownTotal : 0)
        case .finished:
            display = c.display(remaining: nil, progress: 0)
        }
        stageView.setCountdown(display)
    }

    // MARK: - Caps Lock

    /// Caps Lock läses genom att fråga efter tangentbordets läge tio gånger i sekunden. Det kräver ingen
    /// behörighet, till skillnad från att lyssna på tangenttryck i andra appar.
    private func startCapsLockWatch() {
        capsWasOn = NSEvent.modifierFlags.contains(.capsLock)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCapsLock() }
        }
        timer.tolerance = 0.03
        // Även medan musen hålls nere eller en meny är öppen, så att ritläget alltid följer Caps Lock.
        RunLoop.main.add(timer, forMode: .common)
        capsTimer = timer
    }

    private func pollCapsLock() {
        let on = NSEvent.modifierFlags.contains(.capsLock)
        if on != capsWasOn {
            capsWasOn = on
            applyCapsLock(on)
        }
        refreshCapsLayer()
    }

    /// Funktionsläget: medan Caps Lock är på räcker enskilda tangenter, och klick och dra ritar en markering.
    /// Tangenterna släpps medan du skriver i appens egna textfält, så att de går att skriva i.
    private func refreshCapsLayer() {
        let layer = state.capsLockAction == .functionLayer && capsWasOn
        let keys = layer && !hotkeysSuspended && !(NSApp.keyWindow?.firstResponder is NSTextView)
        if keys != capsLayerActive {
            capsLayerActive = keys
            registerHotkeys()
        }
        let draw = layer && state.capsDraw
        if draw && capsDrawLayer == nil {
            capsDrawLayer = DrawLayer(excludingDisplay: virtualDisplay.displayID) { [weak self] rect in
                guard let self, self.capsWasOn else { return }
                self.applyDrawnRegion(rect)
                self.capsDrawnHighlight = self.state.effects.mode == .rect ? self.state.effects.rect : nil
            }
        } else if !draw, let layer = capsDrawLayer {
            layer.close()
            capsDrawLayer = nil
            // Det som ritades med Caps Lock hör till läget och försvinner med det, om det inte ändrats sedan.
            if let drawn = capsDrawnHighlight, state.effects.mode == .rect, state.effects.rect == drawn {
                state.effects.mode = .off
                state.effects.rect = nil
            }
            capsDrawnHighlight = nil
        }
        presenterDim.clickToDismiss = capsDrawLayer == nil
    }

    /// Tangenterna i funktionsläget: samma tangent som i en ändrad genväg, utan ⌃, ⌥ och ⌘, annars standardtangenten.
    /// Visa plats går först, så att siffrorna växlar scen, och sedan övriga funktioner. En tangent som redan är tagen hoppas över.
    func capsLayerBindings() -> [(key: UInt32, action: HotkeyAction)] {
        let order = (0..<AppState.slotCount).map { HotkeyAction.showSlot($0) } + HotkeyAction.general
            + (0..<AppState.slotCount).map { HotkeyAction.assignSlot($0) }
        var taken = Set<UInt32>()
        return order.compactMap { action in
            var key: UInt32?
            if let entry = state.shortcuts[action.id] {
                key = entry?.keyCode
            } else {
                key = action.defaultLayerKey.map { UInt32($0) }
            }
            // Siffrorna visar alltid platserna, även om genvägen är borttagen.
            if key == nil, case .showSlot = action { key = action.defaultLayerKey.map { UInt32($0) } }
            guard let key, taken.insert(key).inserted else { return nil }
            return (key, action)
        }
    }

    /// Följer Caps Lock: på slår på funktionen och av slår av den, så att lampan alltid visar läget.
    private func applyCapsLock(_ on: Bool) {
        if ![.none, .functionLayer].contains(state.capsLockAction) { ShortcutGuide.shared.capsLockChanged(on) }
        switch state.capsLockAction {
        case .none:
            return
        case .functionLayer:
            hud.show(on ? L("Function mode on", "Funktionsläge på") : L("Function mode off", "Funktionsläge av"))
        case .spotlight:
            if on { state.effects.mode = .spotlight } else if state.effects.mode == .spotlight { state.effects.mode = .off }
            hud.show(on ? L("Spotlight on", "Spotlight på") : L("Spotlight off", "Spotlight av"))
        case .camera:
            state.camera.enabled = on
            if !on { state.camera.fullscreen = false }
            hud.show(on ? L("Camera on", "Kamera på") : L("Camera off", "Kamera av"))
        case .onlyMe:
            if on { state.camera.enabled = true }
            state.camera.fullscreen = on
            hud.show(on ? L("Just me", "Bara jag") : L("Back to sharing", "Tillbaka till delningen"))
        case .freeze:
            state.frozen = on
            hud.show(on ? L("Picture frozen", "Bilden är fryst") : L("Live again", "Live igen"))
        }
    }

    // MARK: - Kortkommandon

    func perform(_ action: HotkeyAction) {
        // Medan guiden för kortkommandon visas provas genvägarna där i stället för att utföras.
        if ShortcutGuide.shared.consume(action) { return }
        switch action {
        case .showSlot(let i): activateSlot(i)
        case .assignSlot(let i): assignFrontmost(toSlot: i)
        case .shareFrontmost: shareFrontmost(toggle: true)
        case .shareScreen: shareScreenUnderMouse()
        case .stopSharing: stopSharing()
        case .nextSlot: cycleSlot(1)
        case .previousSlot: cycleSlot(-1)
        case .toggleCamera: toggleCamera()
        case .cameraFullscreen: toggleCameraFullscreen()
        case .cycleCameraCorner: cycleCameraCorner()
        case .cycleCameraShape: cycleCameraShape()
        case .toggleSpotlight: toggleSpotlight()
        case .drawHighlight: beginRegionSelect()
        case .clearEffects: clearEffects()
        case .toggleFreeze: toggleFreeze()
        case .toggleCountdown: toggleCountdown()
        case .toggleText: toggleText()
        }
    }

    func registerHotkeys() {
        let manager = HotkeyManager.shared
        manager.unregisterAll()
        if regionSelecting {
            // Esc är annars "Rensa scenen" när något visas och skulle ta tangenten från ritlagret.
            // Under ritningen fångas Esc därför globalt och avbryter bara ritningen.
            manager.register(Shortcut(keyCode: kVK_Escape, modifiers: 0)) { RegionSelector.cancel() }
            return
        }
        guard !hotkeysSuspended else { return }
        var conflicts: [String] = []
        bareClearRegistered = sceneHasSomethingToClear
        for action in HotkeyAction.all {
            guard let shortcut = state.shortcut(for: action) else { continue }
            // Esc (eller annan tangent utan modifierare) för "Rensa scenen" fångas bara när det finns något att rensa,
            // så att Esc fungerar som vanligt i andra appar resten av tiden.
            if action == .clearEffects && HotkeyAction.isBare(shortcut) && !bareClearRegistered { continue }
            if !manager.register(shortcut, action: { [weak self] in self?.perform(action) }) {
                conflicts.append("\(shortcut.displayString) (\(action.label))")
            }
        }
        state.hotkeyConflicts = conflicts
        if capsLayerActive {
            // Registreras både med och utan Caps Lock-flaggan, eftersom Carbon inte är dokumenterat på den punkten.
            // Den som redan finns (t.ex. Esc för Rensa) misslyckas tyst.
            for (key, action) in capsLayerBindings() {
                for modifiers in [0, alphaLock] {
                    manager.register(Shortcut(keyCode: Int(key), modifiers: modifiers)) { [weak self] in self?.perform(action) }
                }
            }
        }
    }

    private var sceneHasSomethingToClear: Bool {
        state.effects.mode != .off || state.effects.rect != nil || state.countdownStatus != .idle || state.textShown
    }

    /// Registrerar om när "Rensa scenen" med en tangent utan modifierare blir aktuell eller inaktuell.
    private func updateBareClearShortcut() {
        guard let shortcut = state.shortcut(for: .clearEffects), HotkeyAction.isBare(shortcut),
              sceneHasSomethingToClear != bareClearRegistered else { return }
        registerHotkeys()
    }

    /// Medan en genväg spelas in får de globala genvägarna inte fånga tangenttrycken.
    func suspendHotkeys(_ suspended: Bool) {
        hotkeysSuspended = suspended
        registerHotkeys()
    }

    func startRecording(_ action: HotkeyAction) {
        stopRecording()
        state.recordingAction = action
        suspendHotkeys(true)
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleRecordedKey(event) }
            return nil
        }
    }

    func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        guard state.recordingAction != nil else { return }
        state.recordingAction = nil
        suspendHotkeys(false)
    }

    private func handleRecordedKey(_ event: NSEvent) {
        guard let action = state.recordingAction else { return }
        let bare = event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where bare:
            stopRecording()
        case kVK_Delete where bare, kVK_ForwardDelete where bare:
            setShortcut(nil, for: action)
            stopRecording()
        default:
            let shortcut = Shortcut(event: event)
            guard shortcut.isValid else { NSSound.beep(); return }
            setShortcut(shortcut, for: action)
            stopRecording()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panelWindow else { return }
        stopRecording()
        // Stängd kontrollpanel: appen lever vidare i menyraden, utan symbol i Dock.
        NSApp.setActivationPolicy(.accessory)
    }

    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) {
        if let displaced = state.setShortcut(shortcut, for: action), let shortcut {
            state.statusMessage = L("\(shortcut.displayString) was used for \"\(displaced.label)\", which now has no shortcut.", "\(shortcut.displayString) användes för \"\(displaced.label)\", som nu saknar genväg.")
        }
    }

    func showShortcutGuide() {
        ShortcutGuide.shared.show(state: state, controller: self)
    }

    func showTutorial() {
        TutorialVideo.shared.show(state: state)
    }

    func resetShortcuts() {
        state.shortcuts = [:]
    }

    /// Tar bort alla genvägar. Borttagna genvägar har ingen tangent i funktionsläget heller, utom siffrorna för platserna.
    func clearAllShortcuts() {
        state.shortcuts = Dictionary(uniqueKeysWithValues: HotkeyAction.all.map { ($0.id, Shortcut?.none) })
    }

    /// " (⌃⌥K)" för menytexter, eller tomt om funktionen saknar genväg.
    private func hint(_ action: HotkeyAction) -> String {
        state.keys(action).map { " (\($0))" } ?? ""
    }

    // MARK: - Fönster och menyer

    private func languageChanged() {
        stageWindow.title = Self.stageTitle
        preview.updateTexts()
        statusItem.button?.image = MenuBarIcon.image(sharing: state.activeSource != nil)
    }

    func showPanel(section: PanelSection) {
        state.panelSection = section
        showPanel()
    }

    func showPanel() {
        guard started else { PermissionWizard.shared.bringToFront(); return }
        if panelWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "BetterScreenSharing"
            w.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: ControlPanelView(state: state, controller: self))
            // Bara minsta storlek från innehållet; annars låser SwiftUI fönstrets storlek och innehållet följer inte med.
            hosting.sizingOptions = [.minSize]
            w.contentView = hosting
            w.setFrameAutosaveName("ControlPanelSidebar")
            if w.frame.origin == .zero { w.center() }
            // Kontrollpanelen döljs för skärmfångst under delning, men går att ta skärmdumpar av annars.
            w.sharingType = state.activeSource == nil ? .readOnly : .none
            w.delegate = self
            panelWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        panelWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showStage() {
        guard started else { PermissionWizard.shared.bringToFront(); return }
        // På den virtuella skärmen syns scenen bara via förhandsvisningen.
        if state.stageMode == .virtualDisplay {
            state.showPreview = true
            if state.previewDocked && state.dockPosition != .off { dock.expand() }
            updatePreview()
            return
        }
        stageWindow.deminiaturize(nil)
        stageWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func setStageSize(_ size: CGSize) {
        // Storleken anges i pixlar; fönstret mäts i punkter.
        let scale = stageWindow.backingScaleFactor
        stageWindow.setContentSize(CGSize(width: size.width / scale, height: size.height / scale))
        showStage()
    }

    func windowWillMiniaturize(_ notification: Notification) {
        if (notification.object as? NSWindow) === stageWindow {
            hud.show(L("Note: a minimized stage window can't be shared", "Obs! Ett minimerat scenfönster kan inte delas"))
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image(sharing: state.activeSource != nil)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in makeQuickMenu(includeAppItems: true).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private var countdownMenuTitle: String {
        switch state.countdownStatus {
        case .idle: L("Start countdown (\(state.countdown.shortDescription))", "Starta nedräkning (\(state.countdown.shortDescription))")
        case .running: L("Pause the countdown", "Pausa nedräkningen")
        case .paused: L("Resume the countdown", "Fortsätt nedräkningen")
        case .finished: L("Remove the countdown", "Ta bort nedräkningen")
        }
    }

    func makeQuickMenu(includeAppItems: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: L("Sharing: \(state.activeSource?.displayName ?? "nothing")", "Delar: \(state.activeSource?.displayName ?? "ingenting")"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for (i, s) in state.slots.enumerated() {
            guard let s else { continue }
            menu.addItem(ClosureMenuItem("\(i + 1)  \(s.displayName)\(hint(.showSlot(i)))", checked: state.activeSlot == i) { [weak self] in
                self?.activateSlot(i)
            })
        }
        menu.addItem(ClosureMenuItem(L("Share active window", "Dela aktivt fönster") + hint(.shareFrontmost)) { [weak self] in self?.shareFrontmost() })
        menu.addItem(ClosureMenuItem(L("Share entire screen", "Dela hela skärmen") + hint(.shareScreen)) { [weak self] in self?.shareScreenUnderMouse() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Camera", "Kamera") + hint(.toggleCamera), checked: state.camera.enabled) { [weak self] in self?.toggleCamera() })
        menu.addItem(ClosureMenuItem(L("Just me", "Bara jag") + hint(.cameraFullscreen), checked: state.camera.enabled && state.camera.fullscreen) { [weak self] in self?.toggleCameraFullscreen() })
        let shapeItem = NSMenuItem(title: L("Camera shape", "Kameraform"), action: nil, keyEquivalent: "")
        let shapeMenu = NSMenu()
        for shape in CameraShape.allCases {
            shapeMenu.addItem(ClosureMenuItem(shape.label, checked: state.camera.shape == shape) { [weak self] in self?.state.camera.shape = shape })
        }
        shapeItem.submenu = shapeMenu
        menu.addItem(shapeItem)
        let cornerItem = NSMenuItem(title: L("Camera position", "Kameraposition"), action: nil, keyEquivalent: "")
        let cornerMenu = NSMenu()
        for (i, c) in Self.corners.enumerated() {
            cornerMenu.addItem(ClosureMenuItem(c.2.text.prefix(1).uppercased() + c.2.text.dropFirst()) { [weak self] in
                self?.state.camera.enabled = true
                self?.setCameraCorner(i)
            })
        }
        cornerItem.submenu = cornerMenu
        menu.addItem(cornerItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Spotlight" + hint(.toggleSpotlight), checked: state.effects.mode == .spotlight) { [weak self] in self?.toggleSpotlight() })
        menu.addItem(ClosureMenuItem(L("Draw highlight…", "Rita markering…") + hint(.drawHighlight)) { [weak self] in self?.beginRegionSelect() })
        menu.addItem(ClosureMenuItem(L("Remove highlight", "Ta bort markering") + hint(.clearEffects)) { [weak self] in self?.clearEffects() })
        menu.addItem(ClosureMenuItem(L("Freeze picture", "Frys bilden") + hint(.toggleFreeze), checked: state.frozen) { [weak self] in self?.toggleFreeze() })
        menu.addItem(ClosureMenuItem(countdownMenuTitle + hint(.toggleCountdown), checked: state.countdownStatus != .idle) { [weak self] in self?.toggleCountdown() })
        let lengthItem = NSMenuItem(title: L("Countdown length", "Nedräkningens längd"), action: nil, keyEquivalent: "")
        let lengthMenu = NSMenu()
        for m in Self.countdownPresets {
            lengthMenu.addItem(ClosureMenuItem("\(Int(m)) min", checked: state.countdown.mode == .duration && state.countdown.minutes == m) { [weak self] in
                self?.setCountdownLength(minutes: m)
            })
        }
        lengthMenu.addItem(.separator())
        lengthMenu.addItem(ClosureMenuItem(L("Until \(state.countdown.targetTimeText)", "Till klockslag \(state.countdown.targetTimeText)"), checked: state.countdown.mode == .untilTime) { [weak self] in
            self?.state.countdown.mode = .untilTime
        })
        lengthMenu.addItem(ClosureMenuItem(L("More settings…", "Fler inställningar…")) { [weak self] in self?.showPanel(section: .countdown) })
        lengthItem.submenu = lengthMenu
        menu.addItem(lengthItem)
        menu.addItem(ClosureMenuItem(L("Stop sharing", "Sluta dela") + hint(.stopSharing)) { [weak self] in self?.stopSharing() })
        if includeAppItems {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Show control panel", "Visa kontrollpanel")) { [weak self] in self?.showPanel() })
            if state.stageMode == .window {
                menu.addItem(ClosureMenuItem(L("Show stage window", "Visa scenfönster")) { [weak self] in self?.showStage() })
            }
            menu.addItem(ClosureMenuItem(L("Preview", "Förhandsvisning"), checked: state.showPreview) { [weak self] in self?.state.showPreview.toggle() })
            menu.addItem(ClosureMenuItem(L("Quit", "Avsluta")) { NSApp.terminate(nil) })
        }
        return menu
    }
}
