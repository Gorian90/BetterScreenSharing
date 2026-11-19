import AppKit
import ApplicationServices

/// Flyttar andra appars fönster från den virtuella scenskärmen till en riktig skärm. macOS kan inte spärra en skärm
/// för fönster, och på scenskärmen går de varken att se eller nå (och kan hamna i delningen). Så de flyttas i efterhand.
@MainActor
final class WindowShepherd {
    struct Report {
        /// Andra appars fönster som låg på scenskärmen när kontrollen gjordes.
        let strays: Int
        let trusted: Bool
    }

    private let worker = Worker()
    private let queue = DispatchQueue(label: "local.betterscreensharing.shepherd", qos: .utility)
    private var checking = false

    /// `stage` och `target` har origo uppe till vänster, som CGWindow och Accessibility.
    func check(stage: CGRect, target: CGRect, move: Bool, completion: @escaping @MainActor (Report) -> Void) {
        // En app som inte svarar får inte fördröja nästa kontroll eller lägga kontrollerna på kö.
        guard !checking else { return }
        checking = true
        let worker = worker
        queue.async {
            let report = worker.check(stage: stage, target: target, move: move)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.checking = false
                    completion(report)
                }
            }
        }
    }

    /// Accessibility-anrop väntar på svar från den andra appen, och därför körs de utanför huvudtråden.
    /// Används bara från en seriell kö.
    private final class Worker: @unchecked Sendable {
        private var attempts: [pid_t: Int] = [:]

        init() {
            // Gäller alla anrop från processen. Standardvärdet på flera sekunder är för långt när en app har hängt sig.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        }

        func check(stage: CGRect, target: CGRect, move: Bool) -> Report {
            let trusted = AXIsProcessTrusted()
            let strays = strayWindowsByApp(on: stage)
            attempts = attempts.filter { strays[$0.key] != nil }
            if move && trusted {
                var placed = 0
                for pid in strays.keys {
                    let attempt = attempts[pid, default: 0]
                    attempts[pid] = attempt + 1
                    // Vägrar appen flytta sig, eller flyttar tillbaka fönstret, ska den inte få hoppa fram och tillbaka.
                    if attempt >= 3 && attempt % 10 != 0 { continue }
                    placed += moveWindows(of: pid, from: stage, to: target, startingAt: placed)
                }
            }
            return Report(strays: strays.values.reduce(0, +), trusted: trusted)
        }

        private func strayWindowsByApp(on stage: CGRect) -> [pid_t: Int] {
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
            var result: [pid_t: Int] = [:]
            let ownPID = getpid()
            for info in list {
                guard info[kCGWindowLayer as String] as? Int == 0,
                      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: dict),
                      // Många appar har små osynliga hjälpfönster som ingen behöver nå.
                      frame.width >= 50, frame.height >= 50,
                      stage.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                result[pid, default: 0] += 1
            }
            return result
        }

        private func moveWindows(of pid: pid_t, from stage: CGRect, to target: CGRect, startingAt first: Int) -> Int {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return 0 }
            var placed = 0
            for window in windows {
                guard let frame = frame(of: window), stage.contains(CGPoint(x: frame.midX, y: frame.midY)),
                      !bool(kAXMinimizedAttribute, of: window) else { continue }
                // Helskärm måste lämnas först, och animeringen hinner inte bli klar. Nästa kontroll flyttar fönstret.
                if bool("AXFullScreen", of: window) {
                    AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
                    continue
                }
                place(window, size: frame.size, in: target, index: first + placed)
                placed += 1
            }
            return placed
        }

        /// Mitt på skärmen och förskjutet per fönster, så att flera fönster inte hamnar exakt ovanpå varandra.
        private func place(_ window: AXUIElement, size current: CGSize, in target: CGRect, index: Int) {
            let size = CGSize(width: min(current.width, target.width), height: min(current.height, target.height))
            let step = CGFloat(index % 8) * 28
            var origin = CGPoint(x: min(target.midX - size.width / 2 + step, target.maxX - size.width),
                                 y: min(target.midY - size.height / 2 + step, target.maxY - size.height))
            var newSize = size
            let sizeValue = size != current ? AXValueCreate(.cgSize, &newSize) : nil
            // Scenskärmen kan vara större än den riktiga skärmen. Fönstret justerar storleken efter skärmen det
            // ligger på, och blev för brett när storleken bara sattes en gång. Den sätts därför före och efter flytten.
            if let sizeValue { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
            if let position = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
            }
            if let sizeValue { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
        }

        private func frame(of window: AXUIElement) -> CGRect? {
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size else { return nil }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: origin, size: extent)
        }

        private func bool(_ attribute: String, of window: AXUIElement) -> Bool {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else { return false }
            return value as? Bool ?? false
        }
    }
}
