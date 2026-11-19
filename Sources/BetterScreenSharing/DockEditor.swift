import SwiftUI

/// Pågående dragning i redigeraren (vyerna kan inte ha eget @State utan Xcode).
@MainActor
final class DockEditorModel: ObservableObject {
    static let shared = DockEditorModel()
    enum Origin: Equatable { case panel(Int), palette(DockTool) }
    @Published var dragging: Origin?
    @Published var location: CGPoint = .zero
    /// Verktyget i panelen som pekaren vilar över, för etiketten ovanför.
    @Published var hovered: Int?
    var panelFrame: CGRect = .zero
}

/// Snabbpanelen som den ser ut, där verktygen dras för att ändra ordning. Kortet som dras puttar undan de andra
/// medan det hovrar, nya dras in från paletten och ett verktyg som dras ner till paletten tas bort.
struct DockEditor: View {
    @ObservedObject var state: AppState
    @ObservedObject var model = DockEditorModel.shared

    private static let space = "dockEditor"
    private static let padding: CGFloat = 12
    private static let maxPitch: CGFloat = 40
    private static let panelHeight: CGFloat = 52
    private static let amber = Color(nsColor: NSColor(hex: "#FFB020")!)
    private static let red = Color(nsColor: NSColor(hex: "#FF6B5E")!)
    private static let icon = Color(nsColor: NSColor(hex: "#E6E8EC")!)
    private static let tile = Color(nsColor: NSColor(hex: "#1B1D23")!)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Drag the tools in the panel to change their order. Drag more in from the list below, and drag a tool down to the list to remove it.", "Dra verktygen i panelen för att ändra ordningen. Dra in fler från listan nedanför, och dra ner ett verktyg till listan för att ta bort det."))
                .font(.caption)
                .foregroundStyle(.secondary)
            panel
            Text(L("Available tools", "Tillgängliga verktyg")).font(.subheadline.weight(.semibold))
            palette
            HStack(alignment: .top) {
                Text(L("The notch marks where the panel splits when it sits around the notch; in other positions it does nothing.", "Notchen visar var panelen delas när den sitter runt notchen; i övriga lägen gör den ingenting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Reset", "Återställ")) { state.dockLayout = DockTool.defaultLayout }
            }
        }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) {
            if let tool = draggedTool {
                face(tool, size: 40)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.85)))
                    .shadow(radius: 6)
                    .position(model.location)
                    .allowsHitTesting(false)
            }
        }
    }

    private var draggedTool: DockTool? {
        switch model.dragging {
        case .panel(let i): state.dockLayout.indices.contains(i) ? state.dockLayout[i] : nil
        case .palette(let tool): tool
        case nil: nil
        }
    }

    private var draggedIndex: Int? {
        if case .panel(let i) = model.dragging { return i }
        return nil
    }

    // MARK: Panelen

    /// Avstånd mellan verktygen, så att hela panelen alltid får plats på en rad, som den riktiga.
    private func pitch(width: CGFloat) -> CGFloat {
        let others = state.dockLayout.count - (draggedIndex == nil ? 0 : 1)
        let slots = others + (model.dragging == nil ? 0 : 1)
        return min(Self.maxPitch, (width - Self.padding * 2) / CGFloat(max(slots, 1)))
    }

    /// Var det dragna verktyget skulle hamna, räknat bland de övriga, eller nil om pekaren inte är över panelen.
    private func insertion(pitch: CGFloat) -> Int? {
        guard model.dragging != nil, model.panelFrame.insetBy(dx: -12, dy: -28).contains(model.location) else { return nil }
        let others = state.dockLayout.count - (draggedIndex == nil ? 0 : 1)
        let x = model.location.x - model.panelFrame.minX - Self.padding - pitch / 2
        return min(max(Int((x / pitch).rounded()), 0), others)
    }

    private var panel: some View {
        GeometryReader { geo in
            let pitch = pitch(width: geo.size.width)
            let gap = insertion(pitch: pitch)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14).fill(Color.black)
                ForEach(Array(state.dockLayout.enumerated()), id: \.offset) { index, tool in
                    let order = index - (draggedIndex.map { $0 < index ? 1 : 0 } ?? 0)
                    let position = gap.map { order >= $0 ? order + 1 : order } ?? order
                    face(tool, size: pitch)
                        .frame(width: pitch, height: Self.panelHeight)
                        .contentShape(Rectangle())
                        // Det dragna verktyget ligger kvar osynligt, så att dragningen inte avbryts.
                        .opacity(draggedIndex == index ? 0 : 1)
                        .offset(x: Self.padding + CGFloat(position) * pitch)
                        .animation(.easeInOut(duration: 0.15), value: gap)
                        .gesture(drag(.panel(index)))
                        .onHover { inside in
                            if inside { model.hovered = index } else if model.hovered == index { model.hovered = nil }
                        }
                }
                if model.dragging == nil, let hovered = model.hovered, state.dockLayout.indices.contains(hovered) {
                    label(state.dockLayout[hovered])
                        .position(x: Self.padding + (CGFloat(hovered) + 0.5) * pitch, y: -18)
                }
            }
            .onAppear { model.panelFrame = geo.frame(in: .named(Self.space)) }
            .onChange(of: geo.frame(in: .named(Self.space))) { frame in model.panelFrame = frame }
        }
        .frame(height: Self.panelHeight)
    }

    // MARK: Paletten

    private var palette: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
            ForEach(DockTool.allCases.filter { $0.repeatable || !state.dockLayout.contains($0) }) { tool in
                HStack(spacing: 8) {
                    face(tool, size: 28).frame(width: 28, height: 28)
                    Text(tool.label).font(.system(size: 11)).foregroundStyle(Self.icon).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Self.tile))
                .contentShape(Rectangle())
                .gesture(drag(.palette(tool)))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(model.dragging == nil ? 0.08 : 0.16)))
    }

    // MARK: Dragning

    private func drag(_ origin: DockEditorModel.Origin) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if model.dragging == nil { model.dragging = origin }
                model.location = value.location
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        defer { model.dragging = nil }
        var layout = state.dockLayout
        let gap = insertion(pitch: pitch(width: model.panelFrame.width))
        switch model.dragging {
        case .panel(let i):
            guard layout.indices.contains(i) else { return }
            if let gap {
                let tool = layout.remove(at: i)
                layout.insert(tool, at: min(gap, layout.count))
            } else if model.location.y > model.panelFrame.maxY + 24 {
                // Nerdraget till paletten: ta bort.
                layout.remove(at: i)
            }
        case .palette(let tool):
            guard let gap, tool.repeatable || !layout.contains(tool) else { return }
            layout.insert(tool, at: min(gap, layout.count))
        case nil:
            return
        }
        if layout != state.dockLayout { state.dockLayout = layout }
    }

    // MARK: Utseende

    /// Etiketten som visas ovanför verktyget pekaren vilar över.
    private func label(_ tool: DockTool) -> some View {
        Text(tool.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Self.icon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Self.tile))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .allowsHitTesting(false)
    }

    /// Verktyget som det ser ut i den riktiga panelen.
    @ViewBuilder
    private func face(_ tool: DockTool, size: CGFloat) -> some View {
        let iconSize = min(17, size * 0.45)
        switch tool {
        case .divider:
            // Lodrät, som i panelen.
            Rectangle().fill(Color(white: 0.32)).frame(width: 1, height: min(24, size * 0.6))
        case .slots:
            HStack(spacing: 1) {
                ForEach(1...3, id: \.self) { n in
                    Text("\(n)").font(.system(size: max(7, iconSize * 0.62), weight: .semibold))
                        .frame(width: max(8, size * 0.24), height: max(12, size * 0.4))
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.2)))
                }
            }
            .foregroundStyle(Self.icon)
        case .lamp:
            Circle().fill(Self.amber).frame(width: 8, height: 8)
        case .notch:
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Self.amber, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: size * 0.7, height: min(22, size * 0.55))
        default:
            Image(systemName: tool.symbol)
                .font(.system(size: iconSize))
                .foregroundStyle(tool == .stop ? Self.red : Self.icon)
        }
    }
}
