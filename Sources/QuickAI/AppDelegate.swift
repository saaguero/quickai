import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var viewModel: ChatViewModel!
    private var panelController: PanelController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings.applyAppearance()

        // A previous run that crashed or was killed may have left its opencode
        // server running. Clear it before anything starts a new one.
        OpenCodeServer.reapOrphan()
        installTerminationSignalHandlers()

        settings.applyDefaultChoice()
        viewModel = ChatViewModel(settings: settings)
        panelController = PanelController(viewModel: viewModel, settings: settings) { [weak self] in
            self?.showSettings()
        }

        setupMainMenu()
        setupStatusItem()
        registerHotKey()

        NotificationCenter.default.addObserver(
            forName: AppSettings.hotKeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerHotKey()
                self?.rebuildStatusMenu()
            }
        }

        // Discoverability on first launch
        panelController.show()

        // Warm up the macOS Local Network permission so the first real
        // question does not eat the TCC-prompt connection failure.
        if let local = settings.providers.first(where: { $0.id == "local" }) {
            Task.detached {
                _ = try? await ModelCatalog.fetch(baseUrl: local.baseUrl, apiKey: local.apiKey)
            }
        }
    }

    /// AppKit calls `applicationWillTerminate` only on a normal quit, so a
    /// `kill` or a supervisor stop would strand the opencode child. These
    /// sources catch the signals and shut it down before exiting.
    private func installTerminationSignalHandlers() {
        for code in [SIGTERM, SIGINT, SIGHUP] {
            // The default disposition would kill us before the handler runs.
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    await OpenCodeServer.shared.stop()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// The opencode server is a child process: it must not outlive the app.
    func applicationWillTerminate(_ notification: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await OpenCodeServer.shared.stop()
            semaphore.signal()
        }
        // Termination does not wait for async work on its own, and a leaked
        // server would keep holding its port and the user's credentials.
        _ = semaphore.wait(timeout: .now() + 3)
    }

    private func registerHotKey() {
        HotKeyCenter.shared.register(
            keyCode: settings.hotKeyKeyCode,
            modifiers: settings.hotKeyModifierFlags
        ) { [weak self] in
            self?.panelController.toggle()
        }
    }

    // MARK: - Main menu

    /// Accessory apps have no visible menu bar, but ⌘X/⌘C/⌘V/⌘A in text fields
    /// are routed through the main menu's Edit items, so one must exist.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit QuickAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "QuickAI")
        statusItem = item
        rebuildStatusMenu()
    }

    /// "QuickAI 0.1.0 (build 20260828.1530)" - the fastest way to tell whether a
    /// freshly bundled build actually replaced the running one.
    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "QuickAI \(short) (build \(build))"
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()

        let version = NSMenuItem(title: versionLabel, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(.separator())

        let ask = NSMenuItem(title: "Ask  (\(settings.hotKeyDisplay))", action: #selector(togglePanel), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)

        let history = NSMenuItem(title: "Conversation History", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Settings…", action: #selector(showSettingsItem), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit QuickAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func showHistory() {
        panelController.showHistory()
    }

    @objc private func showSettingsItem() {
        showSettings()
    }

    // MARK: - Settings window

    func showSettings() {
        // The panel floats above normal windows, so leaving it up puts it on
        // top of Settings. It keeps its conversation while hidden, and ⌥Space
        // brings it back untouched.
        panelController?.hide()

        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, model: viewModel))
            let window = NSWindow(contentViewController: hosting)
            window.title = "QuickAI Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        // the floating panel may still hold key focus; insist once the run loop settles
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindow?.makeKey()
        }
    }
}
