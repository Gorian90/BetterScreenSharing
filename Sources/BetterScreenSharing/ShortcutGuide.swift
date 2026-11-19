import AppKit
import SwiftUI

/// Vad guiden för kortkommandon visar: vilka genvägar användaren redan har provat.
@MainActor
final class ShortcutGuideModel: ObservableObject {
    @Published var tested: Set<HotkeyAction> = []
    /// Den senast provade, för att markera raden en kort stund.
    @Published var flash: HotkeyAction?
    /// Caps Lock har slagits på eller av medan guiden var öppen, och hur den står nu.
    @Published var capsTested = false
    @Published var capsOn = false
    @Published var capsFlash = false

    func press(_ action: HotkeyAction) {
        tested.insert(action)
        flash = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                if self?.flash == action { self?.flash = nil }
            }
        }
    }

    func capsLock(_ on: Bool) {
        capsTested = true
        capsOn = on
        capsFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.capsFlash = false }
        }
    }
}

struct ShortcutGuideView: View {
    @ObservedObject var model: ShortcutGuideModel
    @ObservedObject var state: AppState
    /// Tangenten i Caps Lock-funktionsläget för en funktion, eller nil om läget inte används.
    var layerKey: (HotkeyAction) -> UInt32? = { _ in nil }
    var onChange: () -> Void = {}
    var onDone: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Text(L("Try the shortcuts", "Prova kortkommandona"))
                .font(.title3.weight(.semibold))
            Text(L("They work in every app. Nothing is shared while this window is open.",
                   "De fungerar i alla appar. Inget delas medan rutan är öppen."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            HStack(alignment: .top, spacing: 56) {
                combo(.shareFrontmost)
                if showsCaps { capsCombo }
            }
            .padding(.top, 32)
            .padding(.bottom, 28)

            if !footer.isEmpty {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L("Change shortcuts…", "Ändra genvägar…")) { onChange() }
                    .buttonStyle(.link)
                Spacer()
                Button(L("Done", "Klar")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 520)
    }

    /// Caps Lock visas när den slår på och av en funktion (spotlight som standard). Funktionsläget nämns i texten under.
    private var showsCaps: Bool {
        state.capsLockAction != .none && state.capsLockAction != .functionLayer
    }

    private var capsCombo: some View {
        let tested = model.capsTested
        return VStack(spacing: 14) {
            KeyCap(text: "⇪", caption: "CAPS", lit: tested && model.capsOn, pressed: model.capsFlash)
            VStack(spacing: 4) {
                Text(state.capsLockAction.label).font(.headline)
                Group {
                    if tested {
                        Label(model.capsOn ? L("On", "På") : L("Off", "Av"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(L("Caps Lock on and off", "Caps Lock på och av")).foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
        }
        .animation(.easeOut(duration: 0.15), value: tested)
    }

    private var footer: String {
        var parts: [String] = []
        if let keys = state.keys(.shareFrontmost) {
            parts.append(L("Press \(keys) again in the same window to stop sharing, or in another window to switch to it.",
                           "Tryck \(keys) igen i samma fönster för att sluta dela, eller i ett annat fönster för att byta till det."))
        }
        if let keys = state.keys(.stopSharing) {
            parts.append(L("Press \(keys) to stop all sharing.", "Tryck \(keys) för att stoppa all delning."))
        }
        // Bara i funktionsläget, och med de tangenter som faktiskt gäller där (de kan skilja sig från genvägarna).
        if state.capsLockAction == .functionLayer {
            let keys = HotkeyAction.introduced.compactMap { layerKey($0).map { Shortcut.keyName($0) } }
            if keys.count == 2 {
                parts.append(L("With Caps Lock on, \(keys[0]) and \(keys[1]) alone are enough.",
                               "Med Caps Lock på räcker \(keys[0]) och \(keys[1]) ensamma."))
            }
        }
        return parts.joined(separator: " ")
    }

    private func combo(_ action: HotkeyAction) -> some View {
        let tested = model.tested.contains(action)
        let shortcut = state.shortcut(for: action)
        let conflict = state.hotkeyConflicts.contains { $0.hasSuffix("(\(action.label))") }
        return VStack(spacing: 14) {
            HStack(spacing: 8) {
                if let shortcut {
                    ForEach(Array(shortcut.displayParts.enumerated()), id: \.offset) { _, part in
                        KeyCap(text: part, lit: tested, pressed: model.flash == action)
                    }
                } else {
                    KeyCap(text: "–", lit: false, pressed: false)
                }
            }
            VStack(spacing: 4) {
                Text(Self.title(action)).font(.headline)
                Group {
                    if conflict {
                        Label(L("Taken by another app", "Upptagen av en annan app"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if tested {
                        Label(L("Works", "Fungerar"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(shortcut == nil ? L("No shortcut", "Ingen genväg") : L("Press to try", "Tryck för att prova"))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
        }
        .animation(.easeOut(duration: 0.15), value: tested)
    }

    private static func title(_ action: HotkeyAction) -> String {
        switch action {
        case .shareFrontmost: L("Share active window", "Dela aktivt fönster")
        default: action.label
        }
    }
}

/// En tangent ritad som en fysisk tangent. Blir grön när genvägen har provats och trycks ner en kort stund.
private struct KeyCap: View {
    let text: String
    /// Liten text under symbolen, för tangenter vars symbol inte alla känner igen (som Caps Lock).
    var caption: String? = nil
    let lit: Bool
    let pressed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: caption == nil ? 30 : 24, weight: .medium, design: .rounded))
            if let caption {
                Text(caption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.8)
            }
        }
            .foregroundStyle(lit ? Color.green : Color.primary)
            .frame(minWidth: 64, minHeight: 64)
            .padding(.horizontal, text.count > 1 ? 10 : 0)
            .background(shape.fill(Color.primary.opacity(lit ? 0.06 : 0.09)))
            .overlay(shape.strokeBorder(lit ? Color.green.opacity(0.7) : Color.primary.opacity(0.15), lineWidth: lit ? 1.5 : 1))
            // Tangentens kant nedtill, som försvinner när den trycks ner.
            .background(shape.fill(Color.black.opacity(0.35)).offset(y: pressed ? 0 : 3))
            .offset(y: pressed ? 3 : 0)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// Visas vid första starten (och från Kortkommandon). Medan den är öppen fångar den de introducerade genvägarna,
/// så att de kan provas utan att något delas.
@MainActor
final class ShortcutGuide: NSObject, NSWindowDelegate {
    static let shared = ShortcutGuide()

    private let model = ShortcutGuideModel()
    private var window: NSWindow?
    private weak var state: AppState?
    private weak var controller: AppController?

    func show(state: AppState, controller: AppController) {
        self.state = state
        self.controller = controller
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        model.tested = []
        model.flash = nil
        model.capsTested = false
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Shortcuts", "Kortkommandon")
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        let view = ShortcutGuideView(model: model, state: state,
                                     layerKey: { [weak controller] action in
                                         controller?.capsLayerBindings().first { $0.action == action }?.key
                                     },
                                     onChange: { [weak self, weak controller] in
                                         self?.window?.close()
                                         controller?.showPanel(section: .shortcuts)
                                     },
                                     onDone: { [weak self] in self?.window?.close() })
        let hosting = NSHostingView(rootView: view)
        w.contentView = hosting
        w.setContentSize(hosting.fittingSize)
        w.center()
        window = w
        controller.setSpotlightDemo(true)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// Sant om genvägen fångades av guiden och inte ska utföras.
    func consume(_ action: HotkeyAction) -> Bool {
        guard window != nil, HotkeyAction.introduced.contains(action) else { return false }
        model.press(action)
        return true
    }

    /// Caps Lock slogs på eller av. Funktionen (t.ex. spotlight) utförs som vanligt, och spotlighten syns
    /// över hela skärmen medan guiden är öppen (se `setSpotlightDemo`).
    func capsLockChanged(_ on: Bool) {
        guard window != nil else { return }
        model.capsLock(on)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        controller?.setSpotlightDemo(false)
        state?.shortcutGuideShown = true
    }
}
