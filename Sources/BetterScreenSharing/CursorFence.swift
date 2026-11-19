import AppKit

/// Håller muspekaren borta från den virtuella scenskärmen. macOS kräver att skärmar hänger ihop, så skärmen kan inte
/// läggas helt utom räckhåll, och på den är pekaren osynlig. Ingen funktion behöver pekaren där: scenen styrs via
/// förhandsvisningen. Musövervakning kräver inte heller någon behörighet, till skillnad från tangentbordsövervakning.
@MainActor
final class CursorFence {
    private var monitors: [Any] = []

    /// nil när scenen ligger i ett vanligt fönster; då finns inget att spärra.
    var stageDisplay: CGDirectDisplayID? {
        didSet {
            guard stageDisplay != oldValue else { return }
            removeMonitors()
            if stageDisplay != nil { addMonitors() }
        }
    }

    private func addMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Den globala övervakningen ser bara andra appars händelser, så våra egna fönster behöver en lokal.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.enforce() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.enforce() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Anropas även av en timer: alla mushändelser når inte övervakningen. En simulerad dragning medan appen själv
    /// var aktiv syntes till exempel inte alls.
    func enforce() {
        guard let stageDisplay, let cursor = CGEvent(source: nil)?.location,
              CGDisplayBounds(stageDisplay).contains(cursor),
              let nearest = nearestPointOnRealScreens(to: cursor, excluding: stageDisplay) else { return }
        CGWarpMouseCursorPosition(nearest)
        // Annars ignorerar systemet musrörelser en kort stund efter flytten, och pekaren känns som att den fastnar.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Närmaste punkt i stället för den senaste positionen: pekaren stannar vid kanten även efter en snabb rörelse.
    private func nearestPointOnRealScreens(to point: CGPoint, excluding stage: CGDirectDisplayID) -> CGPoint? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        let candidates = ids.prefix(Int(count)).filter { $0 != stage }.map { id -> CGPoint in
            let b = CGDisplayBounds(id)
            return CGPoint(x: min(max(point.x, b.minX), b.maxX - 1), y: min(max(point.y, b.minY), b.maxY - 1))
        }
        return candidates.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }
    }
}
