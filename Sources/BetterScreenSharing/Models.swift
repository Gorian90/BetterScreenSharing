import AppKit
import ScreenCaptureKit

// MARK: - Källor

enum SourceKind: String, Codable {
    case window, display
}

/// Ett fönster eller en skärm som kan visas i scenen.
struct Source: Identifiable, Equatable {
    var kind: SourceKind
    var windowID: CGWindowID = 0
    var displayID: CGDirectDisplayID = 0
    var appName: String
    var title: String
    var bundleID: String
    /// Fånga bara scenfönstret så som det ritas på den virtuella skärmen (förhandsvisningen).
    var stageOnDisplay = false

    var id: String { kind == .window ? "w\(windowID)" : "d\(displayID)" }

    var displayName: String {
        if kind == .display { return "\(appName) (\(title))" }
        return title.isEmpty ? appName : "\(appName) – \(title)"
    }

    init(window w: SCWindow) {
        kind = .window
        windowID = w.windowID
        appName = w.owningApplication?.applicationName ?? L("Unknown app", "Okänd app")
        title = w.title ?? ""
        bundleID = w.owningApplication?.bundleIdentifier ?? ""
    }

    init(display d: SCDisplay, index: Int) {
        kind = .display
        displayID = d.displayID
        let screen = NSScreen.screen(for: d.displayID)
        appName = screen?.localizedName ?? L("Display \(index + 1)", "Skärm \(index + 1)")
        title = "\(d.width)×\(d.height)"
        bundleID = ""
    }

    var persisted: PersistedSlot {
        PersistedSlot(kind: kind, bundleID: bundleID, title: title, displayID: displayID)
    }
}

/// Fönster-ID:n överlever inte omstarter, så platser sparas som app + titel och matchas om vid start.
struct PersistedSlot: Codable {
    var kind: SourceKind
    var bundleID: String
    var title: String
    var displayID: CGDirectDisplayID
}

// MARK: - Kamera

enum CameraShape: String, CaseIterable, Codable, Identifiable {
    case circle, rounded, chamfered, sharp, hexagon
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: L("Circle / oval", "Cirkel / oval")
        case .rounded: L("Rounded corners", "Rundade hörn")
        case .chamfered: L("Chamfered corners", "Fasade hörn")
        case .sharp: L("Sharp corners", "Skarpa hörn")
        case .hexagon: L("Hexagon", "Hexagon")
        }
    }
}

enum CameraAspect: String, CaseIterable, Codable, Identifiable {
    case square, fourThree, sixteenNine, portrait
    var id: String { rawValue }
    var ratio: CGFloat {
        switch self {
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .sixteenNine: 16.0 / 9.0
        case .portrait: 3.0 / 4.0
        }
    }
    var label: String {
        switch self {
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .portrait: "3:4"
        }
    }
}

struct CameraSettings: Codable, Equatable {
    var enabled = false
    var deviceID: String?
    var shape: CameraShape = .circle
    var aspect: CameraAspect = .square
    /// Höjd som andel av scenens höjd.
    var size: Double = 0.28
    /// Mittpunkt, normaliserad med origo uppe till vänster.
    var centerX: Double = 1
    var centerY: Double = 1
    var mirror = true
    var zoom: Double = 1.0
    var borderWidth: Double = 3
    var borderColor = "#FFFFFF"
    var shadow = true
    /// "Bara jag" – kameran stor. Sparas inte mellan körningar.
    var fullscreen = false
    /// Storlek och mittpunkt i "Bara jag", skilda från den lilla bubblans.
    var fullSize: Double = 0.86
    var fullCenterX: Double = 0.5
    var fullCenterY: Double = 0.5

    enum CodingKeys: String, CodingKey {
        case enabled, deviceID, shape, aspect, size, centerX, centerY, mirror, zoom, borderWidth, borderColor, shadow
        case fullSize, fullCenterX, fullCenterY
    }

    init() {}

    /// Saknade nycklar (från äldre versioner) får standardvärden i stället för att hela inställningen kastas.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        shape = try c.decodeIfPresent(CameraShape.self, forKey: .shape) ?? d.shape
        aspect = try c.decodeIfPresent(CameraAspect.self, forKey: .aspect) ?? d.aspect
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? d.centerX
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? d.centerY
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? d.mirror
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? d.zoom
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? d.borderWidth
        borderColor = try c.decodeIfPresent(String.self, forKey: .borderColor) ?? d.borderColor
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? d.shadow
        fullSize = try c.decodeIfPresent(Double.self, forKey: .fullSize) ?? d.fullSize
        fullCenterX = try c.decodeIfPresent(Double.self, forKey: .fullCenterX) ?? d.fullCenterX
        fullCenterY = try c.decodeIfPresent(Double.self, forKey: .fullCenterY) ?? d.fullCenterY
    }
}

// MARK: - Effekter

enum HighlightMode: String, CaseIterable, Codable, Identifiable {
    case off, rect, spotlight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: L("Off", "Av")
        case .rect: L("Rectangle", "Rektangel")
        case .spotlight: L("Spotlight", "Spotlight")
        }
    }
}

struct EffectSettings: Codable, Equatable {
    var mode: HighlightMode = .off
    var dimOpacity: Double = 0.65
    /// Radie som andel av innehållets höjd.
    var spotlightRadius: Double = 0.16
    /// Andel av radien som tonas mjukt.
    var feather: Double = 0.35
    /// Markerad yta, normaliserad i källans koordinater (origo uppe till vänster).
    var rect: CGRect?
}

// MARK: - Färghjälp

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

// MARK: - Scen

enum StageMode: String, CaseIterable, Codable, Identifiable {
    case virtualDisplay, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .virtualDisplay: L("A virtual display", "En virtuell skärm")
        case .window: L("A separate window", "Ett eget fönster")
        }
    }
}

/// Vad som delas i mötesappen när scenen ligger på den virtuella skärmen.
enum ShareTarget: String, CaseIterable, Codable, Identifiable {
    case screen, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .screen: L("Entire screen (recommended)", "Hela skärmen (rekommenderas)")
        case .window: L("A window", "Ett fönster")
        }
    }
}

enum VirtualResolution: String, CaseIterable, Codable, Identifiable {
    case hd720, hd1080, qhd1440
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .hd720: CGSize(width: 1280, height: 720)
        case .hd1080: CGSize(width: 1920, height: 1080)
        case .qhd1440: CGSize(width: 2560, height: 1440)
        }
    }
    var label: String { "\(Int(size.width)) × \(Int(size.height))" }
}

extension Source {
    /// Källa för ett av appens egna fönster (används av förhandsvisningen).
    static func ownWindow(_ windowID: CGWindowID) -> Source {
        Source(kind: .window, windowID: windowID, displayID: 0, appName: "BetterScreenSharing", title: "", bundleID: "")
    }

    /// Scenfönstret så som det ritas på den virtuella skärmen, utan menyrad eller annat runt omkring.
    static func stageDisplay(_ displayID: CGDirectDisplayID, window windowID: CGWindowID) -> Source {
        var s = Source(kind: .display, windowID: windowID, displayID: displayID, appName: VirtualDisplayManager.displayName, title: "", bundleID: "")
        s.stageOnDisplay = true
        return s
    }

    private init(kind: SourceKind, windowID: CGWindowID, displayID: CGDirectDisplayID, appName: String, title: String, bundleID: String) {
        self.kind = kind
        self.windowID = windowID
        self.displayID = displayID
        self.appName = appName
        self.title = title
        self.bundleID = bundleID
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}

// MARK: - När ingen källa delas

enum IdleContent: String, CaseIterable, Codable, Identifiable {
    case text, image, camera, lastFrame
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: L("Text", "Text")
        case .image: L("Image, logo or GIF", "Bild, logga eller GIF")
        case .camera: L("Just me (large camera)", "Bara jag (kameran stor)")
        case .lastFrame: L("Last frame (frozen)", "Senaste bilden (fryst)")
        }
    }
}

enum IdleReason: String, CaseIterable, Identifiable {
    case stopped, lost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stopped: L("When you stop sharing", "När du slutar dela")
        case .lost: L("When the source disappears", "När källan försvinner")
        }
    }
}

/// Var texten hamnar ovanpå en bild: ett rutnät med tre rader och tre kolumner.
enum TextPosition: String, CaseIterable, Codable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: String { rawValue }
    /// 0 = vänster/överst, 0,5 = mitten, 1 = höger/nederst.
    var anchor: (x: CGFloat, y: CGFloat) {
        let i = Self.allCases.firstIndex(of: self)!
        return (CGFloat(i % 3) / 2, CGFloat(i / 3) / 2)
    }
    var label: String {
        switch self {
        case .topLeft: L("Top left", "Uppe till vänster")
        case .top: L("Top center", "Uppe i mitten")
        case .topRight: L("Top right", "Uppe till höger")
        case .left: L("Center left", "Mitten till vänster")
        case .center: L("Center", "Mitten")
        case .right: L("Center right", "Mitten till höger")
        case .bottomLeft: L("Bottom left", "Nere till vänster")
        case .bottom: L("Bottom center", "Nere i mitten")
        case .bottomRight: L("Bottom right", "Nere till höger")
        }
    }
    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .top: "arrow.up"
        case .topRight: "arrow.up.right"
        case .left: "arrow.left"
        case .center: "circle"
        case .right: "arrow.right"
        case .bottomLeft: "arrow.down.left"
        case .bottom: "arrow.down"
        case .bottomRight: "arrow.down.right"
        }
    }
}

struct IdleMessage: Codable, Equatable {
    var content: IdleContent = .text
    var title: String
    var subtitle = ""
    /// Bilden sparas i inställningarna, så att appen inte är beroende av någon fil.
    var imageData: Data?
    /// Rubrik och undertext ovanpå bilden, på vald plats.
    var textOnImage = false
    var textPosition: TextPosition = .bottom

    init(content: IdleContent = .text, title: String, subtitle: String = "", imageData: Data? = nil) {
        self.content = content
        self.title = title
        self.subtitle = subtitle
        self.imageData = imageData
    }

    /// Saknade nycklar (från äldre versioner) får standardvärden i stället för att meddelandet kastas.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(IdleContent.self, forKey: .content) ?? .text
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        textOnImage = try c.decodeIfPresent(Bool.self, forKey: .textOnImage) ?? false
        textPosition = try c.decodeIfPresent(TextPosition.self, forKey: .textPosition) ?? .bottom
    }
}

// MARK: - Nedräkning

enum CountdownPlacement: String, CaseIterable, Codable, Identifiable {
    case full, corner
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: L("Across the whole stage", "Över hela scenen")
        case .corner: L("Small in the corner", "Litet i hörnet")
        }
    }
}

enum CountdownEnd: String, CaseIterable, Codable, Identifiable {
    case welcome, resume, holdZero
    var id: String { rawValue }
    var label: String {
        switch self {
        case .welcome: L("Show a welcome message", "Visa ett välkomstmeddelande")
        case .resume: L("Go back to what was shared", "Gå tillbaka till det som delades")
        case .holdZero: L("Stay at 00:00", "Stanna på 00:00")
        }
    }
}

enum CountdownMode: String, CaseIterable, Codable, Identifiable {
    case duration, untilTime
    var id: String { rawValue }
    var label: String {
        switch self {
        case .duration: L("Duration", "Längd")
        case .untilTime: L("Until a time", "Till klockslag")
        }
    }
}

struct CountdownSettings: Codable, Equatable {
    var mode: CountdownMode = .duration
    var minutes: Double = 10
    /// Klockslag att räkna ned till, i minuter efter midnatt enligt datorns klocka och tidszon.
    var targetMinuteOfDay = 13 * 60
    var message = Phrase.breakMessage.text
    var subtitle = ""
    var placement: CountdownPlacement = .full
    var endAction: CountdownEnd = .welcome
    var welcomeText = Phrase.welcomeBack.text
    var chime = true
    var messageColor = "#F2F3F5"
    var subtitleColor = "#B4B9C3"
    var timeColor = "#FFB020"
    var backgroundColor = "#15171C"
    /// Vid nedräkning till ett klockslag: skriv ut klockslaget under klockan, med en text före.
    var showTargetTime = true
    var targetTimeLabel = Phrase.resumeAt.text
    var targetTimeColor = "#B4B9C3"

    init() {}

    /// Saknade nycklar (från äldre versioner) får standardvärden i stället för att hela inställningen kastas.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CountdownSettings()
        mode = try c.decodeIfPresent(CountdownMode.self, forKey: .mode) ?? d.mode
        minutes = try c.decodeIfPresent(Double.self, forKey: .minutes) ?? d.minutes
        targetMinuteOfDay = try c.decodeIfPresent(Int.self, forKey: .targetMinuteOfDay) ?? d.targetMinuteOfDay
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? d.message
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? d.subtitle
        placement = try c.decodeIfPresent(CountdownPlacement.self, forKey: .placement) ?? d.placement
        endAction = try c.decodeIfPresent(CountdownEnd.self, forKey: .endAction) ?? d.endAction
        welcomeText = try c.decodeIfPresent(String.self, forKey: .welcomeText) ?? d.welcomeText
        chime = try c.decodeIfPresent(Bool.self, forKey: .chime) ?? d.chime
        messageColor = try c.decodeIfPresent(String.self, forKey: .messageColor) ?? d.messageColor
        subtitleColor = try c.decodeIfPresent(String.self, forKey: .subtitleColor) ?? d.subtitleColor
        timeColor = try c.decodeIfPresent(String.self, forKey: .timeColor) ?? d.timeColor
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor) ?? d.backgroundColor
        showTargetTime = try c.decodeIfPresent(Bool.self, forKey: .showTargetTime) ?? d.showTargetTime
        targetTimeLabel = try c.decodeIfPresent(String.self, forKey: .targetTimeLabel) ?? d.targetTimeLabel
        targetTimeColor = try c.decodeIfPresent(String.self, forKey: .targetTimeColor) ?? d.targetTimeColor
    }

    /// Nästa gång klockan visar det valda klockslaget (i dag, eller i morgon om det redan passerats).
    func targetDate(after now: Date = Date()) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let today = cal.date(bySettingHour: targetMinuteOfDay / 60, minute: targetMinuteOfDay % 60, second: 0, of: start) ?? now
        return today > now ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Sekunder som nedräkningen skulle vara om den startade nu.
    func seconds(from now: Date = Date()) -> Double {
        switch mode {
        case .duration: max(1, minutes * 60)
        case .untilTime: max(1, targetDate(after: now).timeIntervalSince(now))
        }
    }

    /// Det scenen ska visa. `remaining` saknas när nedräkningen är slut.
    func display(remaining: Double?, progress: Double) -> CountdownDisplay {
        var d = CountdownDisplay(message: message, subtitle: subtitle, time: remaining.map(Self.formatTime), progress: progress,
                                 placement: placement, messageColor: messageColor, subtitleColor: subtitleColor,
                                 timeColor: timeColor, backgroundColor: backgroundColor)
        if mode == .untilTime && showTargetTime {
            d.footer = [targetTimeLabel.trimmingCharacters(in: .whitespaces), targetTimeText].filter { !$0.isEmpty }.joined(separator: " ")
            d.footerColor = targetTimeColor
        }
        if remaining == nil {
            if endAction == .welcome {
                d.message = welcomeText
                d.subtitle = ""
                d.footer = ""
            } else {
                d.time = Self.formatTime(0)
            }
        }
        return d
    }

    /// 04:59, eller 1:04:59 för en timme eller mer. Avrundas uppåt så att 10:00 syns vid start och 00:00 först vid slutet.
    static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "10:00" eller "till 13:00", för menyer och hjälptexter.
    var shortDescription: String {
        mode == .untilTime ? L("until \(targetTimeText)", "till \(targetTimeText)") : Self.formatTime(minutes * 60)
    }

    var targetTimeText: String {
        String(format: "%02d:%02d", targetMinuteOfDay / 60, targetMinuteOfDay % 60)
    }
}

enum CountdownStatus {
    case idle, running, paused, finished
}

/// Det som scenen ritar för nedräkningen. `time` saknas när bara ett slutmeddelande visas.
struct CountdownDisplay: Equatable {
    var message: String
    var subtitle = ""
    var time: String?
    var progress: Double
    var placement: CountdownPlacement
    var messageColor = "#F2F3F5"
    var subtitleColor = "#B4B9C3"
    var timeColor = "#FFB020"
    var backgroundColor = "#15171C"
    /// Rad under klockan, t.ex. "Vi fortsätter klockan 13:00".
    var footer = ""
    var footerColor = "#B4B9C3"
}

// MARK: - Snabbpanel

enum DockPosition: String, CaseIterable, Codable, Identifiable {
    case right, left, notch, aroundNotch, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .right: L("Right edge", "Höger kant")
        case .left: L("Left edge", "Vänster kant")
        case .notch: L("Below the notch", "Under notchen")
        case .aroundNotch: L("Around the notch", "Runt notchen")
        case .off: L("Off", "Av")
        }
    }
    /// Panelen sitter vid notchen (under eller runt den).
    var atNotch: Bool { self == .notch || self == .aroundNotch }
}

/// Ett verktyg i snabbpanelen. Användaren väljer vilka som finns med och i vilken ordning.
enum DockTool: String, CaseIterable, Codable, Identifiable {
    case slots, screen, camera, onlyMe, spotlight, highlight, clear, freeze, countdown, text, stop, preview, panel
    /// Avdelare mellan grupper (får finnas flera gånger).
    case divider
    /// Var notchen ligger när panelen sitter runt notchen: verktygen före hamnar till vänster, efter till höger.
    case notch
    /// Lampan som lyser när något delas. Ligger sist som standard men kan flyttas eller tas bort.
    case lamp
    var id: String { rawValue }

    static let defaultLayout: [DockTool] = [
        .slots, .screen, .divider, .camera, .onlyMe, .spotlight, .highlight, .clear, .notch,
        .freeze, .countdown, .text, .stop, .divider, .preview, .panel, .lamp,
    ]

    var repeatable: Bool { self == .divider }

    var label: String {
        switch self {
        case .slots: L("Slots 1–9", "Platser 1–9")
        case .screen: L("Entire screen", "Hela skärmen")
        case .camera: L("Camera", "Kamera")
        case .onlyMe: L("Just me", "Bara jag")
        case .spotlight: L("Spotlight", "Spotlight")
        case .highlight: L("Highlight", "Markering")
        case .clear: L("Clear", "Rensa")
        case .freeze: L("Freeze", "Frys")
        case .countdown: L("Countdown", "Nedräkning")
        case .text: L("Text", "Text")
        case .stop: L("Stop sharing", "Sluta dela")
        case .preview: L("Preview", "Förhandsvisning")
        case .panel: L("Control panel", "Kontrollpanel")
        case .divider: L("Divider", "Avdelare")
        case .notch: L("The notch", "Notchen")
        case .lamp: L("Sharing light", "Delningslampa")
        }
    }

    var symbol: String {
        switch self {
        case .slots: "number.square"
        case .screen: "display"
        case .camera: "video"
        case .onlyMe: "person"
        case .spotlight: "sun.max"
        case .highlight: "rectangle.dashed"
        case .clear: "eraser"
        case .freeze: "pause"
        case .countdown: "timer"
        case .text: "text.bubble"
        case .stop: "stop.fill"
        case .preview: "eye"
        case .panel: "slider.horizontal.3"
        case .divider: "poweron"
        case .notch: "rectangle.topthird.inset.filled"
        case .lamp: "circle.fill"
        }
    }
}

// MARK: - Caps Lock

/// Caps Lock som strömbrytare: på = funktionen på, av = av. Lampan på tangenten visar läget.
enum CapsLockAction: String, CaseIterable, Codable, Identifiable {
    case none, functionLayer, spotlight, camera, onlyMe, freeze
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: L("Nothing", "Ingenting")
        case .functionLayer: L("Function mode (single keys)", "Funktionsläge (enskilda tangenter)")
        case .spotlight: L("Spotlight", "Spotlight")
        case .camera: L("Camera", "Kamera")
        case .onlyMe: L("Just me", "Bara jag")
        case .freeze: L("Freeze the picture", "Frys bilden")
        }
    }
}

// MARK: - Kontrollpanel

enum PanelSection: String, CaseIterable, Identifiable {
    case general, camera, effects, countdown, messages, dock, shortcuts
    var id: String { rawValue }
    var label: String {
        switch self {
        case .camera: L("Camera", "Kamera")
        case .effects: L("Highlight and dim", "Framhäv och dimma")
        case .dock: L("Quick panel", "Snabbpanel")
        case .countdown: L("Countdown", "Nedräkning")
        case .messages: L("Messages", "Meddelanden")
        case .shortcuts: L("Shortcuts", "Kortkommandon")
        case .general: L("General", "Allmänt")
        }
    }
    var symbol: String {
        switch self {
        case .camera: "video"
        case .effects: "sun.max"
        case .dock: "sidebar.right"
        case .countdown: "timer"
        case .messages: "text.bubble"
        case .shortcuts: "command"
        case .general: "gearshape"
        }
    }
}
