import AppKit
import Carbon

// MARK: - Genvägar

/// En tangentkombination: Carbon-tangentkod + Carbon-modifierare.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
    }

    init(event: NSEvent) {
        let f = event.modifierFlags
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        self.init(keyCode: Int(event.keyCode), modifiers: m)
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Kräver ⌃, ⌥ eller ⌘ – annars skulle vanligt skrivande utlösa genvägen. F-tangenter får stå ensamma.
    var isValid: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || Self.functionKeys.contains(Int(keyCode))
    }

    var displayString: String { displayParts.joined() }

    /// En del per tangent (modifierare först), för att rita dem som separata tangenter.
    var displayParts: [String] {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        return parts + [Self.keyName(keyCode)]
    }

    private static let specialNames: [Int: String] = [
        kVK_Tab: "⇥", kVK_Return: "↩", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Tangentens namn enligt aktuell tangentbordslayout (så att t.ex. svenska Å visas rätt).
    static func keyName(_ code: UInt32) -> String {
        if Int(code) == kVK_Space { return L("Space", "Mellanslag") }
        if let special = specialNames[Int(code)] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// MARK: - Funktioner som kan ha en genväg

enum HotkeyAction: Hashable, Identifiable {
    case showSlot(Int), assignSlot(Int)
    case shareFrontmost, shareScreen, stopSharing, nextSlot, previousSlot
    case toggleCamera, cameraFullscreen, cycleCameraCorner, cycleCameraShape
    case toggleSpotlight, drawHighlight, clearEffects, toggleFreeze, toggleCountdown, toggleText

    static let general: [HotkeyAction] = [
        .shareFrontmost, .shareScreen, .stopSharing, .nextSlot, .previousSlot,
        .toggleCamera, .cameraFullscreen, .cycleCameraCorner, .cycleCameraShape,
        .toggleSpotlight, .drawHighlight, .clearEffects, .toggleFreeze, .toggleCountdown, .toggleText,
    ]
    static let slotActions: [HotkeyAction] = (0..<AppState.slotCount).flatMap { [HotkeyAction.showSlot($0), .assignSlot($0)] }
    static var all: [HotkeyAction] { general + slotActions }

    var id: String {
        switch self {
        case .showSlot(let i): "showSlot\(i + 1)"
        case .assignSlot(let i): "assignSlot\(i + 1)"
        default: String(describing: self)
        }
    }

    var label: String {
        switch self {
        case .showSlot(let i): L("Show slot \(i + 1)", "Visa plats \(i + 1)")
        case .assignSlot(let i): L("Put active window in slot \(i + 1)", "Lägg aktivt fönster på plats \(i + 1)")
        case .shareFrontmost: L("Share the active window right away", "Dela det aktiva fönstret direkt")
        case .shareScreen: L("Share the entire screen (where the pointer is)", "Dela hela skärmen (där pekaren är)")
        case .stopSharing: L("Stop sharing", "Sluta dela")
        case .nextSlot: L("Next slot", "Nästa plats")
        case .previousSlot: L("Previous slot", "Föregående plats")
        case .toggleCamera: L("Camera on/off", "Kamera på/av")
        case .cameraFullscreen: L("Just me (large camera)", "Bara jag (stor kamera)")
        case .cycleCameraCorner: L("Move the camera to the next corner", "Flytta kameran till nästa hörn")
        case .cycleCameraShape: L("Change camera shape", "Byt kameraform")
        case .toggleSpotlight: L("Spotlight on/off", "Spotlight på/av")
        case .drawHighlight: L("Draw a highlight on the screen", "Rita markering på skärmen")
        case .clearEffects: L("Clear the stage (highlight, spotlight, countdown, text)", "Rensa scenen (markering, spotlight, nedräkning, text)")
        case .toggleFreeze: L("Freeze the picture", "Frys bilden")
        case .toggleCountdown: L("Countdown: start/pause", "Nedräkning: starta/pausa")
        case .toggleText: L("Text on stage: show/hide", "Text på scenen: visa/dölj")
        }
    }

    private static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// Bara två globala genvägar med modifierare som standard: ⌥ och ⌘ plus tangent krockar med för mycket i systemet
    /// och andra appar (⌥ skriver tecken som @ och |, ⌘1–9 byter flik). Det mesta nås i stället med Caps Lock-funktionsläget.
    /// Esc rensar scenen men fångas bara medan något visas, så att den fungerar som vanligt i andra appar resten av tiden.
    var defaultShortcut: Shortcut? {
        switch self {
        case .shareFrontmost: return Shortcut(keyCode: Self.keyBelowEscape, modifiers: optionKey)
        case .stopSharing: return Shortcut(keyCode: kVK_ANSI_X, modifiers: optionKey)
        case .clearEffects: return Shortcut(keyCode: kVK_Escape, modifiers: 0)
        default: return nil
        }
    }

    /// Genvägarna som guiden vid första starten visar och låter användaren prova.
    static let introduced: [HotkeyAction] = [.shareFrontmost, .stopSharing]

    /// Tangenten i funktionsläget när genvägen inte är ändrad. En ändrad genväg ger sin egen tangent.
    var defaultLayerKey: Int? {
        switch self {
        case .showSlot(let i): return Self.digits[i]
        case .shareFrontmost: return Self.keyBelowEscape
        case .shareScreen: return kVK_ANSI_F
        case .stopSharing: return kVK_ANSI_S
        case .toggleSpotlight: return kVK_Space
        case .cameraFullscreen: return kVK_ANSI_B
        case .toggleText: return kVK_ANSI_T
        case .clearEffects: return kVK_Escape
        default: return nil
        }
    }

    /// Tangenten som skriver § med den aktuella tangentbordslayouten (under Esc på svenska tangentbord).
    /// Den letas upp efter tecknet, eftersom tangentkoden för § och < skiljer sig mellan tangentbordstyper
    /// och ibland är omkastad. Finns inget § i layouten gissas efter tangentbordstyp.
    static var keyBelowEscape: Int {
        if let cached = cachedSectionKey { return cached }
        let code = (0..<128).first(where: { Shortcut.keyName(UInt32($0)) == "§" })
            ?? (KBGetLayoutType(Int16(LMGetKbdType())) == PhysicalKeyboardLayoutType(kKeyboardISO) ? kVK_ISO_Section : kVK_ANSI_Grave)
        cachedSectionKey = code
        return code
    }

    /// Uppslaget sparas; nollställs när tangentbordslayouten byts.
    nonisolated(unsafe) static var cachedSectionKey: Int?

    /// En genväg utan ⌃, ⌥ eller ⌘ (som Esc) tar tangenten från alla appar och registreras därför bara när den behövs.
    static func isBare(_ shortcut: Shortcut) -> Bool {
        shortcut.modifiers & UInt32(controlKey | optionKey | cmdKey) == 0
    }
}

// MARK: - Registrering

/// Globala kortkommandon via Carbon – kräver ingen Hjälpmedels-behörighet.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4253_5348), id: id) // "BSSH"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[id] = action
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotkeyManager.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
