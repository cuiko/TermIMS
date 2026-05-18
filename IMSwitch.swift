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

struct DomainRule: Codable {
    var enabled: Bool = true
    var domainPattern: String
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

extension Notification.Name {
    static let rulesDidChange = Notification.Name("RulesDidChange")
    static let imDidSwitch    = Notification.Name("IMDidSwitch")
}

let browserIDs: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
    "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    "com.mozilla.firefox", "org.mozilla.firefox",
    "company.thebrowser.Browser",
    "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
    "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
]

// MARK: - Rule Store

class RuleStore {
    static let shared = RuleStore()
    private let ud = UserDefaults.standard

    private func notify() {
        NotificationCenter.default.post(name: .rulesDidChange, object: nil)
    }

    var rules: [Rule] {
        get { decode("IMSwitchRules") ?? [] }
        set { encode(newValue, "IMSwitchRules"); notify() }
    }

    var domainRules: [DomainRule] {
        get { decode("IMSwitchDomainRules") ?? [] }
        set { encode(newValue, "IMSwitchDomainRules"); notify() }
    }

    var defaultSourceID: String? {
        get { ud.string(forKey: "DefaultSourceID") }
        set { ud.set(newValue, forKey: "DefaultSourceID"); notify() }
    }
    var defaultSourceName: String? {
        get { ud.string(forKey: "DefaultSourceName") }
        set { ud.set(newValue, forKey: "DefaultSourceName") }
    }

    var addressBarSourceID: String? {
        get { ud.string(forKey: "AddressBarSourceID") }
        set { ud.set(newValue, forKey: "AddressBarSourceID"); notify() }
    }
    var addressBarSourceName: String? {
        get { ud.string(forKey: "AddressBarSourceName") }
        set { ud.set(newValue, forKey: "AddressBarSourceName") }
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

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = ud.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func encode<T: Encodable>(_ val: T, _ key: String) {
        ud.set(try? JSONEncoder().encode(val), forKey: key)
    }
}

// MARK: - Browser Helpers

func extractBrowserURL(_ appEl: AXUIElement) -> String? {
    var winRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success else { return nil }
    let win = winRef as! AXUIElement

    var docRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(win, "AXDocument" as CFString, &docRef) == .success,
       let url = docRef as? String, !url.isEmpty { return url }

    if let bar = findAddressBar(win, depth: 0) {
        var valRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &valRef) == .success,
           let url = valRef as? String, !url.isEmpty { return url }
    }
    return nil
}

func findAddressBar(_ el: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth < 6 else { return nil }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    let r = role as? String ?? ""
    if r == "AXWebArea" { return nil }
    if r == "AXTextField" || r == "AXSearchField" || r == "AXComboBox" {
        var desc: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &desc)
        let d = (desc as? String ?? "").lowercased()
        if d.contains("address") || d.contains("url") || d.contains("location") || d.contains("search") {
            return el
        }
    }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
          let kids = children as? [AXUIElement] else { return nil }
    for kid in kids {
        if let found = findAddressBar(kid, depth: depth + 1) { return found }
    }
    return nil
}

func isAddressBarFocused(_ appEl: AXUIElement) -> Bool {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &ref) == .success else { return false }
    let el = ref as! AXUIElement
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    let r = role as? String ?? ""
    guard r == "AXTextField" || r == "AXSearchField" || r == "AXComboBox" else { return false }
    var parent = el as CFTypeRef
    for _ in 0..<10 {
        var p: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXParentAttribute as CFString, &p) == .success else { break }
        var pRole: CFTypeRef?
        AXUIElementCopyAttributeValue(p as! AXUIElement, kAXRoleAttribute as CFString, &pRole)
        if (pRole as? String) == "AXWebArea" { return false }
        parent = p!
    }
    return true
}

func matchDomain(url: String, pattern: String) -> Bool {
    let normalized = url.hasPrefix("http") ? url : "https://\(url)"
    guard let host = URL(string: normalized)?.host else { return false }
    let p = pattern.lowercased()
    let h = host.lowercased()
    if p.hasPrefix("*.") {
        let suffix = String(p.dropFirst(2))
        return h == suffix || h.hasSuffix(".\(suffix)")
    }
    return h == p || h.hasSuffix(".\(p)")
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

        let bg = NSVisualEffectView(frame: contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
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
        let margin: CGFloat = 40
        let pt: NSPoint
        switch position {
        case .screenCenter:
            pt = NSPoint(x: s.frame.midX - w / 2, y: s.frame.midY - h / 2)
        case .centerBottom:
            pt = NSPoint(x: s.frame.midX - w / 2, y: s.frame.minY + margin)
        case .topLeft:
            pt = NSPoint(x: s.frame.minX + margin, y: s.frame.maxY - h - margin)
        case .topRight:
            pt = NSPoint(x: s.frame.maxX - w - margin, y: s.frame.maxY - h - margin)
        case .bottomLeft:
            pt = NSPoint(x: s.frame.minX + margin, y: s.frame.minY + margin)
        case .bottomRight:
            pt = NSPoint(x: s.frame.maxX - w - margin, y: s.frame.minY + margin)
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
    private var titleDebounce: Timer?

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
        for bid in Array(observers.keys) { detach(bid) }
    }

    @objc func reload() {
        let appIDs  = Set(RuleStore.shared.rules.filter(\.enabled).map(\.appBundleID))
        let needAX  = appIDs.union(browserIDs)
        for bid in observers.keys where !needAX.contains(bid) { detach(bid) }
        for bid in needAX where observers[bid] == nil { attach(bid) }
    }

    func resolveInputSource(for bid: String) -> String? {
        let store = RuleStore.shared
        if let rule = store.rules.first(where: { $0.enabled && $0.appBundleID == bid }) {
            return rule.inputSourceID
        }
        return store.defaultSourceID
    }

    func handleWindowFocus(_ bid: String) {
        guard enabled else { return }
        if browserIDs.contains(bid) {
            applyBrowserRules(bid)
        } else if let id = resolveInputSource(for: bid) {
            selectInputSource(id)
        }
    }

    func handleElementFocus(_ bid: String) {
        guard enabled, browserIDs.contains(bid), let el = elements[bid] else { return }
        let store = RuleStore.shared
        if isAddressBarFocused(el), let abID = store.addressBarSourceID {
            selectInputSource(abID)
        } else {
            applyBrowserRules(bid)
        }
    }

    func handleTitleChange(_ bid: String) {
        guard enabled, browserIDs.contains(bid) else { return }
        titleDebounce?.invalidate()
        titleDebounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.applyBrowserRules(bid)
        }
    }

    private func applyBrowserRules(_ bid: String) {
        let store = RuleStore.shared
        if let el = elements[bid], let url = extractBrowserURL(el) {
            for dr in store.domainRules where dr.enabled {
                if matchDomain(url: url, pattern: dr.domainPattern) {
                    selectInputSource(dr.inputSourceID)
                    return
                }
            }
        }
        if let id = resolveInputSource(for: bid) {
            selectInputSource(id)
        }
    }

    @objc private func activated(_ n: Notification) {
        guard enabled, let bid = bundleID(from: n) else { return }
        if browserIDs.contains(bid) && observers[bid] == nil { attach(bid) }
        handleWindowFocus(bid)
    }

    @objc private func launched(_ n: Notification) {
        guard let bid = bundleID(from: n) else { return }
        let store = RuleStore.shared
        if store.rules.contains(where: { $0.enabled && $0.appBundleID == bid }) || browserIDs.contains(bid) {
            attach(bid)
        }
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

        let cb: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let c = Unmanaged<AXContext>.fromOpaque(refcon).takeUnretainedValue()
            guard let m = c.monitor, m.enabled else { return }
            let n = notification as String
            if n == kAXFocusedUIElementChangedNotification as String {
                m.handleElementFocus(c.bundleID)
            } else if n == kAXTitleChangedNotification as String {
                m.handleTitleChange(c.bundleID)
            } else {
                m.handleWindowFocus(c.bundleID)
            }
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, cb, &obs) == .success, let observer = obs else { return }
        observers[bid] = observer

        var notifs = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] as [CFString]
        if browserIDs.contains(bid) {
            notifs += [kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification] as [CFString]
        }
        for name in notifs { AXObserverAddNotification(observer, el, name, ptr) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func detach(_ bid: String) {
        guard let obs = observers[bid], let el = elements[bid] else { return }
        let allNotifs = [
            kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
            kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification,
        ] as [CFString]
        for n in allNotifs { AXObserverRemoveNotification(obs, el, n) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers.removeValue(forKey: bid)
        elements.removeValue(forKey: bid)
        contexts.removeValue(forKey: bid)
    }
}

// MARK: - Settings Window

class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var appTableView: NSTableView!
    private var domainTableView: NSTableView!
    private let inputSources = listInputSources()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "IMSwitch Settings"
        w.center()
        w.minSize = NSSize(width: 480, height: 380)
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
        let t3 = NSTabViewItem(identifier: "browser"); t3.label = "Browser"
        t3.view = buildBrowserTab()

        tabView.addTabViewItem(t1)
        tabView.addTabViewItem(t2)
        tabView.addTabViewItem(t3)

        appTableView.dataSource = self; appTableView.delegate = self
        domainTableView.dataSource = self; domainTableView.delegate = self
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
        let sv = scrolledTable(&appTableView, id: "app")
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

    // MARK: Browser Tab

    private func buildBrowserTab() -> NSView {
        let v = NSView()
        let store = RuleStore.shared

        let abLabel = label("Address Bar Input Method:")
        let abPopup = imPopup(selected: store.addressBarSourceID, includeNone: true)
        abPopup.tag = 901
        abPopup.target = self; abPopup.action = #selector(addressBarIMChanged(_:))

        let sep = separator()
        let drLabel = label("Domain Rules:")
        drLabel.font = .systemFont(ofSize: 11); drLabel.textColor = .secondaryLabelColor

        let sv = NSScrollView(); sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        domainTableView = NSTableView()
        domainTableView.usesAlternatingRowBackgroundColors = true; domainTableView.rowHeight = 28
        let colOn = NSTableColumn(identifier: .init("don")); colOn.title = ""; colOn.width = 30; colOn.minWidth = 30; colOn.maxWidth = 30
        let colDom = NSTableColumn(identifier: .init("domain")); colDom.title = "Domain"; colDom.width = 200; colDom.minWidth = 100
        let colIM = NSTableColumn(identifier: .init("dim")); colIM.title = "Input Method"; colIM.width = 180; colIM.minWidth = 120
        domainTableView.addTableColumn(colOn); domainTableView.addTableColumn(colDom); domainTableView.addTableColumn(colIM)
        sv.documentView = domainTableView

        let addBtn = smallButton("+", action: #selector(addDomainRule))
        let rmBtn  = smallButton("\u{2212}", action: #selector(removeDomainRule))
        for sub in [abLabel, abPopup, sep, drLabel, sv, addBtn, rmBtn] { v.addSubview(sub) }
        NSLayoutConstraint.activate([
            abLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            abLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            abPopup.centerYAnchor.constraint(equalTo: abLabel.centerYAnchor),
            abPopup.leadingAnchor.constraint(equalTo: abLabel.trailingAnchor, constant: 8),
            abPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            sep.topAnchor.constraint(equalTo: abLabel.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            sep.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            drLabel.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            drLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            sv.topAnchor.constraint(equalTo: drLabel.bottomAnchor, constant: 6),
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

    @objc private func addressBarIMChanged(_ sender: NSPopUpButton) {
        let store = RuleStore.shared
        if sender.indexOfSelectedItem == 0 {
            store.addressBarSourceName = nil; store.addressBarSourceID = nil
        } else {
            let src = inputSources[sender.indexOfSelectedItem - 1]
            store.addressBarSourceName = src.name; store.addressBarSourceID = src.id
        }
    }

    @objc private func addDomainRule() {
        let alert = NSAlert()
        alert.messageText = "Add Domain Rule"
        alert.informativeText = "Enter a domain pattern (e.g. github.com, *.google.com):"
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "example.com"
        alert.accessoryView = input
        alert.beginSheetModal(for: window!) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let domain = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !domain.isEmpty else { return }
            var dr = RuleStore.shared.domainRules
            let im = self.inputSources.first { $0.id.contains("ABC") } ?? self.inputSources.first
                     ?? IMSource(id: "com.apple.keylayout.ABC", name: "ABC")
            dr.append(DomainRule(domainPattern: domain, inputSourceID: im.id, inputSourceName: im.name))
            RuleStore.shared.domainRules = dr
            self.domainTableView.reloadData()
        }
    }
    @objc private func removeDomainRule() {
        let r = domainTableView.selectedRow; guard r >= 0 else { return }
        var dr = RuleStore.shared.domainRules; dr.remove(at: r)
        RuleStore.shared.domainRules = dr; domainTableView.reloadData()
    }

    // MARK: Table DataSource / Delegate

    func numberOfRows(in tv: NSTableView) -> Int {
        if tv === appTableView { return RuleStore.shared.rules.count }
        if tv === domainTableView { return RuleStore.shared.domainRules.count }
        return 0
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if tv === appTableView { return appCell(col, row) }
        if tv === domainTableView { return domainCell(col, row) }
        return nil
    }

    // App table cells
    private func appCell(_ col: NSTableColumn?, _ row: Int) -> NSView? {
        let rules = RuleStore.shared.rules
        guard row < rules.count else { return nil }
        let rule = rules[row]
        switch col?.identifier.rawValue {
        case "on":
            let btn = recycledCheckbox(appTableView, id: "aon")
            btn.state = rule.enabled ? .on : .off; btn.tag = row
            btn.target = self; btn.action = #selector(appToggle(_:))
            return btn
        case "app":
            let cell = recycledAppCell(appTableView)
            cell.textField?.stringValue = rule.appName
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.appBundleID) {
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                cell.imageView?.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            }
            return cell
        case "im":
            let popup = recycledIMPopup(appTableView, id: "aim")
            configureIMPopup(popup, selected: rule.inputSourceID, row: row)
            popup.target = self; popup.action = #selector(appIMChanged(_:))
            return popup
        default: return nil
        }
    }

    // Domain table cells
    private func domainCell(_ col: NSTableColumn?, _ row: Int) -> NSView? {
        let dr = RuleStore.shared.domainRules
        guard row < dr.count else { return nil }
        let rule = dr[row]
        switch col?.identifier.rawValue {
        case "don":
            let btn = recycledCheckbox(domainTableView, id: "don")
            btn.state = rule.enabled ? .on : .off; btn.tag = row
            btn.target = self; btn.action = #selector(domainToggle(_:))
            return btn
        case "domain":
            let id = NSUserInterfaceItemIdentifier("domtf")
            let tf: NSTextField
            if let v = domainTableView.makeView(withIdentifier: id, owner: nil) as? NSTextField { tf = v }
            else {
                tf = NSTextField(); tf.identifier = id
                tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                tf.isBordered = false; tf.drawsBackground = false
            }
            tf.stringValue = rule.domainPattern; tf.tag = row
            tf.target = self; tf.action = #selector(domainPatternChanged(_:))
            return tf
        case "dim":
            let popup = recycledIMPopup(domainTableView, id: "dim")
            configureIMPopup(popup, selected: rule.inputSourceID, row: row)
            popup.target = self; popup.action = #selector(domainIMChanged(_:))
            return popup
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
    @objc private func domainToggle(_ s: NSButton) {
        var r = RuleStore.shared.domainRules; guard s.tag < r.count else { return }
        r[s.tag].enabled = s.state == .on; RuleStore.shared.domainRules = r
    }
    @objc private func domainPatternChanged(_ s: NSTextField) {
        var r = RuleStore.shared.domainRules; guard s.tag < r.count else { return }
        r[s.tag].domainPattern = s.stringValue; RuleStore.shared.domainRules = r
    }
    @objc private func domainIMChanged(_ s: NSPopUpButton) {
        var r = RuleStore.shared.domainRules
        guard s.tag < r.count, let item = s.selectedItem, let sid = item.representedObject as? String else { return }
        r[s.tag].inputSourceID = sid; r[s.tag].inputSourceName = item.title; RuleStore.shared.domainRules = r
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

    private func scrolledTable(_ tv: inout NSTableView!, id: String) -> NSScrollView {
        let sv = NSScrollView(); sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true; tv.rowHeight = 30
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

    private func configureIMPopup(_ popup: NSPopUpButton, selected sid: String, row: Int) {
        popup.removeAllItems()
        for src in inputSources { popup.addItem(withTitle: src.name); popup.lastItem?.representedObject = src.id }
        if let idx = inputSources.firstIndex(where: { $0.id == sid }) { popup.selectItem(at: idx) }
        popup.tag = row
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let monitor = FocusMonitor()
    private let indicator = IndicatorPanel()
    private var settingsWC: SettingsWindowController?
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.user.imswitch.plist"
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

        applyMenuBarVisibility()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildMenu),
                                               name: .rulesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(imDidSwitch),
                                               name: .imDidSwitch, object: nil)
        monitor.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
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
                    btn.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "IMSwitch")
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

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self; enabledItem.state = monitor.enabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(.separator())

        let defName = store.defaultSourceName ?? "None"
        let defItem = NSMenuItem(title: "Default: \(defName)", action: nil, keyEquivalent: "")
        defItem.isEnabled = false; menu.addItem(defItem)

        if let abName = store.addressBarSourceName {
            let abItem = NSMenuItem(title: "Address Bar: \(abName)", action: nil, keyEquivalent: "")
            abItem.isEnabled = false; menu.addItem(abItem)
        }

        if !store.rules.isEmpty || !store.domainRules.isEmpty { menu.addItem(.separator()) }
        for rule in store.rules {
            let s = rule.enabled ? "\u{2713}" : "\u{2717}"
            let item = NSMenuItem(title: "\(s)  \(rule.appName) \u{2192} \(rule.inputSourceName)", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
        for dr in store.domainRules {
            let s = dr.enabled ? "\u{2713}" : "\u{2717}"
            let item = NSMenuItem(title: "\(s)  \(dr.domainPattern) \u{2192} \(dr.inputSourceName)", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
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
        let quit = NSMenuItem(title: "Quit IMSwitch", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        monitor.enabled.toggle(); enabledItem.state = monitor.enabled ? .on : .off
    }
    @objc private func showSettings() {
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
                "Label": "com.user.imswitch",
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
