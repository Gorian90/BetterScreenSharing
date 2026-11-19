import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var languageObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        AppController.shared.start()
        // Menyerna är vanliga AppKit-menyer och byggs om när språket byts.
        languageObserver = AppState.shared.$language.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { NSApp.mainMenu = self?.makeMainMenu() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared.showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About BetterScreenSharing", "Om BetterScreenSharing"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide BetterScreenSharing", "Göm BetterScreenSharing"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("Quit BetterScreenSharing", "Avsluta BetterScreenSharing"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit", "Redigera"))
        editMenu.addItem(withTitle: L("Cut", "Klipp ut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy", "Kopiera"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste", "Klistra in"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All", "Markera allt"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Window", "Fönster"))
        windowMenu.addItem(withTitle: L("Control Panel", "Kontrollpanel"), action: #selector(showPanel), keyEquivalent: "1").target = self
        windowMenu.addItem(withTitle: L("Stage", "Scen"), action: #selector(showStage), keyEquivalent: "2").target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("Minimize", "Minimera"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Close", "Stäng"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    @objc private func showPanel() { AppController.shared.showPanel() }
    @objc private func showStage() { AppController.shared.showStage() }
}

// build.sh: `--write-iconset <mapp>` skriver appikonen som PNG-filer och avslutar.
if let i = CommandLine.arguments.firstIndex(of: "--write-iconset"), i + 1 < CommandLine.arguments.count {
    do {
        try AppIcon.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not write the icon: \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    // `--write-tutorial-video <fil.mp4> [en|sv]` sparar introduktionsvideon och avslutar.
    if let i = CommandLine.arguments.firstIndex(of: "--write-tutorial-video"), i + 1 < CommandLine.arguments.count {
        let language = CommandLine.arguments.dropFirst(i + 2).first.flatMap(AppLanguage.init(rawValue:)) ?? .english
        do {
            try TutorialExport.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), language: language)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Could not write the video: \(error)\n".utf8))
            exit(1)
        }
    }
    if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), i + 1 < CommandLine.arguments.count {
        do { try UIRender.run(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) } catch { print(error) }
        exit(0)
    }
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
