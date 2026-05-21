import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let monitor = FocusMonitor()
    private let indicator = IndicatorPanel()
    private var settingsWC: SettingsWindowController?
    private var permissionWC: PermissionWindowController?
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var permissionPollTimer: Timer?
    private var wasTrusted = false

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/top.cuiko.termims.plist"
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.debug("=== TermIMS started ===")
        installEditMenu()
        if AXIsProcessTrusted() {
            wasTrusted = true
            startApp()
        } else {
            showPermissionWindow()
        }
        startPermissionPolling()
    }

    /// LSUIElement apps don't get a main menu by default, which means
    /// Cmd+C/V/X/A in any text field are dispatched into the void. Wire up
    /// a minimal Edit menu so the standard shortcuts reach the field editor.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),         keyEquivalent: "x")
        edit.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),        keyEquivalent: "c")
        edit.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),       keyEquivalent: "v")
        edit.addItem(withTitle: "Delete",     action: #selector(NSText.delete(_:)),      keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),   keyEquivalent: "a")

        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if self.wasTrusted && !trusted {
                self.wasTrusted = false
                self.monitor.stop()
                self.rebuildMenu()
            } else if !self.wasTrusted && trusted {
                self.wasTrusted = true
                self.startApp()
            }
        }
    }

    private func showPermissionWindow() {
        permissionWC = PermissionWindowController()
        permissionWC?.onGranted = { [weak self] in
            self?.permissionWC = nil
            self?.startApp()
        }
        permissionWC?.showWindow(nil)
        permissionWC?.startPolling()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var appStarted = false
    private func startApp() {
        guard !appStarted else { rebuildMenu(); monitor.reload(); return }
        appStarted = true
        applyMenuBarVisibility()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildMenu),
                                               name: .rulesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(imDidSwitch),
                                               name: .imDidSwitch, object: nil)
        monitor.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !AXIsProcessTrusted() {
            showPermissionWindow()
        } else {
            showSettings()
        }
        return true
    }

    @objc private func imDidSwitch() {
        guard RuleStore.shared.indicatorEnabled,
              let name = currentInputSourceName() else { return }
        indicator.show(text: name, position: RuleStore.shared.indicatorPosition)
    }

    private func applyMenuBarVisibility() {
        if RuleStore.shared.hideMenuBarIcon {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        } else {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let btn = statusItem?.button {
                    btn.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "TermIMS")
                }
            }
            rebuildMenu()
        }
    }

    @objc private func rebuildMenu() {
        if RuleStore.shared.hideMenuBarIcon { applyMenuBarVisibility(); return }
        guard let statusItem else { applyMenuBarVisibility(); return }

        let menu = NSMenu()
        let store = RuleStore.shared
        let trusted = AXIsProcessTrusted()

        if !trusted {
            let warn = NSMenuItem(title: "Accessibility Permission Required", action: #selector(showPermissionPrompt), keyEquivalent: "")
            warn.target = self
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self; enabledItem.state = monitor.enabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(.separator())

        let defName = store.defaultSourceName ?? "None"
        let defItem = NSMenuItem(title: "Default: \(defName)", action: nil, keyEquivalent: "")
        defItem.isEnabled = false; menu.addItem(defItem)

        let activeAppRules = store.rules.filter(\.enabled)
        if !activeAppRules.isEmpty {
            menu.addItem(.separator())
            let hdr = NSMenuItem(title: "App Rules", action: nil, keyEquivalent: "")
            hdr.isEnabled = false; menu.addItem(hdr)
            for rule in activeAppRules {
                let item = NSMenuItem(title: "  \(rule.appName) \u{2192} \(rule.inputSourceName)", action: nil, keyEquivalent: "")
                item.isEnabled = false; menu.addItem(item)
            }
        }

        let activeTermRules = store.terminalRules.filter(\.enabled)
        if !activeTermRules.isEmpty {
            menu.addItem(.separator())
            let hdr = NSMenuItem(title: "Terminal Rules", action: nil, keyEquivalent: "")
            hdr.isEnabled = false; menu.addItem(hdr)
            for rule in activeTermRules {
                let typeStr = rule.matchType == .title ? "title" : "proc"
                let item = NSMenuItem(title: "  \(typeStr):\(rule.pattern) \u{2192} \(rule.inputSourceName)", action: nil, keyEquivalent: "")
                item.isEnabled = false; menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)

        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TermIMS", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        monitor.enabled.toggle(); enabledItem.state = monitor.enabled ? .on : .off
    }
    @objc private func showPermissionPrompt() {
        showPermissionWindow()
    }
    @objc private func showSettings() {
        if !AXIsProcessTrusted() { showPermissionWindow(); return }
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentPath) {
            try? fm.removeItem(atPath: launchAgentPath)
        } else {
            try? fm.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents", withIntermediateDirectories: true)
            let plist: NSDictionary = [
                "Label": "top.cuiko.termims",
                "ProgramArguments": [Bundle.main.executablePath ?? ""],
                "RunAtLoad": true,
            ]
            plist.write(toFile: launchAgentPath, atomically: true)
        }
        loginItem.state = fm.fileExists(atPath: launchAgentPath) ? .on : .off
    }
    @objc private func quitApp() { monitor.stop(); NSApp.terminate(nil) }
}
