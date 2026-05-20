import Cocoa
import Carbon
import ApplicationServices
import UniformTypeIdentifiers

// MARK: - Input Source

struct IMSource {
    let id: String
    let name: String
}

func listInputSources() -> [IMSource] {
    guard let all = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
    return all.compactMap { tis -> IMSource? in
        guard let typePtr = TISGetInputSourceProperty(tis, kTISPropertyInputSourceType),
              let capPtr  = TISGetInputSourceProperty(tis, kTISPropertyInputSourceIsSelectCapable),
              let enPtr   = TISGetInputSourceProperty(tis, kTISPropertyInputSourceIsEnabled),
              let idPtr   = TISGetInputSourceProperty(tis, kTISPropertyInputSourceID),
              let namePtr = TISGetInputSourceProperty(tis, kTISPropertyLocalizedName) else { return nil }
        let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        guard type == kTISTypeKeyboardLayout as String ||
              type == kTISTypeKeyboardInputMode as String else { return nil }
        guard CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(capPtr).takeUnretainedValue()),
              CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enPtr).takeUnretainedValue()) else { return nil }
        return IMSource(
            id:   Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String,
            name: Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
        )
    }
}

func currentInputSourceName() -> String? {
    guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(cur, kTISPropertyLocalizedName) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func selectInputSource(_ id: String) {
    if let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
       let ptr = TISGetInputSourceProperty(cur, kTISPropertyInputSourceID) {
        let curID = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        if curID == id { return }
    }
    let props = [kTISPropertyInputSourceID: id] as CFDictionary
    guard let list = TISCreateInputSourceList(props, false)?.takeRetainedValue() as? [TISInputSource],
          let source = list.first else { return }
    TISSelectInputSource(source)
    NotificationCenter.default.post(name: .imDidSwitch, object: nil)
}

// MARK: - Data Models

struct Rule: Codable {
    var enabled: Bool = true
    var appBundleID: String
    var appName: String
    var inputSourceID: String
    var inputSourceName: String
}

enum TerminalMatchType: String, Codable, CaseIterable {
    case process = "Process Name"
    case title   = "Tab Title"
}

struct TerminalRule: Codable {
    var enabled: Bool = true
    var matchType: TerminalMatchType = .title
    var pattern: String = ""
    var inputSourceID: String
    var inputSourceName: String
}

enum IndicatorPosition: String, Codable, CaseIterable {
    case screenCenter  = "Screen Center"
    case centerBottom  = "Center Bottom"
    case topLeft       = "Top Left"
    case topRight      = "Top Right"
    case bottomLeft    = "Bottom Left"
    case bottomRight   = "Bottom Right"
}

let terminalBundleIDs: Set<String> = [
    "com.mitchellh.ghostty",
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "dev.warp.Warp-Stable",
    "org.alacritty",
]

extension Notification.Name {
    static let rulesDidChange = Notification.Name("RulesDidChange")
    static let imDidSwitch    = Notification.Name("IMDidSwitch")
}

// MARK: - Rule Store

class RuleStore {
    static let shared = RuleStore()
    private let ud = UserDefaults.standard

    private func notify() {
        NotificationCenter.default.post(name: .rulesDidChange, object: nil)
    }

    var rules: [Rule] {
        get { decode("TermIMSRules") ?? [] }
        set { encode(newValue, "TermIMSRules"); notify() }
    }

    var defaultSourceID: String? {
        get { ud.string(forKey: "DefaultSourceID") }
        set { ud.set(newValue, forKey: "DefaultSourceID"); notify() }
    }
    var defaultSourceName: String? {
        get { ud.string(forKey: "DefaultSourceName") }
        set { ud.set(newValue, forKey: "DefaultSourceName") }
    }

    var indicatorEnabled: Bool {
        get { ud.object(forKey: "IndicatorEnabled") as? Bool ?? true }
        set { ud.set(newValue, forKey: "IndicatorEnabled") }
    }
    var indicatorPosition: IndicatorPosition {
        get { IndicatorPosition(rawValue: ud.string(forKey: "IndicatorPosition") ?? "") ?? .centerBottom }
        set { ud.set(newValue.rawValue, forKey: "IndicatorPosition") }
    }

    var hideMenuBarIcon: Bool {
        get { ud.bool(forKey: "HideMenuBarIcon") }
        set { ud.set(newValue, forKey: "HideMenuBarIcon"); notify() }
    }

    var terminalRules: [TerminalRule] {
        get { decode("TermIMSTerminalRules") ?? [] }
        set { encode(newValue, "TermIMSTerminalRules"); notify() }
    }

    var terminalDefaultSourceID: String? {
        get { ud.string(forKey: "TerminalDefaultSourceID") }
        set { ud.set(newValue, forKey: "TerminalDefaultSourceID"); notify() }
    }
    var terminalDefaultSourceName: String? {
        get { ud.string(forKey: "TerminalDefaultSourceName") }
        set { ud.set(newValue, forKey: "TerminalDefaultSourceName") }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = ud.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func encode<T: Encodable>(_ val: T, _ key: String) {
        ud.set(try? JSONEncoder().encode(val), forKey: key)
    }
}

// MARK: - Indicator

class IndicatorPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 180, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .transient]

        let bg = NSView(frame: contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.9).cgColor
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        contentView?.addSubview(bg)

        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -12),
        ])
    }

    func show(text: String, position: IndicatorPosition) {
        label.stringValue = text
        label.sizeToFit()
        let w = max(label.frame.width + 40, 100)
        let h: CGFloat = 44
        setContentSize(NSSize(width: w, height: h))

        guard let s = NSScreen.main else { return }
        let mx: CGFloat = 60
        let my: CGFloat = 60
        let pt: NSPoint
        switch position {
        case .screenCenter:
            pt = NSPoint(x: s.frame.midX - w / 2, y: s.frame.midY - h / 2)
        case .centerBottom:
            pt = NSPoint(x: s.frame.midX - w / 2, y: s.frame.minY + my)
        case .topLeft:
            pt = NSPoint(x: s.frame.minX + mx, y: s.frame.maxY - h - my)
        case .topRight:
            pt = NSPoint(x: s.frame.maxX - w - mx, y: s.frame.maxY - h - my)
        case .bottomLeft:
            pt = NSPoint(x: s.frame.minX + mx, y: s.frame.minY + my)
        case .bottomRight:
            pt = NSPoint(x: s.frame.maxX - w - mx, y: s.frame.minY + my)
        }
        setFrameOrigin(pt)
        alphaValue = 1
        orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.animator().alphaValue = 0
            }, completionHandler: { self?.orderOut(nil) })
        }
    }
}

// MARK: - Focus Monitor

class AXContext {
    let bundleID: String
    weak var monitor: FocusMonitor?
    init(_ bid: String, _ m: FocusMonitor) { bundleID = bid; monitor = m }
}

class FocusMonitor {
    var enabled = true
    private var observers: [String: AXObserver] = [:]
    private var elements:  [String: AXUIElement] = [:]
    private var contexts:  [String: AXContext] = [:]
    private var termDebounce: Timer?

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(activated),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(launched),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(terminated),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .rulesDidChange, object: nil)
        reload()
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        termDebounce?.invalidate()
        for bid in Array(observers.keys) { detach(bid) }
    }

    @objc func reload() {
        let store = RuleStore.shared
        var needed = Set(store.rules.filter(\.enabled).map(\.appBundleID))
        if store.terminalRules.contains(where: \.enabled) {
            needed.formUnion(terminalBundleIDs)
        }
        for bid in observers.keys where !needed.contains(bid) { detach(bid) }
        for bid in needed where observers[bid] == nil { attach(bid) }
    }

    private func isTerminalWithRules(_ bid: String) -> Bool {
        terminalBundleIDs.contains(bid) && RuleStore.shared.terminalRules.contains(where: \.enabled)
    }

    private func resolveInputSource(for bid: String) -> String? {
        let store = RuleStore.shared
        if isTerminalWithRules(bid) {
            if let matched = matchTerminalRule(bid: bid, store: store) {
                return matched
            }
            if let termDefault = store.terminalDefaultSourceID {
                return termDefault
            }
        }
        if let rule = store.rules.first(where: { $0.enabled && $0.appBundleID == bid }) {
            return rule.inputSourceID
        }
        return store.defaultSourceID
    }

    private func matchTerminalRule(bid: String, store: RuleStore) -> String? {
        let rules = store.terminalRules.filter(\.enabled)
        guard !rules.isEmpty else { return nil }

        let titleRules = rules.filter { $0.matchType == .title }
        let processRules = rules.filter { $0.matchType == .process }

        if !titleRules.isEmpty, let title = getFocusedWindowTitle(bid: bid) {
            for rule in titleRules {
                if !rule.pattern.isEmpty &&
                   title.localizedCaseInsensitiveContains(rule.pattern) {
                    return rule.inputSourceID
                }
            }
        }

        if !processRules.isEmpty {
            let procs = getTerminalForegroundProcesses(bid: bid)
            for rule in processRules {
                if !rule.pattern.isEmpty &&
                   procs.contains(where: { $0.localizedCaseInsensitiveContains(rule.pattern) }) {
                    return rule.inputSourceID
                }
            }
        }

        return nil
    }

    // MARK: AX Helpers

    private func getFocusedWindow(bid: String) -> AXUIElement? {
        guard let el = elements[bid] else { return nil }
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success else { return nil }
        return (win as! AXUIElement)
    }

    private func getFocusedWindowTitle(bid: String) -> String? {
        guard let win = getFocusedWindow(bid: bid) else { return nil }
        var val: AnyObject?
        guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &val) == .success else { return nil }
        return val as? String
    }

    private func getFocusedWindowCWD(bid: String) -> String? {
        guard let win = getFocusedWindow(bid: bid) else { return nil }
        var val: AnyObject?
        guard AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &val) == .success,
              let urlStr = val as? String,
              let url = URL(string: urlStr) else { return nil }
        return url.path
    }

    // MARK: Process Helpers

    private func processCWD(_ pid: Int32) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, size)
        guard ret == size else { return nil }
        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private func procName(from kp: kinfo_proc) -> String {
        withUnsafePointer(to: kp.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private func getTerminalForegroundProcesses(bid: String) -> [String] {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bid }) else { return [] }
        let termPid = app.processIdentifier
        guard let tabCWD = getFocusedWindowCWD(bid: bid) else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride

        struct PE { let pid: Int32; let ppid: Int32; let tdev: dev_t; let isFg: Bool; let comm: String }
        var entries: [PE] = []
        entries.reserveCapacity(actual)
        for i in 0..<actual {
            let kp = procs[i]
            entries.append(PE(
                pid: kp.kp_proc.p_pid,
                ppid: kp.kp_eproc.e_ppid,
                tdev: kp.kp_eproc.e_tdev,
                isFg: kp.kp_eproc.e_pgid == kp.kp_eproc.e_tpgid,
                comm: procName(from: kp)
            ))
        }

        var descendants = Set<Int32>()
        var queue: [Int32] = [termPid]
        while let p = queue.popLast() {
            for e in entries where e.ppid == p {
                descendants.insert(e.pid)
                queue.append(e.pid)
            }
        }

        // Find shell processes among descendants to identify the active tab's tty via CWD
        let shellNames: Set<String> = ["zsh", "bash", "fish", "login"]
        let shells = entries.filter { descendants.contains($0.pid) && $0.tdev != 0 && shellNames.contains($0.comm) }

        // Collect all ttys whose shell CWD matches AXDocument
        var candidateTdevs: [dev_t] = []
        var matched = Set<dev_t>()
        for shell in shells {
            guard !matched.contains(shell.tdev) else { continue }
            if processCWD(shell.pid) == tabCWD {
                matched.insert(shell.tdev)
                candidateTdevs.append(shell.tdev)
            }
        }

        guard !candidateTdevs.isEmpty else { return [] }

        // Build a lookup: tdev → foreground process names on that tty
        let fgByTty: [dev_t: [String]] = {
            var m: [dev_t: [String]] = [:]
            for e in entries where descendants.contains(e.pid) && e.isFg && e.tdev != 0 {
                m[e.tdev, default: []].append(e.comm)
            }
            return m
        }()

        let tdev: dev_t
        if candidateTdevs.count == 1 {
            tdev = candidateTdevs[0]
        } else {
            // Multiple ttys share the same CWD — use window title to pick the shell
            // vs non-shell branch, then tty mtime to disambiguate within each branch.
            let title = getFocusedWindowTitle(bid: bid) ?? ""
            let cwdBase = URL(fileURLWithPath: tabCWD).lastPathComponent
            let looksLikeShell = title.isEmpty
                || title == cwdBase
                || title.hasSuffix(cwdBase)
                || title.hasPrefix("/")
                || title.hasPrefix("~")
                || shellNames.contains(title)

            if looksLikeShell {
                tdev = candidateTdevs.first(where: { td in
                    (fgByTty[td] ?? []).allSatisfy { shellNames.contains($0) }
                }) ?? candidateTdevs[0]
            } else {
                let nonShellTdevs = candidateTdevs.filter { td in
                    (fgByTty[td] ?? []).contains(where: { !shellNames.contains($0) })
                }
                if nonShellTdevs.count > 1 {
                    func mtime(_ d: dev_t) -> (Int, Int) {
                        guard let n = devname(d, mode_t(S_IFCHR)) else { return (0, 0) }
                        var sb = stat()
                        guard lstat("/dev/" + String(cString: n), &sb) == 0 else { return (0, 0) }
                        return (sb.st_mtimespec.tv_sec, sb.st_mtimespec.tv_nsec)
                    }
                    tdev = nonShellTdevs.max(by: { mtime($0) < mtime($1) }) ?? nonShellTdevs[0]
                } else {
                    tdev = nonShellTdevs.first ?? candidateTdevs[0]
                }
            }
        }

        return entries
            .filter { descendants.contains($0.pid) && $0.tdev == tdev && $0.isFg }
            .map(\.comm)
    }

    // MARK: Event Handlers

    @objc private func activated(_ n: Notification) {
        guard enabled, let bid = bundleID(from: n) else { return }
        if isTerminalWithRules(bid) {
            debouncedResolve(bid)
        } else {
            if let id = resolveInputSource(for: bid) {
                selectInputSource(id)
            }
        }
    }

    private func handleWindowFocus(_ bid: String) {
        guard enabled else { return }
        if isTerminalWithRules(bid) {
            debouncedResolve(bid)
        } else {
            if let id = resolveInputSource(for: bid) {
                selectInputSource(id)
            }
        }
    }

    private func debouncedResolve(_ bid: String) {
        termDebounce?.invalidate()
        termDebounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self, self.enabled else { return }
            if let id = self.resolveInputSource(for: bid) {
                selectInputSource(id)
            }
        }
    }

    @objc private func launched(_ n: Notification) {
        guard let bid = bundleID(from: n) else { return }
        let store = RuleStore.shared
        let needsObserver = store.rules.contains(where: { $0.enabled && $0.appBundleID == bid })
            || (terminalBundleIDs.contains(bid) && store.terminalRules.contains(where: \.enabled))
        if needsObserver { attach(bid) }
    }

    @objc private func terminated(_ n: Notification) {
        guard let bid = bundleID(from: n) else { return }
        detach(bid)
    }

    private func bundleID(from n: Notification) -> String? {
        (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    func attach(_ bid: String) {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bid }) else { return }
        detach(bid)

        let pid = app.processIdentifier
        let el  = AXUIElementCreateApplication(pid)
        elements[bid] = el

        let ctx = AXContext(bid, self)
        contexts[bid] = ctx
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque())

        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let c = Unmanaged<AXContext>.fromOpaque(refcon).takeUnretainedValue()
            guard let m = c.monitor, m.enabled else { return }
            m.handleWindowFocus(c.bundleID)
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, cb, &obs) == .success, let observer = obs else { return }
        observers[bid] = observer

        let notifs = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] as [CFString]
        for name in notifs { AXObserverAddNotification(observer, el, name, ptr) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func detach(_ bid: String) {
        guard let obs = observers[bid], let el = elements[bid] else { return }
        let notifs = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] as [CFString]
        for n in notifs { AXObserverRemoveNotification(obs, el, n) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers.removeValue(forKey: bid)
        elements.removeValue(forKey: bid)
        contexts.removeValue(forKey: bid)
    }
}

// MARK: - Settings Window

class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var appTableView: NSTableView!
    private var termTableView: NSTableView!
    private let inputSources = listInputSources()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "TermIMS Settings"
        w.center()
        w.minSize = NSSize(width: 520, height: 380)
        w.isReleasedWhenClosed = false
        self.init(window: w)
        buildUI()
    }

    // MARK: Tab Builder

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
        ])

        let t1 = NSTabViewItem(identifier: "general"); t1.label = "General"
        t1.view = buildGeneralTab()
        let t2 = NSTabViewItem(identifier: "apps"); t2.label = "App Rules"
        t2.view = buildAppRulesTab()
        let t3 = NSTabViewItem(identifier: "terminal"); t3.label = "Terminal Rules"
        t3.view = buildTerminalRulesTab()

        tabView.addTabViewItem(t1)
        tabView.addTabViewItem(t2)
        tabView.addTabViewItem(t3)

        appTableView.dataSource = self; appTableView.delegate = self
        termTableView.dataSource = self; termTableView.delegate = self
    }

    // MARK: General Tab

    private func buildGeneralTab() -> NSView {
        let v = NSView()
        let store = RuleStore.shared

        let defLabel = label("Default Input Method:")
        let defPopup = imPopup(selected: store.defaultSourceID, includeNone: true)
        defPopup.tag = 900
        defPopup.target = self; defPopup.action = #selector(defaultIMChanged(_:))

        let sep1 = separator()
        let indLabel = label("Indicator")
        indLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let indCheck = NSButton(checkboxWithTitle: "Show input method indicator on switch",
                                target: self, action: #selector(indicatorToggled(_:)))
        indCheck.translatesAutoresizingMaskIntoConstraints = false
        indCheck.state = store.indicatorEnabled ? .on : .off

        let posLabel = label("Position:")
        let posPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        posPopup.translatesAutoresizingMaskIntoConstraints = false
        for p in IndicatorPosition.allCases { posPopup.addItem(withTitle: p.rawValue) }
        if let idx = IndicatorPosition.allCases.firstIndex(of: store.indicatorPosition) {
            posPopup.selectItem(at: idx)
        }
        posPopup.target = self; posPopup.action = #selector(indicatorPosChanged(_:))

        let sep2 = separator()
        let appLabel = label("Application")
        appLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let hideCheck = NSButton(checkboxWithTitle: "Hide menu bar icon (reopen app to show Settings)",
                                 target: self, action: #selector(hideIconToggled(_:)))
        hideCheck.translatesAutoresizingMaskIntoConstraints = false
        hideCheck.state = store.hideMenuBarIcon ? .on : .off

        for sub in [defLabel, defPopup, sep1, indLabel, indCheck, posLabel, posPopup,
                    sep2, appLabel, hideCheck] { v.addSubview(sub) }
        NSLayoutConstraint.activate([
            defLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            defLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            defPopup.centerYAnchor.constraint(equalTo: defLabel.centerYAnchor),
            defPopup.leadingAnchor.constraint(equalTo: defLabel.trailingAnchor, constant: 8),
            defPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            sep1.topAnchor.constraint(equalTo: defLabel.bottomAnchor, constant: 20),
            sep1.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            sep1.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            indLabel.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 16),
            indLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            indCheck.topAnchor.constraint(equalTo: indLabel.bottomAnchor, constant: 10),
            indCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            posLabel.topAnchor.constraint(equalTo: indCheck.bottomAnchor, constant: 12),
            posLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            posPopup.centerYAnchor.constraint(equalTo: posLabel.centerYAnchor),
            posPopup.leadingAnchor.constraint(equalTo: posLabel.trailingAnchor, constant: 8),
            posPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            sep2.topAnchor.constraint(equalTo: posLabel.bottomAnchor, constant: 20),
            sep2.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            sep2.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            appLabel.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 16),
            appLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            hideCheck.topAnchor.constraint(equalTo: appLabel.bottomAnchor, constant: 10),
            hideCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
        ])
        return v
    }

    @objc private func defaultIMChanged(_ sender: NSPopUpButton) {
        let store = RuleStore.shared
        if sender.indexOfSelectedItem == 0 {
            store.defaultSourceName = nil; store.defaultSourceID = nil
        } else {
            let src = inputSources[sender.indexOfSelectedItem - 1]
            store.defaultSourceName = src.name; store.defaultSourceID = src.id
        }
    }
    @objc private func indicatorToggled(_ sender: NSButton) {
        RuleStore.shared.indicatorEnabled = sender.state == .on
    }
    @objc private func indicatorPosChanged(_ sender: NSPopUpButton) {
        RuleStore.shared.indicatorPosition = IndicatorPosition.allCases[sender.indexOfSelectedItem]
    }
    @objc private func hideIconToggled(_ sender: NSButton) {
        RuleStore.shared.hideMenuBarIcon = sender.state == .on
    }

    // MARK: App Rules Tab

    private func buildAppRulesTab() -> NSView {
        let v = NSView()
        let sv = scrolledTable(&appTableView)
        let addBtn = smallButton("+", action: #selector(addAppRule))
        let rmBtn  = smallButton("\u{2212}", action: #selector(removeAppRule))
        for sub in [sv, addBtn, rmBtn] { v.addSubview(sub) }
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            sv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            sv.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            sv.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -6),
            addBtn.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            addBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            rmBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor),
            rmBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        return v
    }

    @objc private func addAppRule() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for: window!) { resp in
            guard resp == .OK, let url = panel.url, let b = Bundle(url: url),
                  let bid = b.bundleIdentifier else { return }
            var rules = RuleStore.shared.rules
            if rules.contains(where: { $0.appBundleID == bid }) { return }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let im = self.inputSources.first { $0.id.contains("ABC") } ?? self.inputSources.first
                     ?? IMSource(id: "com.apple.keylayout.ABC", name: "ABC")
            rules.append(Rule(appBundleID: bid, appName: name, inputSourceID: im.id, inputSourceName: im.name))
            RuleStore.shared.rules = rules
            self.appTableView.reloadData()
        }
    }
    @objc private func removeAppRule() {
        let r = appTableView.selectedRow; guard r >= 0 else { return }
        var rules = RuleStore.shared.rules; rules.remove(at: r)
        RuleStore.shared.rules = rules; appTableView.reloadData()
    }

    // MARK: Terminal Rules Tab

    private func buildTerminalRulesTab() -> NSView {
        let v = NSView()
        let store = RuleStore.shared

        let defLabel = label("Default Input Method (in terminal):")
        let defPopup = imPopup(selected: store.terminalDefaultSourceID, includeNone: true)
        defPopup.tag = 901
        defPopup.target = self; defPopup.action = #selector(termDefaultIMChanged(_:))

        let hintLabel = label("When a terminal tab matches a rule below, switch to that rule's input method instead:")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let sv = scrolledTermTable(&termTableView)
        let addBtn = smallButton("+", action: #selector(addTermRule))
        let rmBtn  = smallButton("\u{2212}", action: #selector(removeTermRule))

        for sub in [defLabel, defPopup, hintLabel, sv, addBtn, rmBtn] { v.addSubview(sub) }
        NSLayoutConstraint.activate([
            defLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            defLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            defPopup.centerYAnchor.constraint(equalTo: defLabel.centerYAnchor),
            defPopup.leadingAnchor.constraint(equalTo: defLabel.trailingAnchor, constant: 8),
            defPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            hintLabel.topAnchor.constraint(equalTo: defLabel.bottomAnchor, constant: 10),
            hintLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            sv.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 8),
            sv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            sv.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            sv.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -6),
            addBtn.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            addBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            rmBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor),
            rmBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        return v
    }

    @objc private func termDefaultIMChanged(_ sender: NSPopUpButton) {
        let store = RuleStore.shared
        if sender.indexOfSelectedItem == 0 {
            store.terminalDefaultSourceName = nil; store.terminalDefaultSourceID = nil
        } else {
            let src = inputSources[sender.indexOfSelectedItem - 1]
            store.terminalDefaultSourceName = src.name; store.terminalDefaultSourceID = src.id
        }
    }

    @objc private func addTermRule() {
        let im = inputSources.first { $0.id.contains("ABC") } ?? inputSources.first
                 ?? IMSource(id: "com.apple.keylayout.ABC", name: "ABC")
        var rules = RuleStore.shared.terminalRules
        rules.append(TerminalRule(inputSourceID: im.id, inputSourceName: im.name))
        RuleStore.shared.terminalRules = rules
        termTableView.reloadData()
    }

    @objc private func removeTermRule() {
        let r = termTableView.selectedRow; guard r >= 0 else { return }
        var rules = RuleStore.shared.terminalRules; rules.remove(at: r)
        RuleStore.shared.terminalRules = rules; termTableView.reloadData()
    }

    private func scrolledTermTable(_ tv: inout NSTableView!) -> NSScrollView {
        let sv = NSScrollView(); sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true; tv.rowHeight = 24
        let colOn = NSTableColumn(identifier: .init("ton")); colOn.title = ""; colOn.width = 30; colOn.minWidth = 30; colOn.maxWidth = 30
        let colType = NSTableColumn(identifier: .init("ttype")); colType.title = "Match"; colType.width = 100; colType.minWidth = 80
        let colPat = NSTableColumn(identifier: .init("tpat")); colPat.title = "Pattern"; colPat.width = 160; colPat.minWidth = 80
        let colIM = NSTableColumn(identifier: .init("tim")); colIM.title = "Input Method"; colIM.width = 180; colIM.minWidth = 120
        tv.addTableColumn(colOn); tv.addTableColumn(colType); tv.addTableColumn(colPat); tv.addTableColumn(colIM)
        sv.documentView = tv; return sv
    }

    // MARK: Table DataSource / Delegate

    func numberOfRows(in tv: NSTableView) -> Int {
        if tv === termTableView { return RuleStore.shared.terminalRules.count }
        return RuleStore.shared.rules.count
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if tv === termTableView { return termTableCellView(col, row: row) }
        let rules = RuleStore.shared.rules
        guard row < rules.count else { return nil }
        let rule = rules[row]
        switch col?.identifier.rawValue {
        case "on":
            let btn = recycledCheckbox(tv, id: "aon")
            btn.state = rule.enabled ? .on : .off; btn.tag = row
            btn.target = self; btn.action = #selector(appToggle(_:))
            return btn
        case "app":
            let cell = recycledAppCell(tv)
            cell.textField?.stringValue = rule.appName
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.appBundleID) {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                cell.imageView?.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            }
            return cell
        case "im":
            let popup = recycledIMPopup(tv, id: "aim")
            configureIMPopup(popup, selected: rule.inputSourceID, row: row)
            popup.target = self; popup.action = #selector(appIMChanged(_:))
            return popup
        default: return nil
        }
    }

    private func centeredCellView(_ tv: NSTableView, id: String, control: NSView) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(id + "cell")
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            control.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func termTableCellView(_ col: NSTableColumn?, row: Int) -> NSView? {
        let rules = RuleStore.shared.terminalRules
        guard row < rules.count else { return nil }
        let rule = rules[row]
        switch col?.identifier.rawValue {
        case "ton":
            let btn = recycledCheckbox(termTableView, id: "ton")
            btn.state = rule.enabled ? .on : .off; btn.tag = row
            btn.target = self; btn.action = #selector(termToggle(_:))
            return centeredCellView(termTableView, id: "ton\(row)", control: btn)
        case "ttype":
            let popup = recycledMatchTypePopup(termTableView)
            popup.removeAllItems()
            for t in TerminalMatchType.allCases { popup.addItem(withTitle: t.rawValue) }
            if let idx = TerminalMatchType.allCases.firstIndex(of: rule.matchType) { popup.selectItem(at: idx) }
            popup.tag = row
            popup.target = self; popup.action = #selector(termMatchTypeChanged(_:))
            return centeredCellView(termTableView, id: "ttype\(row)", control: popup)
        case "tpat":
            let tf = recycledPatternField(termTableView)
            tf.stringValue = rule.pattern; tf.tag = row
            tf.target = self; tf.action = #selector(termPatternChanged(_:))
            return centeredCellView(termTableView, id: "tpat\(row)", control: tf)
        case "tim":
            let popup = recycledIMPopup(termTableView, id: "tim")
            configureIMPopup(popup, selected: rule.inputSourceID, row: row)
            popup.target = self; popup.action = #selector(termIMChanged(_:))
            return centeredCellView(termTableView, id: "tim\(row)", control: popup)
        default: return nil
        }
    }

    // MARK: Table Actions

    @objc private func appToggle(_ s: NSButton) {
        var r = RuleStore.shared.rules; guard s.tag < r.count else { return }
        r[s.tag].enabled = s.state == .on; RuleStore.shared.rules = r
    }
    @objc private func appIMChanged(_ s: NSPopUpButton) {
        var r = RuleStore.shared.rules
        guard s.tag < r.count, let item = s.selectedItem, let sid = item.representedObject as? String else { return }
        r[s.tag].inputSourceID = sid; r[s.tag].inputSourceName = item.title; RuleStore.shared.rules = r
    }

    @objc private func termToggle(_ s: NSButton) {
        var r = RuleStore.shared.terminalRules; guard s.tag < r.count else { return }
        r[s.tag].enabled = s.state == .on; RuleStore.shared.terminalRules = r
    }
    @objc private func termMatchTypeChanged(_ s: NSPopUpButton) {
        var r = RuleStore.shared.terminalRules; guard s.tag < r.count else { return }
        r[s.tag].matchType = TerminalMatchType.allCases[s.indexOfSelectedItem]
        RuleStore.shared.terminalRules = r
    }
    @objc private func termPatternChanged(_ s: NSTextField) {
        var r = RuleStore.shared.terminalRules; guard s.tag < r.count else { return }
        r[s.tag].pattern = s.stringValue; RuleStore.shared.terminalRules = r
    }
    @objc private func termIMChanged(_ s: NSPopUpButton) {
        var r = RuleStore.shared.terminalRules
        guard s.tag < r.count, let item = s.selectedItem, let sid = item.representedObject as? String else { return }
        r[s.tag].inputSourceID = sid; r[s.tag].inputSourceName = item.title; RuleStore.shared.terminalRules = r
    }

    // MARK: View Factories

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.translatesAutoresizingMaskIntoConstraints = false; l.font = .systemFont(ofSize: 13)
        return l
    }
    private func separator() -> NSBox {
        let b = NSBox(); b.translatesAutoresizingMaskIntoConstraints = false; b.boxType = .separator; return b
    }
    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.translatesAutoresizingMaskIntoConstraints = false; b.bezelStyle = .smallSquare
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private func imPopup(selected sid: String?, includeNone: Bool) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.translatesAutoresizingMaskIntoConstraints = false
        if includeNone { p.addItem(withTitle: "None"); p.lastItem?.representedObject = nil }
        for src in inputSources { p.addItem(withTitle: src.name); p.lastItem?.representedObject = src.id }
        if let sid, let idx = inputSources.firstIndex(where: { $0.id == sid }) {
            p.selectItem(at: idx + (includeNone ? 1 : 0))
        } else if includeNone { p.selectItem(at: 0) }
        return p
    }

    private func scrolledTable(_ tv: inout NSTableView!) -> NSScrollView {
        let sv = NSScrollView(); sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true; tv.rowHeight = 24
        let colOn = NSTableColumn(identifier: .init("on")); colOn.title = ""; colOn.width = 30; colOn.minWidth = 30; colOn.maxWidth = 30
        let colApp = NSTableColumn(identifier: .init("app")); colApp.title = "Application"; colApp.width = 200; colApp.minWidth = 120
        let colIM = NSTableColumn(identifier: .init("im")); colIM.title = "Input Method"; colIM.width = 200; colIM.minWidth = 120
        tv.addTableColumn(colOn); tv.addTableColumn(colApp); tv.addTableColumn(colIM)
        sv.documentView = tv; return sv
    }

    private func recycledCheckbox(_ tv: NSTableView, id: String) -> NSButton {
        let uid = NSUserInterfaceItemIdentifier(id)
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSButton { return v }
        let b = NSButton(checkboxWithTitle: "", target: nil, action: nil); b.identifier = uid; return b
    }

    private func recycledAppCell(_ tv: NSTableView) -> NSTableCellView {
        let uid = NSUserInterfaceItemIdentifier("appcell")
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSTableCellView { return v }
        let v = NSTableCellView(); v.identifier = uid
        let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false; tf.lineBreakMode = .byTruncatingTail
        v.addSubview(iv); v.addSubview(tf); v.imageView = iv; v.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 20), iv.heightAnchor.constraint(equalToConstant: 20),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    private func recycledIMPopup(_ tv: NSTableView, id: String) -> NSPopUpButton {
        let uid = NSUserInterfaceItemIdentifier(id)
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSPopUpButton { return v }
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.identifier = uid; p.controlSize = .small; p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return p
    }

    private func recycledMatchTypePopup(_ tv: NSTableView) -> NSPopUpButton {
        let uid = NSUserInterfaceItemIdentifier("tmtype")
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSPopUpButton { return v }
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.identifier = uid; p.controlSize = .small; p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return p
    }

    private func recycledPatternField(_ tv: NSTableView) -> NSTextField {
        let uid = NSUserInterfaceItemIdentifier("tpat")
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSTextField { return v }
        let tf = NSTextField()
        tf.identifier = uid; tf.controlSize = .small; tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.placeholderString = "e.g. claude, nvim"
        tf.lineBreakMode = .byTruncatingTail; tf.cell?.sendsActionOnEndEditing = true
        return tf
    }

    private func configureIMPopup(_ popup: NSPopUpButton, selected sid: String, row: Int) {
        popup.removeAllItems()
        for src in inputSources { popup.addItem(withTitle: src.name); popup.lastItem?.representedObject = src.id }
        if let idx = inputSources.firstIndex(where: { $0.id == sid }) { popup.selectItem(at: idx) }
        popup.tag = row
    }
}

// MARK: - Permission Window

class PermissionWindowController: NSWindowController {
    private var pollTimer: Timer?
    var onGranted: (() -> Void)?

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "TermIMS"
        w.center()
        w.isReleasedWhenClosed = false
        self.init(window: w)
        buildUI()
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 36, weight: .light)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Accessibility Permission Required")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let desc = NSTextField(wrappingLabelWithString:
            "TermIMS needs accessibility access to detect app switches and change input methods. Please enable it in System Settings > Privacy & Security > Accessibility.")
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor

        let openBtn = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        openBtn.translatesAutoresizingMaskIntoConstraints = false
        openBtn.bezelStyle = .rounded
        openBtn.keyEquivalent = "\r"

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        quitBtn.bezelStyle = .rounded

        for sub in [icon, title, desc, openBtn, quitBtn] { cv.addSubview(sub) }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: cv.topAnchor, constant: 24),
            icon.centerXAnchor.constraint(equalTo: cv.centerXAnchor),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: cv.centerXAnchor),

            desc.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            desc.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 32),
            desc.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -32),

            openBtn.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 16),
            openBtn.trailingAnchor.constraint(equalTo: cv.centerXAnchor, constant: -6),
            openBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),

            quitBtn.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 16),
            quitBtn.leadingAnchor.constraint(equalTo: cv.centerXAnchor, constant: 6),
            quitBtn.widthAnchor.constraint(equalTo: openBtn.widthAnchor),
        ])
    }

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
                self?.window?.close()
                self?.onGranted?()
            }
        }
    }

    @objc private func openSettings() {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - App Delegate

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
        if AXIsProcessTrusted() {
            wasTrusted = true
            startApp()
        } else {
            showPermissionWindow()
        }
        startPermissionPolling()
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

        if !store.rules.isEmpty { menu.addItem(.separator()) }
        for rule in store.rules {
            let s = rule.enabled ? "\u{2713}" : "\u{2717}"
            let item = NSMenuItem(title: "\(s)  \(rule.appName) \u{2192} \(rule.inputSourceName)", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }

        let termRules = store.terminalRules.filter(\.enabled)
        if !termRules.isEmpty {
            menu.addItem(.separator())
            let hdr = NSMenuItem(title: "Terminal Rules", action: nil, keyEquivalent: "")
            hdr.isEnabled = false; menu.addItem(hdr)
            for rule in termRules {
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

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
