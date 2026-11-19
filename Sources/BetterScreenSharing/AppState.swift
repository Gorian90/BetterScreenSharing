import AppKit
import Combine

/// Allt som kontrollpanelen visar och ändrar. Inställningar sparas i UserDefaults.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    nonisolated static let slotCount = 9

    /// Platser 1–9; tomma platser är nil så att numret (och kortkommandot) står still.
    @Published var slots: [Source?] = Array(repeating: nil, count: AppState.slotCount) {
        didSet { saveSlots() }
    }
    @Published var activeSource: Source?
    @Published var activeSlot: Int?

    /// Appens språk. Sparas som en vanlig sträng så att Lang kan läsa det innan AppState finns.
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            Lang.current = language
            UserDefaults.standard.set(language.rawValue, forKey: Lang.key)
            translateUntouchedDefaults(from: oldValue)
        }
    }
    @Published var camera: CameraSettings { didSet { save(camera, "camera") } }
    @Published var effects: EffectSettings { didSet { save(effects, "effects") } }
    /// Egna genvägar per funktion. Saknas nyckeln gäller standard; ett lagrat nil betyder "ingen genväg".
    @Published var shortcuts: [String: Shortcut?] { didSet { save(shortcuts, "shortcuts") } }
    @Published var fps: Int { didSet { save(fps, "fps") } }
    @Published var stageBackground: String { didSet { save(stageBackground, "stageBackground") } }
    @Published var stageMode: StageMode { didSet { save(stageMode, "stageMode") } }
    @Published var virtualResolution: VirtualResolution { didSet { save(virtualResolution, "virtualResolution") } }
    @Published var showPreview: Bool { didSet { save(showPreview, "showPreview") } }
    @Published var shareTarget: ShareTarget { didSet { save(shareTarget, "shareTarget") } }
    @Published var moveStrayWindows: Bool { didSet { save(moveStrayWindows, "moveStrayWindows") } }
    @Published var skippedPermissions: Set<PermissionStep> { didSet { save(skippedPermissions, "skippedPermissions") } }
    @Published var stoppedMessage: IdleMessage { didSet { save(stoppedMessage, "stoppedMessage") } }
    @Published var lostMessage: IdleMessage { didSet { save(lostMessage, "lostMessage") } }
    @Published var countdown: CountdownSettings { didSet { save(countdown, "countdown") } }
    @Published var dockPosition: DockPosition { didSet { save(dockPosition, "dockPosition") } }
    /// Snabbpanelen är alltid utfälld och går inte att fälla ihop.
    @Published var dockPinned: Bool { didSet { save(dockPinned, "dockPinned") } }
    /// Snabbpanelens höjd längs kanten, 0 = nederst och 1 = överst.
    @Published var dockY: Double { didSet { save(dockY, "dockY") } }
    /// Verktygen i snabbpanelen, i ordning.
    @Published var dockLayout: [DockTool] { didSet { save(dockLayout, "dockLayout") } }
    /// Förhandsvisningen sitter under den utfällda snabbpanelen vid notchen i stället för i ett eget fönster.
    @Published var previewDocked: Bool { didSet { save(previewDocked, "previewDocked") } }
    /// Dockad förhandsvisning: liten (lika hög som menyn) eller stor.
    @Published var previewCompact: Bool { didSet { save(previewCompact, "previewCompact") } }
    /// Vid skärmens kant: förhandsvisningen ovanför eller under panelen (längs kanten) i stället för bredvid den.
    @Published var previewBelowAtEdge: Bool { didSet { save(previewBelowAtEdge, "previewBelowAtEdge") } }
    /// Vid skärmens kant: förhandsvisningens överkant relativt panelens överkant, i punkter (negativt är nedåt).
    /// Relativt panelen, så att förhandsvisningen följer med när fliken flyttas.
    @Published var previewEdgeOffset: Double { didSet { save(previewEdgeOffset, "previewEdgeOffset") } }
    /// Texten som visas över scenen i textläget (skrivs i snabbpanelen).
    @Published var textMessage: String { didSet { save(textMessage, "textMessage") } }
    @Published var capsLockAction: CapsLockAction { didSet { save(capsLockAction, "capsLockAction") } }
    /// I funktionsläget ritar klick och dra en markering så länge Caps Lock är på.
    @Published var capsDraw: Bool { didSet { save(capsDraw, "capsDraw") } }
    /// Dimningen (markering och spotlight) syns även på presentatörens skärm.
    @Published var presenterDim: Bool { didSet { save(presenterDim, "presenterDim") } }
    /// Guiden för kortkommandon har visats (den visas en gång, vid första starten).
    @Published var shortcutGuideShown: Bool { didSet { save(shortcutGuideShown, "shortcutGuideShown") } }
    /// Introduktionsvideon har visats (den visas en gång, vid första starten, före guiden för kortkommandon).
    @Published var tutorialShown: Bool { didSet { save(tutorialShown, "tutorialShown") } }

    @Published var frozen = false
    /// Uppmätta bilder per sekund. Eget objekt, eftersom det ändras varje sekund och annars skulle rita om
    /// hela kontrollpanelen och snabbpanelen varje gång.
    let frameStats = FrameStats()
    @Published var availableWindows: [Source] = []
    @Published var availableDisplays: [Source] = []
    @Published var cameraDevices: [(id: String, name: String)] = []
    @Published var screenPermissionMissing = false
    /// Hjälpmedel behövs bara för att flytta andra appars fönster från scenskärmen.
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var strayWindowCount = 0
    @Published var hotkeyConflicts: [String] = []
    /// Funktionen vars genväg spelas in just nu.
    @Published var recordingAction: HotkeyAction?
    /// Vilket meddelande panelen redigerar just nu.
    @Published var editingIdleReason: IdleReason = .stopped
    @Published var statusMessage: String?
    @Published var countdownStatus: CountdownStatus = .idle
    /// Textläget: en ruta med texten över hela scenen.
    @Published var textShown = false
    /// Textläget i snabbpanelen: textfältet syns bara när det är på.
    @Published var textMode = false
    /// Sekunder kvar av nedräkningen.
    @Published var countdownRemaining: Double = 0
    @Published var panelSection: PanelSection? = .general
    /// Kontrollpanelens förhandsvisning: visa slutmeddelandet i stället för klockan.
    @Published var countdownPreviewEnd = false

    /// Sparade platser som ännu inte matchats mot riktiga fönster.
    var pendingPersistedSlots: [PersistedSlot?]?

    private init() {
        language = Lang.current
        camera = Self.load("camera", CameraSettings())
        var loadedEffects = Self.load("effects", EffectSettings())
        loadedEffects.rect = nil
        effects = loadedEffects
        shortcuts = Self.load("shortcuts", [String: Shortcut?]())
        fps = Self.load("fps", 30)
        stageBackground = Self.load("stageBackground", "#1C1C1E")
        stageMode = Self.load("stageMode", StageMode.virtualDisplay)
        virtualResolution = Self.load("virtualResolution", VirtualResolution.hd1080)
        showPreview = Self.load("showPreview", true)
        shareTarget = Self.load("shareTarget", ShareTarget.screen)
        moveStrayWindows = Self.load("moveStrayWindows", true)
        skippedPermissions = Self.load("skippedPermissions", Set<PermissionStep>())
        stoppedMessage = Self.load("stoppedMessage", IdleMessage(title: Phrase.nothingShared.text))
        lostMessage = Self.load("lostMessage", IdleMessage(title: Phrase.windowClosed.text, subtitle: Phrase.backShortly.text))
        countdown = Self.load("countdown", CountdownSettings())
        dockPosition = Self.load("dockPosition", DockPosition.aroundNotch)
        dockPinned = Self.load("dockPinned", false)
        previewDocked = Self.load("previewDocked", true)
        previewCompact = Self.load("previewCompact", true)
        previewBelowAtEdge = Self.load("previewBelowAtEdge", false)
        previewEdgeOffset = Self.load("previewEdgeOffset", 0.0)
        textMessage = Self.load("textMessage", "")
        capsLockAction = Self.load("capsLockAction", CapsLockAction.spotlight)
        capsDraw = Self.load("capsDraw", true)
        presenterDim = Self.load("presenterDim", true)
        shortcutGuideShown = Self.load("shortcutGuideShown", false)
        tutorialShown = Self.load("tutorialShown", false)
        dockY = Self.load("dockY", 0.6)
        dockLayout = Self.load("dockLayout", DockTool.defaultLayout)
        // Lampan blev ett eget verktyg senare. Sparade paneler får den sist en gång, sedan gäller användarens val.
        if !Self.load("dockLampAdded", false) {
            if !dockLayout.contains(.lamp) { dockLayout.append(.lamp) }
            save(dockLayout, "dockLayout")
            save(true, "dockLampAdded")
        }
        pendingPersistedSlots = Self.load("slots", [PersistedSlot?]?.none)
        // Sparade standardtexter från ett annat språk (t.ex. från tiden då appen bara fanns på svenska).
        for other in AppLanguage.allCases where other != language {
            translateUntouchedDefaults(from: other)
        }
    }

    /// Nedräkningens klockslag som datum i dag, för klockväljare.
    var countdownTargetDate: Date {
        get {
            let m = countdown.targetMinuteOfDay
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            countdown.targetMinuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    /// Standardtexter som användaren inte ändrat följer med till det nya språket; egna texter lämnas i fred.
    private func translateUntouchedDefaults(from old: AppLanguage) {
        func translate(_ text: inout String, _ phrase: Phrase) {
            if text == phrase.text(in: old) { text = phrase.text }
        }
        var stopped = stoppedMessage, lost = lostMessage, c = countdown
        translate(&stopped.title, .nothingShared)
        translate(&lost.title, .windowClosed)
        translate(&lost.subtitle, .backShortly)
        translate(&c.message, .breakMessage)
        translate(&c.welcomeText, .welcomeBack)
        translate(&c.targetTimeLabel, .resumeAt)
        if stopped != stoppedMessage { stoppedMessage = stopped }
        if lost != lostMessage { lostMessage = lost }
        if c != countdown { countdown = c }
    }

    func idleMessage(for reason: IdleReason) -> IdleMessage {
        reason == .stopped ? stoppedMessage : lostMessage
    }

    func setIdleMessage(_ message: IdleMessage, for reason: IdleReason) {
        if reason == .stopped { stoppedMessage = message } else { lostMessage = message }
    }

    func shortcut(for action: HotkeyAction) -> Shortcut? {
        if let entry = shortcuts[action.id] { return entry }
        return action.defaultShortcut
    }

    /// Visningstext för funktionens genväg, eller nil om den saknar genväg.
    func keys(_ action: HotkeyAction) -> String? {
        shortcut(for: action)?.displayString
    }

    /// Sätter en genväg. En annan funktion med samma kombination tappar sin, och returneras.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) -> HotkeyAction? {
        var updated = shortcuts
        var displaced: HotkeyAction?
        if let shortcut {
            for other in HotkeyAction.all where other != action && self.shortcut(for: other) == shortcut {
                updated[other.id] = .some(nil)
                displaced = other
            }
        }
        updated[action.id] = .some(shortcut)
        shortcuts = updated
        return displaced
    }

    private static func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func saveSlots() {
        // Skriv inte över sparade platser innan de hunnit matchas vid start.
        guard pendingPersistedSlots == nil else { return }
        save(slots.map { $0?.persisted }, "slots")
    }
}

/// Uppmätta bilder per sekund, för att se om något i kedjan går långsamt.
@MainActor
final class FrameStats: ObservableObject {
    @Published var source: Double = 0
    @Published var preview: Double = 0
}
