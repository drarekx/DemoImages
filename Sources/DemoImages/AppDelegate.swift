import AppKit
import Combine
import SwiftUI

/// App identity shared by the updater, menus and storage.
enum AppInfo {
    static let name = "DemoImages"
    /// GitHub repository the updater and installer read releases from.
    static let repo = "drarekx/DemoImages"
}

/// Menu commands the main window reacts to. Menu items without a text field in
/// focus travel up the responder chain to the app delegate, which forwards them here.
enum AppCommand {
    case newAlbum, importImages, selectAll, delete, copy, paste, settings
    case open([URL])
}

@MainActor
final class AppCommands {
    static let shared = AppCommands()
    let subject = PassthroughSubject<AppCommand, Never>()
    func send(_ command: AppCommand) { subject.send(command) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pendingOpen: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        Localizer.shared.$choice
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setupMainMenu() }
            .store(in: &cancellables)
        removeLeftoverTemporaryFiles()
        Library.shared.load()
        showMainWindow()
        Updater.shared.start()
        launched = true
        if !pendingOpen.isEmpty {
            let urls = pendingOpen
            pendingOpen = []
            DispatchQueue.main.async { AppCommands.shared.send(.open(urls)) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Files dropped on the Dock icon (or "Open with") go into the current album.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingOpen += urls
            return
        }
        showMainWindow()
        AppCommands.shared.send(.open(urls))
    }

    /// Optimizer work folders live in $TMPDIR; remove those a crash left behind.
    private func removeLeftoverTemporaryFiles() {
        let temp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-12 * 60 * 60)
        for item in items where item.lastPathComponent.hasPrefix("\(AppInfo.name)-") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Window

    @objc func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = AppInfo.name
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 900, height: 600)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
            let hosting = NSHostingController(rootView: MainView())
            // NSHostingController would otherwise shrink the window to its ideal size.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
            // Restores the last frame, if any, and saves it from now on.
            window.setFrameAutosaveName("MainWindow")
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Main menu

    private func setupMainMenu() {
        let main = NSMenu()
        let name = AppInfo.name

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Acerca de %@", name),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Ajustes…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: tr("Buscar actualizaciones…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Ocultar %@", name), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: tr("Ocultar otras"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: tr("Mostrar todo"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Salir de %@", name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: tr("Archivo"))
        file.addItem(withTitle: tr("Nuevo álbum…"), action: #selector(newAlbum), keyEquivalent: "n").target = self
        file.addItem(withTitle: tr("Añadir imágenes…"), action: #selector(importImages), keyEquivalent: "o").target = self
        file.addItem(.separator())
        file.addItem(withTitle: tr("Cerrar ventana"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        // Text fields need these for ⌘C / ⌘V / ⌘A; with no text field focused they
        // reach the app delegate (below) and act on the gallery.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Edición"))
        edit.addItem(withTitle: tr("Deshacer"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Rehacer"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Cortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Pegar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let trash = edit.addItem(withTitle: tr("Mover a la papelera"), action: #selector(deleteSelection), keyEquivalent: "\u{8}")
        trash.keyEquivalentModifierMask = [.command]
        trash.target = self
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: tr("Ventana"))
        window.addItem(withTitle: tr("Minimizar"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: tr("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: AppInfo.name, action: #selector(showMainWindow), keyEquivalent: "0").target = self
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return Updater.shared.state == .idle
        }
        return true
    }

    // MARK: - Commands

    @objc private func newAlbum() { showMainWindow(); AppCommands.shared.send(.newAlbum) }
    @objc private func importImages() { showMainWindow(); AppCommands.shared.send(.importImages) }
    @objc private func showSettings() { showMainWindow(); AppCommands.shared.send(.settings) }
    @objc private func deleteSelection() { AppCommands.shared.send(.delete) }
    @objc private func checkForUpdates() { Task { await Updater.shared.check(userInitiated: true) } }

    // Reached only when no text field handles them first.
    @objc func selectAll(_ sender: Any?) { AppCommands.shared.send(.selectAll) }
    @objc func copy(_ sender: Any?) { AppCommands.shared.send(.copy) }
    @objc func paste(_ sender: Any?) { AppCommands.shared.send(.paste) }
}
