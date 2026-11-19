import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var state: AppState
    let controller: AppController

    /// " (⌃⌥K)" efter en etikett, eller tomt om funktionen saknar genväg.
    private func k(_ action: HotkeyAction) -> String {
        state.keys(action).map { " (\($0))" } ?? ""
    }

    var body: some View {
        NavigationSplitView {
            List(PanelSection.allCases, selection: $state.panelSection) { section in
                Label(section.label, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                banners
                detail(state.panelSection ?? .general)
            }
            // Innehållet följer fönstrets storlek.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle((state.panelSection ?? .general).label)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder
    private var banners: some View {
        if state.screenPermissionMissing {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("The app needs permission to record the screen.", "Appen behöver behörighet för skärminspelning."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L("Turn on BetterScreenSharing in System Settings › Privacy & Security › Screen & System Audio Recording, then restart the app.", "Slå på BetterScreenSharing under Systeminställningar › Integritet och säkerhet › Skärm- och ljudinspelning och starta sedan om appen."))
                    .font(.callout)
                Button(L("Open System Settings", "Öppna Systeminställningar")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.12))
        }
        if let msg = state.statusMessage {
            HStack {
                Text(msg).font(.callout)
                Spacer()
                Button("OK") { state.statusMessage = nil }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1))
        }
    }

    @ViewBuilder
    private func detail(_ section: PanelSection) -> some View {
        switch section {
        case .general: generalPage
        case .camera: Form { cameraPreview; cameraSection }.formStyle(.grouped)
        case .effects: Form { effectsPreview; effectsSection }.formStyle(.grouped)
        case .dock: Form { dockSection; slotsSection; dockEditorSection }.formStyle(.grouped)
        case .countdown: Form { countdownSection }.formStyle(.grouped)
        case .messages: Form { messagesPreview; messagesSection; textSection }.formStyle(.grouped)
        case .shortcuts: Form { hotkeySection }.formStyle(.grouped)
        }
    }

    // MARK: Förhandsvisningar

    /// Kameran som publiken ser just nu, eller nil om den är avslagen.
    private var visibleCamera: CameraSettings? { state.camera.enabled ? state.camera : nil }

    private func previewBox(_ preview: StagePreview) -> some View {
        preview
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .allowsHitTesting(preview.interactive)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
    }

    private func previewSection(_ preview: StagePreview, caption: String? = nil) -> some View {
        Section(L("Preview", "Förhandsvisning")) {
            previewBox(preview)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var cameraPreview: some View {
        // Formen och placeringen visas även när kameran är avslagen, så att den går att ställa in i förväg.
        previewSection(StagePreview(background: state.stageBackground, camera: state.camera, interactive: true, controller: controller),
                       caption: state.camera.enabled ? nil : L("The camera is off and isn't visible in the share. This shows how it will look.", "Kameran är avslagen och syns inte i delningen. Här visas hur den kommer att se ut."))
    }

    private var effectsPreview: some View {
        var effects = state.effects
        if effects.mode == .rect && effects.rect == nil {
            effects.rect = CGRect(x: 0.06, y: 0.16, width: 0.5, height: 0.2)
        }
        return previewSection(StagePreview(background: state.stageBackground, camera: visibleCamera, effects: effects,
                                           spotlightCenter: effects.mode == .spotlight ? CGPoint(x: 0.42, y: 0.4) : nil,
                                           interactive: true, controller: controller),
                              caption: effects.mode == .off ? L("Choose Rectangle or Spotlight to see the effect.", "Välj Rektangel eller Spotlight för att se effekten.") : nil)
    }

    private var messagesPreview: some View {
        let message = state.idleMessage(for: state.editingIdleReason)
        return previewSection(StagePreview(background: state.stageBackground, camera: visibleCamera, idle: message, controller: controller),
                              caption: message.content == .lastFrame ? L("A sample window is shown here instead of the last frame.", "Här visas ett exempelfönster i stället för den senaste bilden.") : nil)
    }

    private var textSection: some View {
        Section(L("Text on stage", "Text på scenen") + k(.toggleText)) {
            previewBox(StagePreview(background: state.stageBackground, camera: visibleCamera,
                                    textCard: state.textMessage.isEmpty ? L("Type a text below", "Skriv en text nedan") : state.textMessage,
                                    controller: controller))
            TextField(L("Text", "Text"), text: $state.textMessage, prompt: Text(L("Type a text to show on the stage", "Skriv en text att visa på scenen")))
            Toggle(L("Show the text now", "Visa texten nu"), isOn: $state.textShown)
                .disabled(state.textMessage.trimmingCharacters(in: .whitespaces).isEmpty && !state.textShown)
            Text(L("A card across the whole stage, in the same style as the message when nothing is shared. You can also type the text directly in the quick panel. The camera shows on top. Sharing something, Stop sharing or Clear the stage removes the text.", "En ruta över hela scenen, i samma stil som meddelandet när inget delas. Texten kan också skrivas direkt i snabbpanelen. Kameran syns ovanpå. Att dela något, Sluta dela eller Rensa scenen tar bort texten."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Allmänt

    /// Startsidan: vad som delas just nu, hur scenen delas i mötesappen, snabbval och bild.
    private var generalPage: some View {
        Form {
            shareSection
            languageSection
            imageSection
            audioSection
            settingsSection
        }
        .formStyle(.grouped)
        .task { await controller.refreshSources() }
    }

    private var shareSection: some View {
        Section(L("Share in the meeting app", "Dela i mötesappen")) {
            Picker(L("Show the stage in", "Visa scenen i"), selection: $state.stageMode) {
                ForEach(StageMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if state.stageMode == .virtualDisplay {
                Picker(L("In the meeting app you share", "I mötesappen delar du"), selection: $state.shareTarget) {
                    ForEach(ShareTarget.allCases) { Text($0.label).tag($0) }
                }
            }
            Text(.init(shareInstructions))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Watch how it works…", "Se hur det fungerar…")) { controller.showTutorial() }
            switch state.stageMode {
            case .virtualDisplay:
                Picker(L("Resolution", "Upplösning"), selection: $state.virtualResolution) {
                    ForEach(VirtualResolution.allCases) { Text($0.label).tag($0) }
                }
                strayWindowsRow
            case .window:
                HStack {
                    Button(L("Show stage window", "Visa scenfönster")) { controller.showStage() }
                    Menu(L("Size", "Storlek")) {
                        ForEach(VirtualResolution.allCases) { r in
                            Button(r.label) { controller.setStageSize(r.size) }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private var strayWindowsRow: some View {
        Toggle(L("Move windows off the stage display", "Flytta bort fönster från scenskärmen"), isOn: $state.moveStrayWindows)
        Text(L("Windows that land on the invisible display are moved to the screen you're using, so they don't end up out of reach or in the share.",
               "Fönster som hamnar på den osynliga skärmen flyttas till skärmen du använder, så att de inte blir oåtkomliga eller syns i delningen."))
            .font(.caption)
            .foregroundStyle(.secondary)
        if state.moveStrayWindows && !state.accessibilityGranted {
            VStack(alignment: .leading, spacing: 6) {
                Label(state.strayWindowCount > 0
                      ? L("\(state.strayWindowCount) window(s) on the stage display. Moving them needs the Accessibility permission.",
                          "\(state.strayWindowCount) fönster på scenskärmen. För att flytta dem behövs behörigheten Hjälpmedel.")
                      : L("Moving windows needs the Accessibility permission.", "För att flytta fönster behövs behörigheten Hjälpmedel."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(L("Allow Accessibility", "Tillåt Hjälpmedel")) { controller.requestAccessibilityPermission() }
            }
        }
    }

    private var imageSection: some View {
        Section(L("Picture", "Bild")) {
            previewBox(StagePreview(background: state.stageBackground, camera: visibleCamera, controller: controller))
            ColorPicker(L("Background (shown around windows that don't fill the stage)", "Bakgrund (syns runt fönster som inte fyller scenen)"), selection: colorBinding($state.stageBackground), supportsOpacity: false)
            Picker(L("Frame rate", "Bildfrekvens"), selection: $state.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            LabeledContent(L("Measured", "Uppmätt")) {
                FPSText(stats: state.frameStats, sharing: state.activeSource != nil, previewOn: state.showPreview)
            }
        }
    }

    // MARK: Översikt

    private static let amber = Color(nsColor: NSColor(hex: "#FFB020")!)
    private static let amberBorder = Color(nsColor: NSColor(hex: "#E09400")!)

    /// En plats som kort. Kortet delar ingenting när man klickar; det görs med kortkommandon eller snabbpanelen.
    /// Här går platsen bara att flytta och ta bort.
    private func slotCard(_ i: Int, _ s: Source) -> some View {
        let active = state.activeSlot == i
        let top = "\(i + 1)\(state.keys(.showSlot(i)).map { " · \($0)" } ?? "")"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(active ? L("\(top) · Sharing", "\(top) · Delas") : top)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(active ? Self.amberBorder : .secondary)
                Spacer(minLength: 4)
                Menu {
                    slotMenu(i)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text(s.appName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(s.title.isEmpty ? " " : s.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(active ? Self.amber.opacity(0.14) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Self.amberBorder : Color.secondary.opacity(0.25), lineWidth: active ? 2 : 1))
        .contentShape(Rectangle())
        .contextMenu { slotMenu(i) }
    }

    @ViewBuilder
    private func slotMenu(_ i: Int) -> some View {
        Button(L("Move up", "Flytta upp")) { controller.moveSlot(i, by: -1) }.disabled(i == 0)
        Button(L("Move down", "Flytta ner")) { controller.moveSlot(i, by: 1) }.disabled(i == AppState.slotCount - 1)
        Menu(L("Move to slot", "Flytta till plats")) {
            ForEach(0..<AppState.slotCount, id: \.self) { j in
                Button("\(j + 1)\(state.slots[j] != nil && j != i ? L(" (swap)", " (byt)") : "")") {
                    controller.moveSlot(i, by: j - i)
                }
            }
        }
        Divider()
        Button(L("Remove", "Ta bort"), role: .destructive) { controller.removeSlot(i) }
    }

    /// Gäller alla mötesappar; Teams och Zoom står som exempel.
    private var shareInstructions: String {
        switch (state.stageMode, state.shareTarget) {
        case (.virtualDisplay, .window):
            L("Share the window **\(AppController.stageTitle)**, for example in Teams: Share › Window. The stage sits below the invisible display's menu bar; if you share the entire screen instead, the menu bar shows, so then choose Entire screen above.",
              "Dela fönstret **\(AppController.stageTitle)**, till exempel i Teams: Dela › Fönster. Scenen ligger under den osynliga skärmens menyrad; delar du hela skärmen i stället syns menyraden, så välj då Hela skärmen ovan.")
        case (.virtualDisplay, .screen):
            L("Share the screen **\(VirtualDisplayManager.displayName)**, for example in Teams: Share › Screen, or in Zoom: Share Screen. The stage covers the whole invisible display, including the menu bar, so you have no windows to keep open.",
              "Dela skärmen **\(VirtualDisplayManager.displayName)**, till exempel i Teams: Dela › Skärm, eller i Zoom: Dela skärm. Scenen täcker hela den osynliga skärmen, även menyraden, så du har inga fönster att hålla öppna.")
        case (.window, _):
            L("Share the window **\(AppController.stageTitle)**, for example in Teams: Share › Window. The stage window may sit behind other windows but must not be minimized.",
              "Dela fönstret **\(AppController.stageTitle)**, till exempel i Teams: Dela › Fönster. Scenfönstret får ligga bakom andra fönster men inte vara minimerat.")
        }
    }

    // MARK: Snabbpanel

    private var dockSection: some View {
        Section(L("Quick panel", "Snabbpanel")) {
            Picker(L("Position", "Placering"), selection: $state.dockPosition) {
                ForEach(DockPosition.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(dockDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            if state.dockPosition != .off {
                Toggle(L("Always expanded (can't be collapsed)", "Visa alltid utfälld (går inte att fälla ihop)"), isOn: $state.dockPinned)
            }
            if state.dockPosition != .off {
                Toggle(L("Show the preview next to the expanded panel", "Visa förhandsvisningen bredvid den utfällda panelen"), isOn: $state.previewDocked)
                if state.previewDocked {
                    Picker(L("Size", "Storlek"), selection: $state.previewCompact) {
                        Text(state.dockPosition.atNotch ? L("Small, in line with the menu bar", "Liten, i linje med menyn") : L("Small", "Liten")).tag(true)
                        Text(L("Large", "Stor")).tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Text(L("The preview is then attached to the panel and shows when you expand it, as a quick check of what's being shared. Detach makes it a separate window you can move and resize.", "Förhandsvisningen sitter då ihop med panelen och syns när du fäller ut den, som en snabb kontroll av vad som delas. Med Frigör blir den ett eget fönster som går att flytta och ändra storlek på."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L("The panel never shows in the share. Hover over a button to see what it does and its shortcut.", "Panelen syns aldrig i delningen. Håll pekaren över en knapp för att se vad den gör och dess kortkommando."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Anpassa snabbpanelen

    private var dockEditorSection: some View {
        Section(L("Customize the quick panel", "Anpassa snabbpanelen")) {
            DockEditor(state: state)
        }
    }

    private var dockDescription: String {
        switch state.dockPosition {
        case .right, .left: L("A tab at the edge. Click to expand the panel and click again to collapse it. Drag the tab up or down to move it.", "En flik vid kanten. Klicka för att fälla ut panelen och klicka igen för att fälla in den. Dra fliken uppåt eller nedåt för att flytta den.")
        case .notch: L("The panel is attached to the notch. Click the notch to drop the panel down and again to fold it up. Without a notch it sits in the middle of the top edge.", "Panelen sitter ihop med notchen. Klicka på notchen för att fälla ner panelen och igen för att fälla upp den. Utan notch hamnar den mitt i överkanten.")
        case .aroundNotch: L("The buttons sit to the left and right of the notch, at menu bar height, so the panel takes as little space as possible. Click the notch to expand and collapse it. Choose where the notch splits the tools below with The notch.", "Knapparna hamnar till vänster och höger om notchen, i menyradens höjd, så panelen tar minsta möjliga plats. Klicka på notchen för att fälla ut och in den. Var notchen delar verktygen väljer du nedan med Notchen.")
        case .off: L("No quick panel. Shortcuts and the menu bar work as usual.", "Ingen snabbpanel. Kortkommandona och menyraden fungerar som vanligt.")
        }
    }

    // MARK: Nedräkning

    private var countdownSection: some View {
        Group {
            Section(L("Preview", "Förhandsvisning")) {
                previewBox(StagePreview(background: state.stageBackground, camera: visibleCamera,
                                        countdown: countdownPreviewDisplay, controller: controller))
                if state.countdownStatus == .idle {
                    Picker(L("Show", "Visa"), selection: $state.countdownPreviewEnd) {
                        Text(L("During the countdown", "Under nedräkningen")).tag(false)
                        Text(L("At 00:00", "Vid 00:00")).tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section(L("Time", "Tid")) {
                Picker(L("Count down", "Räkna ned"), selection: $state.countdown.mode) {
                    ForEach(CountdownMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                switch state.countdown.mode {
                case .duration:
                    LabeledContent(L("Duration", "Längd")) {
                        HStack(spacing: 6) {
                            ForEach([5.0, 10.0, 15.0], id: \.self) { m in
                                Button("\(Int(m)) min") { state.countdown.minutes = m }
                                    .buttonStyle(.bordered)
                                    .tint(state.countdown.minutes == m ? Self.amberBorder : nil)
                            }
                            Text(L("Custom", "Egen"))
                                .padding(.leading, 6)
                            TextField("", value: $state.countdown.minutes, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                            Text("min")
                        }
                        .fixedSize()
                    }
                case .untilTime:
                    DatePicker(L("Time", "Klockslag"), selection: $state.countdownTargetDate, displayedComponents: .hourAndMinute)
                    Text(L("Counts down to the next time the computer's clock shows \(state.countdown.targetTimeText), today or tomorrow.", "Räknar ned till nästa gång datorns klocka visar \(state.countdown.targetTimeText), i dag eller i morgon."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(L("Show the time below the countdown", "Skriv ut klockslaget under nedräkningen"), isOn: $state.countdown.showTargetTime)
                    if state.countdown.showTargetTime {
                        colorRow(color: $state.countdown.targetTimeColor) {
                            TextField(L("Text before the time", "Text före klockslaget"), text: $state.countdown.targetTimeLabel, prompt: Text(Phrase.resumeAt.text))
                        }
                    }
                }
            }
            Section(L("Text and colors", "Text och färger")) {
                colorRow(color: $state.countdown.messageColor) {
                    TextField(L("Heading above the clock", "Rubrik ovanför klockan"), text: $state.countdown.message)
                }
                colorRow(color: $state.countdown.subtitleColor) {
                    TextField(L("Subheading", "Underrubrik"), text: $state.countdown.subtitle, prompt: Text(L("Optional", "Valfri")))
                }
                colorRow(color: $state.countdown.timeColor) {
                    LabeledContent(L("Clock and progress", "Klocka och förlopp")) { EmptyView() }
                }
                colorRow(color: $state.countdown.backgroundColor) {
                    LabeledContent(L("Background", "Bakgrund")) { EmptyView() }
                }
                Button(L("Reset colors", "Återställ färger")) {
                    let d = CountdownSettings()
                    state.countdown.messageColor = d.messageColor
                    state.countdown.subtitleColor = d.subtitleColor
                    state.countdown.timeColor = d.timeColor
                    state.countdown.backgroundColor = d.backgroundColor
                }
            }
            Section(L("Display", "Visning")) {
                Picker(L("Shown", "Visas"), selection: $state.countdown.placement) {
                    ForEach(CountdownPlacement.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(L("When time is up", "När tiden är slut"), selection: $state.countdown.endAction) {
                    ForEach(CountdownEnd.allCases) { Text($0.label).tag($0) }
                }
                if state.countdown.endAction == .welcome {
                    TextField(L("Welcome message", "Välkomstmeddelande"), text: $state.countdown.welcomeText)
                }
                Toggle(L("Play a chime when one minute remains", "Spela en signal när en minut återstår"), isOn: $state.countdown.chime)
                Text(L("The chime plays on the computer. If you share computer sound in the meeting app, it's heard in the meeting too.", "Signalen spelas på datorn. Delar du datorljud i mötesappen hörs den även i mötet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(countdownButtonTitle) { controller.toggleCountdown() }
                        .buttonStyle(.borderedProminent)
                        .tint(Self.amberBorder)
                    if state.countdownStatus != .idle {
                        Button(L("Cancel", "Avbryt")) { controller.cancelCountdown() }
                        Spacer()
                        Text(state.countdownStatus == .finished ? L("Done", "Klar") : CountdownSettings.formatTime(state.countdownRemaining))
                            .font(.title3.monospacedDigit().bold())
                    } else {
                        Spacer()
                    }
                }
                Text((state.keys(.toggleCountdown).map { L("\($0) starts and pauses. ", "\($0) startar och pausar. ") } ?? "")
                     + (state.keys(.clearEffects).map { L("\($0) removes the countdown. ", "\($0) tar bort nedräkningen. ") } ?? "")
                     + L("Right-click the timer in the quick panel to choose the length.", "Högerklicka på timern i snabbpanelen för att välja längd."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colorRow<Content: View>(color: Binding<String>, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
            ColorPicker(L("Color", "Färg"), selection: colorBinding(color), supportsOpacity: false)
                .labelsHidden()
        }
    }

    /// Det som förhandsvisningen ska visa: pågående nedräkning, annars hur den kommer att se ut.
    private var countdownPreviewDisplay: CountdownDisplay {
        let c = state.countdown
        switch state.countdownStatus {
        case .running, .paused:
            return c.display(remaining: state.countdownRemaining, progress: 0.7)
        case .finished:
            return c.display(remaining: nil, progress: 0)
        case .idle:
            return state.countdownPreviewEnd ? c.display(remaining: nil, progress: 0) : c.display(remaining: c.seconds(), progress: 1)
        }
    }


    private var countdownButtonTitle: String {
        switch state.countdownStatus {
        case .idle: L("Start countdown", "Starta nedräkning")
        case .running: L("Pause", "Pausa")
        case .paused: L("Resume", "Fortsätt")
        case .finished: L("Remove", "Ta bort")
        }
    }

    // MARK: Scen


    // MARK: Platser

    private var slotsSection: some View {
        Section(L("Slots", "Platser")) {
            let filled = state.slots.indices.filter { state.slots[$0] != nil }
            if filled.isEmpty {
                Text(state.keys(.assignSlot(0)).map { L("No slots yet. Add windows below, or go to a window and press \($0) for slot 1.", "Inga platser ännu. Lägg till fönster nedan, eller gå till ett fönster och tryck \($0) för plats 1.") }
                     ?? L("No slots yet. Add windows below.", "Inga platser ännu. Lägg till fönster nedan."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !filled.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(filled, id: \.self) { i in
                        if let s = state.slots[i] { slotCard(i, s) }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Menu(L("Add source", "Lägg till källa")) {
                    Section(L("Windows", "Fönster")) {
                        ForEach(state.availableWindows) { w in
                            Button(w.displayName) { controller.addSlot(w) }
                                .disabled(state.slots.contains(w))
                        }
                    }
                    Section(L("Entire screens", "Hela skärmar")) {
                        ForEach(state.availableDisplays) { d in
                            Button(d.displayName) { controller.addSlot(d) }
                                .disabled(state.slots.contains(d))
                        }
                    }
                }
                .fixedSize()
                Button {
                    Task { await controller.refreshSources() }
                } label: {
                    Label(L("Refresh", "Uppdatera"), systemImage: "arrow.clockwise")
                }
            }
            // Här ställs platserna bara in; att dela dem görs med kortkommandon eller snabbpanelen.
            Text(L("Switch between slots with their shortcuts or in the quick panel.", "Växla mellan platserna med kortkommandona eller i snabbpanelen."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await controller.refreshSources() }
    }

    // MARK: Kamera

    private var cameraSection: some View {
        Section(L("Camera", "Kamera")) {
            Toggle(L("Show me in the share", "Visa mig i delningen") + k(.toggleCamera), isOn: $state.camera.enabled)
            Toggle(L("Just me – large camera", "Bara jag – stor kamera") + k(.cameraFullscreen), isOn: $state.camera.fullscreen)
                .disabled(!state.camera.enabled)
            Picker(L("Camera", "Kamera"), selection: $state.camera.deviceID) {
                Text(L("Default", "Standard")).tag(String?.none)
                ForEach(state.cameraDevices, id: \.id) { d in
                    Text(d.name).tag(String?.some(d.id))
                }
            }
            Picker(L("Shape", "Form") + k(.cycleCameraShape), selection: $state.camera.shape) {
                ForEach(CameraShape.allCases) { Text($0.label).tag($0) }
            }
            Picker(L("Aspect", "Format"), selection: $state.camera.aspect) {
                ForEach(CameraAspect.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            // I "Bara jag" styr reglagen och knapparna den stora bubblan, som har egen storlek och position.
            if state.camera.fullscreen {
                LabeledContent(L("Size (Just me)", "Storlek (Bara jag)")) {
                    Slider(value: $state.camera.fullSize, in: 0.3...1)
                }
            } else {
                LabeledContent(L("Size", "Storlek")) {
                    Slider(value: $state.camera.size, in: 0.08...0.8)
                }
            }
            LabeledContent(L("Zoom / crop", "Zoom / beskärning")) {
                Slider(value: $state.camera.zoom, in: 1...3)
            }
            LabeledContent(state.camera.fullscreen ? L("Position (Just me)", "Position (Bara jag)") : "Position" + k(.cycleCameraCorner)) {
                HStack {
                    ForEach([2, 3, 1, 0], id: \.self) { i in
                        Button(["↘", "↙", "↖", "↗"][i]) { controller.setCameraCorner(i) }
                    }
                    Button(L("Center", "Mitten")) { controller.setCameraCenter(x: 0.5, y: 0.5) }
                }
            }
            Text(L("Tip: drag the camera bubble in the preview (or the stage window) and scroll over it to resize.", "Tips: dra kamerabubblan i förhandsvisningen (eller scenfönstret) och scrolla över den för att ändra storlek."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(L("Mirror", "Spegelvänd"), isOn: $state.camera.mirror)
            LabeledContent(L("Border", "Ram")) {
                HStack {
                    Slider(value: $state.camera.borderWidth, in: 0...12)
                    ColorPicker("", selection: colorBinding($state.camera.borderColor), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            Toggle(L("Shadow", "Skugga"), isOn: $state.camera.shadow)
        }
        .onAppear { controller.refreshCameraDevices() }
    }

    // MARK: Effekter

    /// Lägesvalet styr vilka inställningar som visas, så att bara det som påverkar det valda läget syns.
    /// Dimningen gäller båda lägena och ligger därför i en egen sektion.
    @ViewBuilder
    private var effectsSection: some View {
        Section(L("Highlight and dim", "Framhäv och dimma")) {
            Picker(L("Mode", "Läge"), selection: $state.effects.mode) {
                ForEach(HighlightMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            switch state.effects.mode {
            case .off:
                Button(L("Draw a highlight on the screen", "Rita markering på skärmen") + k(.drawHighlight)) { controller.beginRegionSelect() }
                Text(L("Nothing is dimmed. Choose a mode, draw a highlight or press Spotlight\(k(.toggleSpotlight)) to start.", "Inget dimmas. Välj ett läge, rita en markering eller tryck Spotlight\(k(.toggleSpotlight)) för att börja."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .rect:
                HStack {
                    Button(L("Draw a new highlight on the screen", "Rita ny markering på skärmen") + k(.drawHighlight)) { controller.beginRegionSelect() }
                    Spacer()
                    Button(L("Remove", "Ta bort") + k(.clearEffects)) { controller.clearEffects() }
                }
                Text(L("Everything outside the rectangle is dimmed. You can also drag a new rectangle in the preview or the stage window. In the stage window a click removes it.", "Allt utanför rektangeln dimmas. Du kan också dra en ny rektangel i förhandsvisningen eller scenfönstret. I scenfönstret tar ett klick bort den."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .spotlight:
                Text(L("A circle of light follows the mouse pointer and everything else is dimmed.", "En ljuscirkel följer muspekaren och allt annat dimmas."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(L("Spotlight size", "Spotlight-storlek")) {
                    Slider(value: $state.effects.spotlightRadius, in: 0.05...0.5)
                }
                LabeledContent(L("Soft edge", "Mjuk kant")) {
                    Slider(value: $state.effects.feather, in: 0...0.9)
                }
            }
        }
        Section(L("Dimming", "Dimning")) {
            LabeledContent(L("Strength", "Styrka")) {
                Slider(value: $state.effects.dimOpacity, in: 0.2...0.95)
            }
            Toggle(L("Show the dimming on my screen too", "Visa dimningen även på min skärm"), isOn: $state.presenterDim)
            Text(L("You see the same dimming as the audience, over the shared window or screen. It doesn't show in the share and clicks pass straight through it.", "Du ser samma dimning som åskådarna, över det delade fönstret eller skärmen. Den syns inte i delningen och klick går rakt igenom den."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Kortkommandon

    @ViewBuilder
    private var hotkeySection: some View {
        Section("Caps Lock") {
            Picker(L("Caps Lock controls", "Caps Lock styr"), selection: $state.capsLockAction) {
                ForEach(CapsLockAction.allCases) { Text($0.label).tag($0) }
            }
            if state.capsLockAction == .functionLayer {
                Text(L("With Caps Lock on, a single key is enough: 1–9 show the slots, and the other functions have a standard key (see below). If you change a shortcut, its key without ⌃, ⌥ and ⌘ is used instead, and a removed shortcut has no key. With Caps Lock off, the keys type as usual. In the app's own text fields they always type.", "Med Caps Lock på räcker en enda tangent: 1–9 visar platserna och övriga funktioner har en standardtangent (se nedan). Ändrar du en genväg används dess tangent utan ⌃, ⌥ och ⌘ i stället, och en borttagen genväg har ingen tangent. Med Caps Lock av skriver tangenterna som vanligt. I appens egna textfält skriver de alltid."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L("Click and drag draws a highlight while Caps Lock is on", "Klick och dra ritar en markering medan Caps Lock är på"), isOn: $state.capsDraw)
                Text(L("Drawing mode stays on until you turn off Caps Lock, and a thin yellow frame around the screen shows that it's on. Meanwhile you can't click in other apps, but the quick panel works.", "Ritläget ligger kvar tills du slår av Caps Lock, och en tunn gul ram runt skärmen visar att det är på. Under tiden går det inte att klicka i andra appar, men snabbpanelen fungerar."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup(L("Keys in function mode", "Tangenter i funktionsläget")) {
                    ForEach(controller.capsLayerBindings(), id: \.action) { binding in
                        LabeledContent(binding.action.label) {
                            Text(Shortcut.keyName(binding.key)).monospaced().foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(L("Caps Lock on turns the feature on and off turns it off, so the light on the key shows the state. Caps Lock still gives capitals when you type.", "Caps Lock på slår på funktionen och av slår av den, så lampan på tangenten visar läget. Caps Lock ger fortfarande versaler när du skriver."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section(L("Shortcuts", "Kortkommandon")) {
            Text(L("Click a shortcut and press the new combination. It must include ⌃, ⌥ or ⌘ (function keys work on their own). Esc cancels, ⌫ removes the shortcut.", "Klicka på en genväg och tryck den nya kombinationen. Den måste innehålla ⌃, ⌥ eller ⌘ (F-tangenter går bra ensamma). Esc avbryter, ⌫ tar bort genvägen."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !state.hotkeyConflicts.isEmpty {
                Text(L("Couldn't be registered (probably used by the system): ", "Kunde inte registreras (används troligen av systemet): ") + state.hotkeyConflicts.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(HotkeyAction.general) { action in
                shortcutRow(action)
            }
            DisclosureGroup(L("Slots 1–9", "Platser 1–9")) {
                ForEach(HotkeyAction.slotActions) { action in
                    shortcutRow(action)
                }
            }
            HStack {
                Button(L("Reset default shortcuts", "Återställ standardgenvägar")) { controller.resetShortcuts() }
                Button(L("Clear all", "Rensa alla")) { controller.clearAllShortcuts() }
                Spacer()
                Button(L("Try the shortcuts…", "Prova genvägarna…")) { controller.showShortcutGuide() }
            }
        }
    }

    private func shortcutRow(_ action: HotkeyAction) -> some View {
        LabeledContent(action.label) {
            ShortcutRecorder(action: action, state: state, controller: controller)
        }
    }

    // MARK: Meddelanden

    private var messagesSection: some View {
        Section(L("When nothing is shared", "När inget delas")) {
            Picker(L("Situation", "Situation"), selection: $state.editingIdleReason) {
                ForEach(IdleReason.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker(L("Show", "Visa"), selection: idleBinding(\.content)) {
                ForEach(IdleContent.allCases) { Text($0.label).tag($0) }
            }
            if [.text, .image].contains(state.idleMessage(for: state.editingIdleReason).content) {
                TextField(L("Heading", "Rubrik"), text: idleBinding(\.title))
                TextField(L("Subtext", "Undertext"), text: idleBinding(\.subtitle))
            }
            if state.idleMessage(for: state.editingIdleReason).content == .image {
                HStack {
                    Text(imageStatus(state.idleMessage(for: state.editingIdleReason).imageData))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Choose image…", "Välj bild…")) { controller.chooseIdleImage(for: state.editingIdleReason) }
                    if state.idleMessage(for: state.editingIdleReason).imageData != nil {
                        Button(L("Remove", "Ta bort")) {
                            var m = state.idleMessage(for: state.editingIdleReason)
                            m.imageData = nil
                            state.setIdleMessage(m, for: state.editingIdleReason)
                        }
                    }
                }
                Text(L("Animated images (GIF, animated PNG or WebP) play in a loop. The image is stored in the app's settings, so the app needs no other files.", "Animerade bilder (GIF, animerad PNG eller WebP) spelas upp i loop. Bilden sparas i appens inställningar, så appen behöver inga andra filer."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L("Show heading and subtext on top of the image", "Visa rubrik och undertext ovanpå bilden"), isOn: idleBinding(\.textOnImage))
                if state.idleMessage(for: state.editingIdleReason).textOnImage {
                    LabeledContent(L("Text position", "Textens placering")) { positionGrid }
                }
            }
        }
    }

    /// Tre gånger tre knappar för var texten ska ligga på bilden.
    private var positionGrid: some View {
        let selected = state.idleMessage(for: state.editingIdleReason).textPosition
        let rows = stride(from: 0, to: TextPosition.allCases.count, by: 3).map { Array(TextPosition.allCases[$0..<$0 + 3]) }
        return VStack(spacing: 4) {
            ForEach(rows, id: \.first!.id) { row in
                HStack(spacing: 4) {
                    ForEach(row) { position in
                        Button {
                            var m = state.idleMessage(for: state.editingIdleReason)
                            m.textPosition = position
                            state.setIdleMessage(m, for: state.editingIdleReason)
                        } label: {
                            Image(systemName: position.symbol)
                                .foregroundStyle(position == selected ? Color.black : Color.primary)
                                .frame(width: 30, height: 22)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(position == selected ? Self.amber : Color.secondary.opacity(0.18)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(position.label)
                        .accessibilityLabel(position.label)
                    }
                }
            }
        }
    }

    private func imageStatus(_ data: Data?) -> String {
        guard let data else { return L("No image chosen – the text is shown", "Ingen bild vald – texten visas") }
        return AnimatedImage.isAnimated(data) ? L("Animated image chosen", "Animerad bild vald") : L("Image chosen", "Bild vald")
    }

    private func idleBinding<T>(_ keyPath: WritableKeyPath<IdleMessage, T>) -> Binding<T> {
        Binding(
            get: { state.idleMessage(for: state.editingIdleReason)[keyPath: keyPath] },
            set: { value in
                var m = state.idleMessage(for: state.editingIdleReason)
                m[keyPath: keyPath] = value
                state.setIdleMessage(m, for: state.editingIdleReason)
            }
        )
    }

    // MARK: Språk

    private var languageSection: some View {
        // Rubriken står på båda språken, så att den går att hitta även om man valt ett språk man inte läser.
        Section("Language · Språk") {
            Picker(L("Language", "Språk"), selection: $state.language) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Inställningar

    private var settingsSection: some View {
        Section(L("Settings", "Inställningar")) {
            Text(L("The app is a single file with no installation. Settings can be moved to another Mac with export and import.", "Appen är en enda fil utan installation. Inställningarna kan flyttas till en annan Mac med export och import."))
                .font(.callout)
            HStack {
                Button(L("Export settings…", "Exportera inställningar…")) { controller.exportSettings() }
                Button(L("Import…", "Importera…")) { controller.importSettings() }
            }
        }
    }

    // MARK: Ljud

    private var audioSection: some View {
        Section(L("Audio", "Ljud")) {
            Text(.init(L("The meeting app sends audio regardless of what is shared. Turn on computer sound sharing when you start sharing (in Teams: **Include computer sound**, in Zoom: **Share sound**). The sound then comes along whatever the stage shows.", "Mötesappen skickar ljud oberoende av vad som delas. Slå på delning av datorljud när du startar delningen (i Teams: **Inkludera datorljud**, i Zoom: **Dela ljud**). Ljudet följer då med oavsett vad scenen visar.")))
                .font(.callout)
        }
    }

    // MARK: Hjälp

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .white) },
            set: { hex.wrappedValue = NSColor($0).hexString }
        )
    }
}

// MARK: - Inspelning av genväg

struct ShortcutRecorder: View {
    let action: HotkeyAction
    @ObservedObject var state: AppState
    let controller: AppController

    private var recording: Bool { state.recordingAction == action }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? controller.stopRecording() : controller.startRecording(action)
            } label: {
                Text(recording ? L("Press combination…", "Tryck kombination…") : (state.keys(action) ?? L("None", "Ingen")))
                    .frame(minWidth: 120)
                    .foregroundStyle(recording ? Color.accentColor : (state.keys(action) == nil ? Color.secondary : Color.primary))
            }
            Button {
                controller.setShortcut(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("Remove the shortcut", "Ta bort genvägen"))
            .opacity(state.shortcut(for: action) != nil && !recording ? 1 : 0)
            .disabled(state.shortcut(for: action) == nil || recording)
        }
    }
}

// MARK: - Förhandsvisning av scenen

/// En liten scen i kontrollpanelen som visar hur en inställning ser ut för publiken. Den använder samma
/// scenvy som delas, med ett exempelfönster som innehåll, så att det som visas här är det som syns i mötet.
struct StagePreview: NSViewRepresentable {
    var background: String
    /// Kameran med de här inställningarna; `nil` döljer den.
    var camera: CameraSettings?
    var effects = EffectSettings()
    var spotlightCenter: CGPoint?
    /// Meddelandet som visas när inget delas; `nil` visar exempelfönstret.
    var idle: IdleMessage?
    var countdown: CountdownDisplay?
    /// Textläget; `nil` döljer det.
    var textCard: String?
    /// Om musen kan flytta kameran och rita markeringen, som i scenfönstret.
    var interactive = false
    let controller: AppController

    func makeNSView(context: Context) -> StageView {
        let view = StageView(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        if interactive {
            view.controller = controller
            view.isSettingsPreview = true
        }
        view.attachPreview(controller.makeCameraPreviewLayer())
        return view
    }

    func updateNSView(_ view: StageView, context: Context) {
        view.referenceHeight = controller.stageHeight
        view.setBackground(background)
        var cam = camera ?? CameraSettings()
        cam.enabled = camera != nil
        view.apply(camera: cam, animated: false)
        view.apply(effects: effects)
        if interactive {
            view.previewSpotlightRest = spotlightCenter
            view.showPreviewSpotlight()
        } else {
            view.setSpotlight(center: spotlightCenter)
        }
        if let idle {
            if idle.content == .lastFrame { view.displayStill(Self.sampleWindow) }
            view.showIdle(idle)
        } else {
            view.clearIdle()
            view.displayStill(Self.sampleWindow)
        }
        view.setCountdown(countdown)
        view.setTextCard(textCard)
    }

    /// Ett påhittat dokumentfönster att visa effekterna på.
    static let sampleWindow: CGImage = {
        let w = 1400, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ hex: String, _ r: CGRect, radius: CGFloat = 0) {
            ctx.setFillColor((NSColor(hex: hex) ?? .gray).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        fill("#F4F5F7", CGRect(x: 0, y: 0, width: w, height: h))
        fill("#E2E4E9", CGRect(x: 0, y: h - 70, width: w, height: 70))
        for (i, c) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            fill(c, CGRect(x: 30 + i * 40, y: h - 48, width: 24, height: 24), radius: 12)
        }
        fill("#2B2F38", CGRect(x: 90, y: h - 190, width: 620, height: 50), radius: 10)
        for (i, width) in [1100, 980, 1150, 760, 1040, 900].enumerated() {
            fill("#C9CED8", CGRect(x: 90, y: h - 290 - i * 60, width: width, height: 26), radius: 13)
        }
        fill("#FFB020", CGRect(x: 90, y: 90, width: 520, height: 240), radius: 16)
        fill("#5B8DEF", CGRect(x: 660, y: 90, width: 650, height: 240), radius: 16)
        return ctx.makeImage()!
    }()
}

/// Uppmätta bilder per sekund. Egen vy, så att bara den ritas om varje sekund.
/// Källan skickar bara nya bilder när något ändras, så låga tal vid stillastående innehåll är normalt.
private struct FPSText: View {
    @ObservedObject var stats: FrameStats
    let sharing: Bool
    let previewOn: Bool

    var body: some View {
        let source = sharing ? "\(Int(stats.source))" : "–"
        let preview = previewOn ? "\(Int(stats.preview))" : L("off", "av")
        Text(L("source \(source) · preview \(preview) fps", "källa \(source) · förhandsvisning \(preview) fps"))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
