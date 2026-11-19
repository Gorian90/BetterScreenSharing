import AppKit
import VirtualDisplayShim

/// En virtuell skärm som scenen visas på. Den syns inte fysiskt någonstans men kan
/// delas som en vanlig skärm i mötesappen. Skärmen försvinner när appen avslutas.
@MainActor
final class VirtualDisplayManager {
    nonisolated static var displayName: String { L("BetterScreenSharing Stage", "BetterScreenSharing Scen") }

    private var display: Any?
    var onTerminated: (() -> Void)?

    var displayID: CGDirectDisplayID? {
        guard let display else { return nil }
        let id = BSSVirtualDisplayID(display)
        return id == 0 ? nil : id
    }

    /// Skapar skärmen, eller byter upplösning om den redan finns. Returnerar false om macOS saknar stödet.
    func ensure(size: CGSize) -> Bool {
        let w = UInt32(size.width), h = UInt32(size.height)
        if let display {
            guard BSSApplyVirtualDisplayMode(display, w, h, 60) else { return false }
        } else {
            guard let created = BSSCreateVirtualDisplay(Self.displayName, w, h, 60, { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.display = nil
                        self?.onTerminated?()
                    }
                }
            }) else { return false }
            display = created
        }
        // Skärmen dyker upp i systemets lista med en liten fördröjning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.arrange() }
        }
        return true
    }

    func destroy() {
        display = nil
    }

    /// Placerar skärmen diagonalt i övre högra hörnet av de riktiga skärmarna. Den rör dem då bara
    /// i en punkt, så muspekaren och fönster hamnar inte där av misstag.
    func arrange() {
        guard let id = displayID else { return }
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        let others = ids.prefix(Int(count)).filter { $0 != id }
        guard !others.isEmpty else { return }
        let union = others.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
        let bounds = CGDisplayBounds(id)
        let target = CGPoint(x: union.maxX, y: union.minY - bounds.height)
        guard bounds.origin != target else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, id, Int32(target.x), Int32(target.y))
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}
