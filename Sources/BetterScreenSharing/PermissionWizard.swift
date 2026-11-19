import AppKit
import AVFoundation
import SwiftUI

enum PermissionStep: String, Codable {
    case screenRecording, accessibility, camera

    var isGranted: Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    /// Skärminspelning som slås på medan appen körs syns inte förrän appen har startats om: både
    /// CGPreflightScreenCaptureAccess och fönsterlistan svarar samma sak hela processens livstid. ScreenCaptureKit
    /// svarar direkt, men varje anrop utan behörighet visar systemets ruta, så det går inte att fråga i en loop.
    var needsRelaunch: Bool { self == .screenRecording }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "macwindow.on.rectangle"
        case .camera: "video"
        }
    }

    var title: String {
        switch self {
        case .screenRecording: L("Screen recording", "Skärminspelning")
        case .accessibility: L("Accessibility", "Hjälpmedel")
        case .camera: L("Camera", "Kamera")
        }
    }

    var explanation: String {
        switch self {
        case .screenRecording:
            L("In order to show the windows and screens you choose on the stage, BetterScreenSharing needs screen recording.",
              "För att kunna visa de fönster och skärmar du väljer på scenen behöver BetterScreenSharing skärminspelning.")
        case .accessibility:
            L("In order to prevent windows from getting stuck on the invisible stage display, BetterScreenSharing needs Accessibility to move them back to your screen.",
              "För att fönster inte ska fastna på den osynliga scenskärmen behöver BetterScreenSharing Hjälpmedel, som flyttar tillbaka dem till din skärm.")
        case .camera:
            L("In order to show you on the stage, BetterScreenSharing needs the camera.",
              "För att kunna visa dig på scenen behöver BetterScreenSharing kameran.")
        }
    }

    var waitingHint: String {
        switch self {
        case .screenRecording:
            L("Turn on BetterScreenSharing in the list, then click Restart.",
              "Slå på BetterScreenSharing i listan och klicka sedan på Starta om.")
        case .accessibility:
            L("Turn on BetterScreenSharing in the list.", "Slå på BetterScreenSharing i listan.")
        case .camera:
            L("Allow the camera in the system's dialog or in the list.", "Tillåt kameran i systemets fråga eller i listan.")
        }
    }

    /// Kameran kan inte slås på i Systeminställningar förrän appen har frågat, för då finns appen inte i listan.
    var asksDirectly: Bool {
        self == .camera && AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
    }

    func perform() {
        switch self {
        case .screenRecording:
            Self.askThenOpenSettings("Privacy_ScreenCapture") { _ = CGRequestScreenCaptureAccess() }
        case .accessibility:
            Self.askThenOpenSettings("Privacy_Accessibility") {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        case .camera:
            if asksDirectly {
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            } else {
                Self.openSettings("Privacy_Camera")
            }
        }
    }

    /// Appen hamnar i listan i Systeminställningar först när systemet har frågat. Saknas den där, första gången eller
    /// efter att den tagits bort, visar frågan systemets ruta, som har en egen knapp till inställningarna. Finns
    /// appen redan händer inget synligt, och då öppnas inställningarna direkt.
    private static func askThenOpenSettings(_ pane: String, ask: () -> Void) {
        ask()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !systemPromptVisible() { openSettings(pane) }
        }
    }

    /// Äldre versioner sparade här om systemet hade frågat. Nycklarna gäller bara den datorn och får inte följa med
    /// i exporterade inställningar.
    static let askedKeyPrefix = "askedSystemForPermission."

    /// Systemets behörighetsruta visas av en egen process, vars namn syns även utan skärminspelning.
    private static func systemPromptVisible() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "universalAccessAuthWarn" }
    }

    private static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

@MainActor
final class PermissionWizardModel: ObservableObject {
    @Published private(set) var steps: [PermissionStep] = []
    @Published private(set) var index = 0
    @Published private(set) var granted = false
    @Published private(set) var waiting = false
    /// Följer kamerans läge, som ändras när användaren har svarat på systemets fråga.
    @Published private(set) var asksDirectly = false

    var onFinish: () -> Void = {}
    var onSkip: (PermissionStep) -> Void = { _ in }

    var step: PermissionStep? { steps.indices.contains(index) ? steps[index] : nil }
    var isLast: Bool { index >= steps.count - 1 }

    func start(_ steps: [PermissionStep]) {
        self.steps = steps
        show(0)
    }

    func append(_ more: [PermissionStep]) {
        steps += more.filter { !steps.contains($0) }
    }

    /// Bara för förhandsvisning i `--render-ui`, där ingen timer eller systemfråga ska köras.
    func preview(_ step: PermissionStep, index: Int, of steps: [PermissionStep], waiting: Bool, granted: Bool) {
        self.steps = steps
        self.index = index
        self.waiting = waiting
        self.granted = granted
        asksDirectly = step == .camera
    }

    func primary() {
        guard let step else { return }
        if granted {
            next()
        } else {
            waiting = true
            step.perform()
        }
    }

    func skip() {
        if let step { onSkip(step) }
        next()
    }

    /// Startar en ny instans när den här har avslutats. Saknas behörigheten fortfarande visar den nya guiden steget igen.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"",
                          "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }

    /// Anropas av en timer: systemet meddelar inte när en behörighet ändras.
    func refresh() {
        guard let step else { return }
        if asksDirectly != step.asksDirectly { asksDirectly = step.asksDirectly }
        let now = step.isGranted
        guard now != granted else { return }
        granted = now
        guard granted else { return }
        // Användaren är i Systeminställningar. Guiden kommer tillbaka och går vidare av sig själv.
        NSApp.activate()
        let current = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.index == current, self.granted else { return }
                self.next()
            }
        }
    }

    private func next() {
        show(index + 1)
    }

    private func show(_ start: Int) {
        // Ett senare steg kan ha hunnit bli klart, till exempel om det slogs på medan guiden visade ett annat.
        var i = start
        while steps.indices.contains(i), steps[i].isGranted { i += 1 }
        guard steps.indices.contains(i) else { onFinish(); return }
        index = i
        waiting = false
        granted = false
        asksDirectly = steps[i].asksDirectly
    }
}

struct PermissionWizardView: View {
    @ObservedObject var model: PermissionWizardModel

    var body: some View {
        if let step = model.step {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Step \(model.index + 1) of \(model.steps.count)", "Steg \(model.index + 1) av \(model.steps.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 30))
                        .foregroundStyle(.tint)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.title).font(.title2.weight(.semibold))
                        Text(step.explanation).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Group {
                    if model.granted {
                        Label(L("Allowed", "Tillåtet"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if model.waiting {
                        Text(step.waitingHint).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                // Plats för två rader från början, så att fönstret inte ändrar storlek när tipset dyker upp.
                .frame(minHeight: 34, alignment: .topLeading)
                .padding(.leading, 60)
                HStack {
                    Spacer()
                    if !model.granted {
                        // När inställningarna har öppnats har användaren oftast gjort sin del, och då vore "Hoppa över" fel.
                        Button(model.waiting ? L("Continue", "Fortsätt") : L("Skip", "Hoppa över")) { model.skip() }
                    }
                    if !model.granted, model.waiting, step.needsRelaunch {
                        Button(L("Open System Settings", "Öppna Systeminställningar")) { model.primary() }
                        Button(L("Restart", "Starta om")) { model.relaunch() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(primaryTitle) { model.primary() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(24)
            .frame(width: 480)
        }
    }

    private var primaryTitle: String {
        if model.granted { return model.isLast ? L("Done", "Klar") : L("Next", "Nästa") }
        if model.asksDirectly { return L("Allow Camera", "Tillåt kameran") }
        return L("Open System Settings", "Öppna Systeminställningar")
    }
}

/// Guiden går igenom de behörigheter som saknas, en i taget. Den är inte modal: en modal ruta kan hindra systemets
/// Avsluta och öppna igen, som är sista steget för skärminspelning.
@MainActor
final class PermissionWizard: NSObject, NSWindowDelegate {
    static let shared = PermissionWizard()

    private let model = PermissionWizardModel()
    private var window: NSWindow?
    private var timer: Timer?
    private var completions: [() -> Void] = []

    /// Sparar steg som hoppas över, så att valfria behörigheter inte efterfrågas vid varje start.
    var onSkip: (PermissionStep) -> Void {
        get { model.onSkip }
        set { model.onSkip = newValue }
    }

    func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// `completion` körs när guiden har stängts, oavsett hur stegen slutade.
    func run(_ steps: [PermissionStep], completion: @escaping () -> Void) {
        completions.append(completion)
        if window != nil {
            model.append(steps)
            bringToFront()
            return
        }
        model.onFinish = { [weak self] in self?.window?.close() ?? self?.finish() }
        model.start(steps)
        // Allt var redan klart, och då har start() redan avslutat.
        guard !completions.isEmpty else { return }

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "BetterScreenSharing"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let hosting = NSHostingView(rootView: PermissionWizardView(model: model))
        w.contentView = hosting
        w.setContentSize(hosting.fittingSize)
        w.center()
        window = w
        bringToFront()

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        window = nil
        let pending = completions
        completions = []
        pending.forEach { $0() }
    }
}
