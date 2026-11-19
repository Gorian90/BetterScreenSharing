import AppKit
import AVFoundation
import SwiftUI

// MARK: - Manus

/// Introduktionsvideon: en kort, ljudlös animation som visar hur man delar i en mötesapp med appen.
/// Den ritas i kod, precis som appikonen, så att appen inte behöver några video- eller bildfiler och
/// texterna följer appens språk och användarens genvägar. `--write-tutorial-video` sparar den som en .mp4.
struct TutorialScript {
    var shareKeys: [String]
    var stopKeys: [String]
    /// Det som väljs i mötesappens delningsruta: den virtuella skärmen eller scenfönstret.
    var stageName: String
    /// Det andra valet i delningsrutan.
    var otherChoice: String

    static let duration = 28.5
    /// Kapitlen (början, slut). Efter det sista kommer slutbilden.
    static let chapters: [(start: Double, end: Double)] = [(0, 7.2), (7.2, 13.9), (13.9, 22.4), (22.4, 25.5)]

    static var standard: TutorialScript {
        TutorialScript(shareKeys: HotkeyAction.shareFrontmost.defaultShortcut?.displayParts ?? ["⌥", "§"],
                       stopKeys: HotkeyAction.stopSharing.defaultShortcut?.displayParts ?? ["⌥", "X"],
                       stageName: VirtualDisplayManager.displayName,
                       otherChoice: L("Built-in display", "Inbyggd skärm"))
    }

    /// Med användarens genvägar och delningssätt.
    @MainActor
    static func current(_ state: AppState) -> TutorialScript {
        var script = standard
        if let keys = state.shortcut(for: .shareFrontmost)?.displayParts { script.shareKeys = keys }
        if let keys = state.shortcut(for: .stopSharing)?.displayParts { script.stopKeys = keys }
        if state.stageMode == .window || state.shareTarget == .window {
            script.stageName = AppController.stageTitle
            script.otherChoice = L("Document", "Dokument")
        }
        return script
    }

    var captions: [(title: String, detail: String)] {
        let share = shareKeys.joined(), stop = stopKeys.joined()
        return [
            (L("Share the stage in your meeting app", "Dela scenen i mötesappen"),
             L("Choose Share, then \(stageName). You only do this once per meeting.",
               "Välj Dela och sedan \(stageName). Det gör du bara en gång per möte.")),
            (L("Show a window with \(share)", "Visa ett fönster med \(share)"),
             L("Press it in the window you want to show. Press it in another window to switch.",
               "Tryck i fönstret du vill visa. Tryck i ett annat fönster för att byta.")),
            (L("The quick panel in the menu bar", "Snabbpanelen i menyraden"),
             L("Click the middle of the menu bar for camera, spotlight, highlight and more.",
               "Klicka mitt i menyraden för kamera, spotlight, markering och mer.")),
            (L("Stop sharing with \(stop)", "Sluta dela med \(stop)"),
             L("The meeting keeps sharing the stage, but the audience only sees a message.",
               "Mötet fortsätter dela scenen, men publiken ser bara ett meddelande.")),
        ]
    }
}

// MARK: - Tidslinje och mått

private enum Palette {
    static func hex(_ s: String) -> Color { Color(nsColor: NSColor(hex: s)!) }
    static let ink = hex("#15171C")
    static let panel = hex("#1B1D23")
    static let button = hex("#2E323B")
    static let notchButton = hex("#26292F")
    static let divider = hex("#353943")
    static let icon = hex("#E6E8EC")
    static let muted = hex("#A9AEB8")
    static let amber = hex("#FFB020")
    static let amberDark = hex("#E09400")
    static let red = hex("#FF6B5E")
    static let back = hex("#3A3F4B")
    static let light = hex("#F2F3F5")
}

/// Allt ritas på en duk på 960 × 600 punkter och skalas sedan.
private enum Geo {
    static let canvas = CGSize(width: 960, height: 600)
    static let menuH: CGFloat = 30
    static let notchW: CGFloat = 170
    static let midX: CGFloat = 480
    static let meetingBig = CGRect(x: 200, y: 66, width: 560, height: 402)
    static let meetingSmall = CGRect(x: 650, y: 300, width: 280, height: 201)
    /// Mötesfönstrets inre storlek; det skalas till sin ruta.
    static let meetingInner = CGSize(width: 460, height: 330)
    static let winA = CGRect(x: 60, y: 70, width: 380, height: 250)
    static let winB = CGRect(x: 210, y: 170, width: 380, height: 250)

    // Punkter i mötesfönstret (inre koordinater).
    static let shareButton = CGPoint(x: 258, y: 308)
    static let stageThumb = CGPoint(x: 325, y: 135)
    static let otherThumb = CGPoint(x: 135, y: 135)
    static let pickerShare = CGPoint(x: 366, y: 236)

    static func inMeeting(_ p: CGPoint, _ r: CGRect = meetingBig) -> CGPoint {
        let s = r.width / meetingInner.width
        return CGPoint(x: r.minX + p.x * s, y: r.minY + p.y * s)
    }
}

private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
private func smooth(_ x: Double) -> Double { let c = clamp(x); return c * c * (3 - 2 * c) }
/// 0 före `a`, 1 efter `b`, mjuk övergång emellan.
private func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { smooth((t - a) / (b - a)) }
private func lerp(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }
private func lerp(_ a: CGRect, _ b: CGRect, _ k: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, k), y: lerp(a.minY, b.minY, k), width: lerp(a.width, b.width, k), height: lerp(a.height, b.height, k))
}

private enum VideoSource { case none, presentation, document }

/// Muspekarens rörelse: (tid, punkt), med mjuka förflyttningar mellan punkterna.
private let cursorKeys: [(Double, CGPoint)] = {
    let share = Geo.inMeeting(Geo.shareButton), thumb = Geo.inMeeting(Geo.stageThumb), go = Geo.inMeeting(Geo.pickerShare)
    let notch = CGPoint(x: Geo.midX, y: 15)
    return [
        (0, CGPoint(x: 820, y: 520)), (0.6, CGPoint(x: 820, y: 520)),
        (1.6, share), (2.2, share),
        (3.0, thumb), (3.5, thumb),
        (4.1, go), (5.0, go),
        (6.6, CGPoint(x: 700, y: 250)), (7.9, CGPoint(x: 700, y: 250)),
        (8.6, CGPoint(x: 130, y: 120)), (10.5, CGPoint(x: 130, y: 120)),
        (11.0, CGPoint(x: 520, y: 390)), (14.0, CGPoint(x: 520, y: 390)),
        (14.8, notch), (15.2, notch),
        (15.9, DockGeo.center("camera")), (16.8, DockGeo.center("camera")),
        (17.3, DockGeo.center("spotlight")), (17.7, DockGeo.center("spotlight")),
        (18.2, notch), (18.4, notch),
        // Spotlighten följer pekaren över det delade fönstret.
        (19.0, CGPoint(x: 300, y: 260)), (19.8, CGPoint(x: 520, y: 240)), (20.6, CGPoint(x: 470, y: 370)),
        (21.4, CGPoint(x: 290, y: 330)), (22.2, CGPoint(x: 380, y: 285)),
    ]
}()

private let clicks: [Double] = [1.8, 3.2, 4.3, 8.8, 11.2, 15.0, 16.1, 17.5, 18.3]

private func cursorPoint(_ t: Double) -> CGPoint {
    guard let first = cursorKeys.first else { return .zero }
    if t <= first.0 { return first.1 }
    for (a, b) in zip(cursorKeys, cursorKeys.dropFirst()) where t <= b.0 {
        let k = smooth((t - a.0) / (b.0 - a.0))
        return CGPoint(x: lerp(a.1.x, b.1.x, k), y: lerp(a.1.y, b.1.y, k))
    }
    return cursorKeys.last!.1
}

/// Snabbpanelen runt notchen, med standardverktygen (utan platser, som vid första starten).
private enum DockGeo {
    enum Kind { case button(String, String), divider, lamp }
    static let left: [(String, Kind)] = [
        ("screen", .button("display", "")), ("d1", .divider), ("camera", .button("video", "video.fill")),
        ("onlyMe", .button("person", "")), ("spotlight", .button("sun.max", "")),
        ("highlight", .button("rectangle.dashed", "")), ("clear", .button("eraser", "")),
    ]
    static let right: [(String, Kind)] = [
        ("freeze", .button("pause", "")), ("countdown", .button("timer", "")), ("text", .button("text.bubble", "")),
        ("stop", .button("stop.fill", "")), ("d2", .divider), ("preview", .button("eye", "")),
        ("panel", .button("slider.horizontal.3", "")), ("lamp", .lamp),
    ]
    static let buttonSize = CGSize(width: 28, height: 24)

    static func width(_ kind: Kind) -> CGFloat {
        switch kind {
        case .button: buttonSize.width
        case .divider: 7
        case .lamp: 20
        }
    }

    static func rowWidth(_ row: [(String, Kind)]) -> CGFloat {
        row.reduce(0) { $0 + width($1.1) } + CGFloat(max(row.count - 1, 0)) * 2
    }

    static var side: CGFloat { max(rowWidth(left), rowWidth(right)) }
    static var leftEdge: CGFloat { Geo.midX - Geo.notchW / 2 }
    static var rightEdge: CGFloat { Geo.midX + Geo.notchW / 2 }

    /// Mittpunkterna i x-led: vänster rad slutar vid notchen, höger rad börjar vid den.
    static var centers: [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        var x = leftEdge
        for (id, kind) in left.reversed() {
            result[id] = x - width(kind) / 2
            x -= width(kind) + 2
        }
        x = rightEdge
        for (id, kind) in right {
            result[id] = x + width(kind) / 2
            x += width(kind) + 2
        }
        return result
    }

    static func center(_ id: String) -> CGPoint { CGPoint(x: centers[id] ?? Geo.midX, y: Geo.menuH / 2) }
}

// MARK: - En bildruta

/// Videons bild vid tiden `t` (sekunder). Ren funktion av tiden, så att samma vy kan spelas i appen och sparas som film.
struct TutorialFrame: View {
    let t: Double
    let script: TutorialScript

    private var source: VideoSource {
        if t >= 23.4 || t < 9.8 { return .none }
        return t < 12.0 ? .presentation : .document
    }
    private var sharing: Bool { source != .none }
    private var meetingShares: Bool { t >= 4.4 }
    private var cameraOn: Bool { t >= 16.1 }
    private var spotlight: Double { t >= 23.4 ? 0 : ramp(t, 17.5, 17.9) }
    /// Spotlightens mitt i dokumentfönstret (0–1), dit pekaren pekar.
    private var spotCenter: UnitPoint {
        let p = cursorPoint(t), r = Geo.winB
        return UnitPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }
    private var dockOpen: Double { t < 17 ? ramp(t, 15.0, 15.25) : 1 - ramp(t, 18.3, 18.55) }
    private var aFront: Bool { t >= 8.8 && t < 11.2 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            desktop
            windows.opacity(ramp(t, 7.4, 8.2))
            audienceLabel
            meeting
            menuBar
            dock
            keys
            caption
            cursor.opacity(1 - ramp(t, 25.1, 25.5))
            endCard.opacity(ramp(t, 25.5, 26.3))
            // Mjuk övergång när videon börjar om.
            Color.black.opacity(max(1 - ramp(t, 0, 0.5), ramp(t, 27.9, 28.5)))
        }
        .frame(width: Geo.canvas.width, height: Geo.canvas.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    // MARK: Skrivbord och menyrad

    private var desktop: some View {
        ZStack {
            LinearGradient(colors: [Palette.hex("#2B303A"), Palette.ink], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.amber.opacity(0.10), .clear], center: .init(x: 0.85, y: 0.15), startRadius: 0, endRadius: 520)
        }
        .frame(width: Geo.canvas.width, height: Geo.canvas.height)
    }

    private var menuBar: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.35)).frame(width: Geo.canvas.width, height: Geo.menuH)
            // Neutrala platshållare i stället för riktiga menyer.
            HStack(spacing: 18) {
                Circle().fill(Palette.light.opacity(0.75)).frame(width: 12, height: 12)
                ForEach([62, 38, 44, 52], id: \.self) { w in
                    Capsule().fill(Palette.light.opacity(0.35)).frame(width: CGFloat(w), height: 7)
                }
            }
            .frame(height: Geo.menuH)
            .padding(.leading, 18)
            HStack(spacing: 12) {
                menuBarIcon
                ForEach([16, 20], id: \.self) { w in
                    RoundedRectangle(cornerRadius: 3).fill(Palette.light.opacity(0.35)).frame(width: CGFloat(w), height: 10)
                }
                Text("10:00").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.light.opacity(0.8))
            }
            .frame(height: Geo.menuH)
            .frame(width: Geo.canvas.width - 18, alignment: .trailing)
        }
    }

    /// Appens menyradssymbol: det bakre fönstret i kontur och det främre i bärnsten, med röd punkt vid delning.
    private var menuBarIcon: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1.6).stroke(Palette.light, lineWidth: 1.4)
                .frame(width: 10, height: 7.5).offset(x: 1.5, y: 2)
            RoundedRectangle(cornerRadius: 1.6).fill(Palette.amber)
                .frame(width: 10.5, height: 8).offset(x: 6, y: 7.5)
            if sharing {
                Circle().fill(Palette.red).frame(width: 5, height: 5).offset(x: 12.7, y: 0.7)
            }
        }
        .frame(width: 18, height: 18, alignment: .topLeading)
    }

    // MARK: Snabbpanelen

    private var dock: some View {
        let open = dockOpen
        let tip = dockTip
        return ZStack(alignment: .topLeading) {
            // Ihopfälld: notchen med delningslampan till höger.
            HStack {
                Spacer()
                lampDot
            }
            .padding(.trailing, 10)
            .frame(width: Geo.notchW + 40, height: Geo.menuH)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black))
            .position(x: Geo.midX, y: Geo.menuH / 2)
            .opacity(1 - open)

            expandedDock
                .scaleEffect(x: 0.3 + 0.7 * open, y: 1, anchor: .center)
                .opacity(open)
                .position(x: Geo.midX, y: Geo.menuH / 2)

            if let tip {
                Text(tip.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.light)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.divider, lineWidth: 1))
                    .fixedSize()
                    .position(x: tip.x, y: Geo.menuH + 22)
                    .opacity(tip.opacity)
            }
        }
    }

    private var lampDot: some View {
        Circle().fill(sharing ? Palette.amber : Palette.divider).frame(width: 8, height: 8)
    }

    private var expandedDock: some View {
        let side = DockGeo.side
        return HStack(spacing: 0) {
            dockRow(DockGeo.left).frame(width: side, alignment: .trailing)
            Color.black.frame(width: Geo.notchW, height: Geo.menuH)
            dockRow(DockGeo.right).frame(width: side, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: Geo.menuH)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black))
        .fixedSize()
    }

    private func dockRow(_ row: [(String, DockGeo.Kind)]) -> some View {
        HStack(spacing: 2) {
            ForEach(row, id: \.0) { id, kind in
                switch kind {
                case .divider:
                    Rectangle().fill(Palette.divider).frame(width: 1, height: DockGeo.buttonSize.height * 0.6).padding(.horizontal, 3)
                case .lamp:
                    lampDot.frame(width: 20, height: DockGeo.buttonSize.height)
                case .button(let symbol, let activeSymbol):
                    let active = (id == "camera" && cameraOn) || (id == "spotlight" && spotlight > 0.5) || id == "preview"
                    let pressed = clicks.contains { abs(t - $0) < 0.1 } && hovered == id
                    Image(systemName: active && !activeSymbol.isEmpty ? activeSymbol : symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(id == "stop" ? Palette.red : (active ? Palette.amber : Palette.icon))
                        .frame(width: DockGeo.buttonSize.width, height: DockGeo.buttonSize.height)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovered == id ? 0.1 : 0)))
                        .scaleEffect(pressed ? 0.88 : 1)
                }
            }
        }
    }

    /// Knappen under pekaren i den utfällda panelen.
    private var hovered: String? {
        guard dockOpen > 0.9 else { return nil }
        let p = cursorPoint(t)
        guard p.y < Geo.menuH else { return nil }
        return DockGeo.centers.first { abs($0.value - p.x) < 14 }?.key
    }

    /// Hjälptexten som visas vid hovring, med samma texter som i appen.
    private var dockTip: (text: String, x: CGFloat, opacity: Double)? {
        if t >= 14.8 && t < 15.0 {
            return (L("Click for BetterScreenSharing", "Klicka för BetterScreenSharing"), Geo.midX, ramp(t, 14.8, 14.85))
        }
        switch hovered {
        case "camera": return (cameraOn ? L("Camera on", "Kamera på") : L("Camera off", "Kamera av"), DockGeo.center("camera").x, 1)
        case "spotlight": return ("Spotlight", DockGeo.center("spotlight").x, 1)
        default: return nil
        }
    }

    // MARK: Fönster på skrivbordet

    private var windows: some View {
        ZStack(alignment: .topLeading) {
            if aFront {
                placed(appWindow(.document, active: false), Geo.winB)
                placed(appWindow(.presentation, active: true), Geo.winA)
            } else {
                placed(appWindow(.presentation, active: false), Geo.winA)
                placed(appWindow(.document, active: true), Geo.winB)
                // Presentatören ser samma spotlight över det delade fönstret.
                if spotlight > 0 && source == .document {
                    spotlightDim(CGSize(width: Geo.winB.width, height: Geo.winB.height), center: spotCenter, radius: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(width: Geo.winB.width, height: Geo.winB.height)
                        .position(x: Geo.winB.midX, y: Geo.winB.midY)
                }
            }
        }
    }

    private func placed<V: View>(_ view: V, _ r: CGRect) -> some View {
        view.frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
    }

    // MARK: Mötesappen

    private var meetingRect: CGRect { lerp(Geo.meetingBig, Geo.meetingSmall, ramp(t, 7.0, 8.0)) }

    private var audienceLabel: some View {
        Label(L("What the meeting sees", "Det mötet ser"), systemImage: "person.2.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .fixedSize()
            .position(x: Geo.meetingSmall.midX, y: Geo.meetingSmall.minY - 14)
            .opacity(ramp(t, 7.8, 8.4))
    }

    private var meeting: some View {
        let r = meetingRect
        let s = r.width / Geo.meetingInner.width
        return meetingInner
            .frame(width: Geo.meetingInner.width, height: Geo.meetingInner.height)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .position(x: r.midX, y: r.midY)
            .opacity(t < 1 ? ramp(t, 0.2, 0.8) : 1)
    }

    private var meetingInner: some View {
        let inner = Geo.meetingInner
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Palette.hex("#191B20"))
            // Titelrad
            ZStack {
                HStack(spacing: 7) {
                    ForEach(0..<3) { _ in Circle().fill(Palette.hex("#4A4F5B")).frame(width: 10, height: 10) }
                    Spacer()
                }
                .padding(.leading, 12)
                Text(L("Meeting", "Möte")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .frame(width: inner.width, height: 28)
            .background(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12).fill(Palette.hex("#22252C")))

            meetingBody.frame(width: inner.width, height: 258).offset(y: 28)
            meetingToolbar.frame(width: inner.width, height: 44).offset(y: 286)
            picker
        }
        .frame(width: inner.width, height: inner.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    @ViewBuilder
    private var meetingBody: some View {
        if meetingShares {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.red).frame(width: 7, height: 7)
                    Text(L("You're sharing: \(script.stageName)", "Du delar: \(script.stageName)"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.icon)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                stage(CGSize(width: 384, height: 216))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.red.opacity(0.8), lineWidth: 1.5))
            }
            .opacity(ramp(t, 4.4, 4.8))
        } else {
            HStack(spacing: 10) {
                participant("A")
                participant("B")
            }
            .padding(14)
        }
    }

    private func participant(_ initial: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Palette.button)
            Circle().fill(Palette.back).frame(width: 64, height: 64)
            Image(systemName: "person.fill").font(.system(size: 30)).foregroundStyle(Palette.muted)
        }
    }

    private var meetingToolbar: some View {
        let sharePressed = abs(t - 1.8) < 0.1
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.hex("#22252C"))
            toolbarButton("mic.fill").position(x: 158, y: 22)
            toolbarButton("video.fill").position(x: 202, y: 22)
            HStack(spacing: 5) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 12, weight: .semibold))
                Text(L("Share", "Dela")).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(meetingShares ? Color.black : Palette.icon)
            .frame(width: 72, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(meetingShares ? Palette.amber : Palette.button))
            .scaleEffect(sharePressed ? 0.92 : 1)
            .position(x: Geo.shareButton.x, y: 22)
            Image(systemName: "phone.down.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(width: 44, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.red))
                .position(x: 320, y: 22)
        }
    }

    private func toolbarButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(Palette.icon)
            .frame(width: 34, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.button))
    }

    /// Mötesappens ruta för att välja vad som delas.
    private var picker: some View {
        let shown = t < 4.4 ? ramp(t, 2.0, 2.3) : 1 - ramp(t, 4.4, 4.6)
        let selected = t >= 3.2
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.45 * shown).frame(width: Geo.meetingInner.width, height: Geo.meetingInner.height)
            VStack(spacing: 0) {
                Text(L("Choose what to share", "Välj vad du vill dela"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.icon)
                    .padding(.top, 14)
                HStack(spacing: 40) {
                    thumb(script.otherChoice, stage: false, selected: false)
                    thumb(script.stageName, stage: true, selected: selected)
                }
                .padding(.top, 14)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Spacer()
                    Text(L("Cancel", "Avbryt")).font(.system(size: 12)).foregroundStyle(Palette.icon)
                        .frame(width: 64, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.button))
                    Text(L("Share", "Dela")).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.black : Palette.muted)
                        .frame(width: 64, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Palette.amber : Palette.button))
                        .scaleEffect(abs(t - 4.3) < 0.1 ? 0.92 : 1)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
            }
            .frame(width: 380, height: 214)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .scaleEffect(0.94 + 0.06 * shown)
            .offset(x: 40, y: 46)
            .opacity(shown)
        }
        .allowsHitTesting(false)
    }

    private func thumb(_ title: String, stage: Bool, selected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(stage ? Palette.ink : Palette.hex("#2B303A"))
                if stage {
                    // Scenen: appens två fönster, som i ikonen.
                    RoundedRectangle(cornerRadius: 3).fill(Palette.back).frame(width: 46, height: 32).offset(x: -10, y: -8)
                    RoundedRectangle(cornerRadius: 3).fill(Palette.amber).frame(width: 48, height: 34).offset(x: 10, y: 8)
                } else {
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.black.opacity(0.4)).frame(height: 6)
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 3).fill(Palette.light.opacity(0.8)).frame(width: 60, height: 38).offset(x: -12, y: 4)
                }
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Palette.amber : Color.white.opacity(0.12), lineWidth: selected ? 2.5 : 1).padding(-2))
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.amber : Palette.muted)
                .lineLimit(1)
                .frame(width: 170)
        }
    }

    // MARK: Scenen

    /// Det som delas: källan, kamerabubblan och spotlighten, eller meddelandet när inget delas.
    private func stage(_ size: CGSize) -> some View {
        ZStack {
            Palette.back
            switch source {
            case .none:
                Text(Phrase.nothingShared.text)
                    .font(.system(size: size.height * 0.085, weight: .semibold))
                    .foregroundStyle(Palette.light)
            case .presentation, .document:
                let h = size.height * 0.94, w = h * 380 / 250
                appWindow(source == .presentation ? .presentation : .document, active: true)
                    .frame(width: 380, height: 250)
                    .scaleEffect(w / 380)
                    .frame(width: w, height: h)
                if spotlight > 0 {
                    // Samma punkt i fönstret som pekaren, omräknad till fönstrets plats på scenen.
                    let c = spotCenter
                    spotlightDim(size, center: UnitPoint(x: (size.width - w) / 2 / size.width + c.x * w / size.width,
                                                         y: (size.height - h) / 2 / size.height + c.y * h / size.height),
                                 radius: 72 * w / 380)
                }
            }
            if cameraOn {
                cameraBubble(size.height * 0.3)
                    .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
                    .padding(size.height * 0.05)
                    .scaleEffect(0.6 + 0.4 * ramp(t, 16.1, 16.4), anchor: .bottomTrailing)
                    .opacity(ramp(t, 16.1, 16.3))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Dimning runt en mjuk, ljus cirkel, som appens spotlight. `center` är relativ till ytan.
    private func spotlightDim(_ size: CGSize, center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.78),
                               .init(color: .black.opacity(0.62), location: 1)],
                       center: center, startRadius: 0, endRadius: radius)
            .frame(width: size.width, height: size.height)
            .opacity(spotlight)
            .allowsHitTesting(false)
    }

    private func cameraBubble(_ d: CGFloat) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Palette.hex("#5A6070"), Palette.back], startPoint: .top, endPoint: .bottom))
            Image(systemName: "person.fill").font(.system(size: d * 0.55)).foregroundStyle(Palette.light.opacity(0.85)).offset(y: d * 0.08)
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: max(1, d * 0.03)))
    }

    // MARK: Vanliga appfönster (påhittade, utan varumärken)

    private enum WindowKind { case presentation, document }

    private func appWindow(_ kind: WindowKind, active: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { _ in Circle().fill(Palette.hex(active ? "#B9BCC4" : "#D3D5DA")).frame(width: 9, height: 9) }
                    Spacer()
                }
                .padding(.leading, 10)
                Text(kind == .presentation ? L("Presentation", "Presentation") : L("Document", "Dokument"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.back.opacity(active ? 1 : 0.6))
            }
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(Palette.hex("#E4E5E9"))
            Group {
                switch kind {
                case .presentation: presentationContent
                case .document: documentContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.hex(kind == .presentation ? "#EDF2FC" : "#ECF7F1"))
        }
        .frame(width: 380, height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .compositingGroup()
        .shadow(color: .black.opacity(active ? 0.45 : 0.25), radius: active ? 16 : 8, y: 6)
    }

    private var presentationContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 3).fill(Palette.hex("#2F5BB7")).frame(width: 150, height: 12)
            HStack(alignment: .bottom, spacing: 18) {
                ForEach(Array([0.35, 0.55, 0.45, 0.8, 0.95].enumerated()), id: \.offset) { i, h in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.hex(i >= 3 ? "#3F6FD6" : "#9DB8F2"))
                        .frame(width: 38, height: 150 * h)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            Rectangle().fill(Palette.hex("#D3D5DA")).frame(height: 1)
        }
        .padding(20)
    }

    private var documentContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 3).fill(Palette.hex("#1B7F50")).frame(width: 130, height: 12).padding(.bottom, 4)
                ForEach(Array([1.0, 0.92, 0.97, 0.7, 1.0, 0.85, 0.6].enumerated()), id: \.offset) { _, w in
                    RoundedRectangle(cornerRadius: 2).fill(Palette.hex("#B9BCC4")).frame(width: 200 * w, height: 7)
                }
            }
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Palette.hex("#3CC985"), Palette.hex("#1E9A5E")], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 110, height: 80)
                .overlay(Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(Color.white.opacity(0.9)))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Tangenter

    private var keys: some View {
        let presses: [(Double, [String])] = [(9.8, script.shareKeys), (12.0, script.shareKeys), (23.4, script.stopKeys)]
        return ZStack {
            ForEach(Array(presses.enumerated()), id: \.offset) { _, press in
                let (at, parts) = press
                let shown = t < at ? ramp(t, at - 0.6, at - 0.35) : 1 - ramp(t, at + 0.8, at + 1.05)
                if shown > 0 {
                    HStack(spacing: 8) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            VideoKey(text: part, pressed: t >= at && t < at + 0.22, lit: t >= at)
                        }
                    }
                    .opacity(shown)
                    .scaleEffect(0.9 + 0.1 * shown)
                }
            }
        }
        .position(x: Geo.midX, y: 470)
    }

    // MARK: Text

    @ViewBuilder
    private var caption: some View {
        if let index = TutorialScript.chapters.firstIndex(where: { t >= $0.start && t < $0.end }) {
            let chapter = TutorialScript.chapters[index]
            let text = script.captions[index]
            let opacity = min(ramp(t, chapter.start, chapter.start + 0.35), 1 - ramp(t, chapter.end - 0.35, chapter.end))
            HStack(spacing: 14) {
                Text("\(index + 1)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Palette.amber))
                VStack(alignment: .leading, spacing: 3) {
                    Text(text.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.light)
                    Text(text.detail).font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.panel.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .position(x: Geo.midX, y: 552)
            .opacity(opacity)
        }
    }

    // MARK: Pekare

    private var cursor: some View {
        let p = cursorPoint(t)
        let down = clicks.contains { t >= $0 - 0.05 && t < $0 + 0.12 }
        return ZStack(alignment: .topLeading) {
            ForEach(clicks.filter { t >= $0 && t < $0 + 0.5 }, id: \.self) { c in
                let k = (t - c) / 0.5
                let q = cursorPoint(c)
                Circle()
                    .stroke(Palette.amber, lineWidth: 2.5)
                    .frame(width: 12 + 38 * k, height: 12 + 38 * k)
                    .opacity(1 - k)
                    .position(q)
            }
            CursorArrow()
                .fill(Color.white)
                .overlay(CursorArrow().stroke(Color.black, lineWidth: 1.2))
                .frame(width: 13, height: 21)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .scaleEffect(down ? 0.85 : 1, anchor: .topLeading)
                .position(x: p.x + 6.5, y: p.y + 10.5)
        }
        .frame(width: Geo.canvas.width, height: Geo.canvas.height, alignment: .topLeading)
    }

    // MARK: Slutbild

    private var endCard: some View {
        ZStack {
            LinearGradient(colors: [Palette.hex("#2B303A"), Palette.ink], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                if let icon = AppIcon.cgImage(pixels: 256) {
                    Image(decorative: icon, scale: 1).resizable().frame(width: 120, height: 120)
                }
                Text("BetterScreenSharing").font(.system(size: 30, weight: .bold)).foregroundStyle(Palette.light)
                Text(L("You're ready to share.", "Nu är du redo att dela.")).font(.system(size: 16)).foregroundStyle(Palette.muted)
            }
        }
        .frame(width: Geo.canvas.width, height: Geo.canvas.height)
    }
}

/// En tangent ritad som en fysisk tangent, som i guiden för kortkommandon men i videons mörka färger.
private struct VideoKey: View {
    let text: String
    let pressed: Bool
    let lit: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Text(text)
            .font(.system(size: 28, weight: .medium, design: .rounded))
            .foregroundStyle(lit ? Palette.amber : Palette.light)
            .frame(minWidth: 60, minHeight: 60)
            .padding(.horizontal, text.count > 1 ? 10 : 0)
            .background(shape.fill(Palette.button))
            .overlay(shape.strokeBorder(lit ? Palette.amber.opacity(0.8) : Color.white.opacity(0.15), lineWidth: lit ? 1.5 : 1))
            .background(shape.fill(Color.black.opacity(0.6)).offset(y: pressed ? 0 : 4))
            .offset(y: pressed ? 4 : 0)
    }
}

private struct CursorArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 13, sy = rect.height / 21
        var p = Path()
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 20), (9.8, 18.9), (6.9, 12.4), (12.5, 12.4)]
        p.move(to: CGPoint(x: points[0].0 * sx, y: points[0].1 * sy))
        for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.0 * sx, y: pt.1 * sy)) }
        p.closeSubpath()
        return p
    }
}

// MARK: - Spelaren

/// Spelar videon i en loop, med kapitel att hoppa mellan, paus och en knapp för att gå vidare.
struct TutorialPlayerView: View {
    let script: TutorialScript
    var doneTitle: String = L("Done", "Klar")
    var onDone: () -> Void = {}

    @State private var start = Date()
    /// Tiden där videon står still, eller nil när den spelas.
    @State private var pausedAt: Double?
    private let scale: CGFloat = 0.75

    var body: some View {
        TimelineView(.animation(paused: pausedAt != nil)) { context in
            let t = pausedAt ?? context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: TutorialScript.duration)
            VStack(spacing: 14) {
                TutorialFrame(t: t, script: script)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: Geo.canvas.width * scale, height: Geo.canvas.height * scale, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement()
                    .accessibilityLabel(L("Animation showing how to share with BetterScreenSharing", "Animation som visar hur du delar med BetterScreenSharing"))
                    .onTapGesture { togglePause(t) }
                controls(t)
            }
        }
        .padding(20)
    }

    private func controls(_ t: Double) -> some View {
        HStack(spacing: 14) {
            Button { togglePause(t) } label: {
                Image(systemName: pausedAt == nil ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(pausedAt == nil ? L("Pause", "Pausa") : L("Play", "Spela"))

            HStack(spacing: 6) {
                ForEach(Array(TutorialScript.chapters.enumerated()), id: \.offset) { i, chapter in
                    let progress = clamp((t - chapter.start) / (chapter.end - chapter.start))
                    Button { jump(to: chapter.start) } label: {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.15))
                            Capsule().fill(Palette.amber).frame(width: 90 * progress)
                        }
                        .frame(width: 90, height: 5)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(script.captions[i].title)
                    .accessibilityLabel(L("Step \(i + 1): \(script.captions[i].title)", "Steg \(i + 1): \(script.captions[i].title)"))
                }
            }
            Spacer()
            Button(doneTitle) { onDone() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func togglePause(_ t: Double) {
        if let paused = pausedAt {
            start = Date().addingTimeInterval(-paused)
            pausedAt = nil
        } else {
            pausedAt = t
        }
    }

    private func jump(to time: Double) {
        if pausedAt != nil { pausedAt = time } else { start = Date().addingTimeInterval(-time) }
    }
}

/// Fönstret med videon. Visas vid första starten, före guiden för kortkommandon, och från kontrollpanelen.
@MainActor
final class TutorialVideo: NSObject, NSWindowDelegate {
    static let shared = TutorialVideo()

    private var window: NSWindow?
    private weak var state: AppState?
    private var onClose: (() -> Void)?

    /// `next` är texten på knappen som stänger rutan (t.ex. "Fortsätt" när guiden för kortkommandon kommer efter).
    func show(state: AppState, next: String? = nil, onClose: (() -> Void)? = nil) {
        self.state = state
        self.onClose = onClose
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("How to share", "Så delar du")
        w.isReleasedWhenClosed = false
        w.delegate = self
        let view = TutorialPlayerView(script: .current(state), doneTitle: next ?? L("Done", "Klar")) { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingView(rootView: view)
        w.contentView = hosting
        w.setContentSize(hosting.fittingSize)
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        state?.tutorialShown = true
        let next = onClose
        onClose = nil
        // Nästa fönster öppnas när det här har stängts klart.
        DispatchQueue.main.async { next?() }
    }
}

// MARK: - Export

/// `--write-tutorial-video <fil.mp4> [en|sv]`: sparar videon som H.264, 1920 × 1200, 30 bilder per sekund.
@MainActor
enum TutorialExport {
    static func write(to url: URL, language: AppLanguage, fps: Int = 30, scale: CGFloat = 2) throws {
        Lang.current = language
        let script = TutorialScript.standard
        let width = Int(Geo.canvas.width * scale), height = Int(Geo.canvas.height * scale)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(TutorialScript.duration * Double(fps))
        for i in 0..<frames {
            let t = Double(i) / Double(fps)
            let renderer = ImageRenderer(content: TutorialFrame(t: t, script: script))
            renderer.scale = scale
            guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Enstaka bilder ur videon, för att granska den (används av `--render-ui`).
    static func writeStill(at t: Double, to url: URL) throws {
        let renderer = ImageRenderer(content: TutorialFrame(t: t, script: .standard))
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
