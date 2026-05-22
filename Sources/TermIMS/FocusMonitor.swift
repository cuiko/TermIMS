import Cocoa
import ApplicationServices

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
        let result: (String?, String)
        if isTerminalWithRules(bid) {
            if let matched = matchTerminalRule(bid: bid, store: store) {
                result = (matched, "terminal-rule")
            } else if let termDefault = store.terminalDefaultSourceID {
                result = (termDefault, "terminal-default")
            } else if let rule = store.rules.first(where: { $0.enabled && $0.appBundleID == bid }) {
                result = (rule.inputSourceID, "app-rule")
            } else {
                result = (store.defaultSourceID, "global-default")
            }
        } else if let rule = store.rules.first(where: { $0.enabled && $0.appBundleID == bid }) {
            result = (rule.inputSourceID, "app-rule")
        } else {
            result = (store.defaultSourceID, "global-default")
        }
        Log.debug("MATCH RESULT bid=\(bid) source=\(result.0 ?? "nil") via=\(result.1)")
        return result.0
    }

    private func matchTerminalRule(bid: String, store: RuleStore) -> String? {
        Log.debug("MATCH START bid=\(bid)")
        let rules = store.terminalRules.filter(\.enabled)
        guard !rules.isEmpty else { return nil }

        let titleRules = rules.filter { $0.matchType == .title }
        let processRules = rules.filter { $0.matchType == .process }

        if !titleRules.isEmpty, let title = getFocusedWindowTitle(bid: bid) {
            for rule in titleRules where !rule.pattern.isEmpty {
                if title.matches(pattern: rule.pattern) {
                    Log.debug("TITLE RULE HIT: pattern=\(rule.pattern) title=\(title)")
                    return rule.inputSourceID
                }
            }
        }

        if !processRules.isEmpty {
            let candidates = getTerminalCandidateProcesses(bid: bid)
            let titleForLog = getFocusedWindowTitle(bid: bid) ?? ""
            Log.debug("PROCESS MATCH: title=\(titleForLog) candidates=\(candidates) rules=\(processRules.map { "\($0.pattern)" })")

            // Per-candidate rule resolution. Multiple candidates mean we
            // couldn't narrow the focused tab to one tty (e.g. several
            // ghostty tabs in the same cwd, generic title). Apply a rule
            // only when every candidate agrees — otherwise an idle tab
            // could get mis-switched just because a *different* tab in
            // the same cwd happens to be running `claude`.
            let hits: [TerminalRule?] = candidates.map { procs in
                processRules.first(where: { rule in
                    !rule.pattern.isEmpty &&
                    procs.contains(where: { $0.matches(pattern: rule.pattern) })
                })
            }
            if let firstHit = hits.first ?? nil,
               hits.allSatisfy({ $0?.inputSourceID == firstHit.inputSourceID }) {
                Log.debug("PROCESS RULE HIT: pattern=\(firstHit.pattern) across \(hits.count) candidate(s)")
                return firstHit.inputSourceID
            }
            let hitCount = hits.compactMap { $0 }.count
            Log.debug("PROCESS RULE MISS: \(candidates.count) candidate(s), \(hitCount) hit, ambiguous → fall through")
        }

        return nil
    }

    // MARK: AX Helpers

    private func getFocusedWindow(bid: String) -> AXUIElement? {
        guard let el = elements[bid] else { return nil }
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let raw = win,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func getFocusedWindowTitle(bid: String) -> String? {
        guard let app = elements[bid] else { return nil }
        return TerminalAdapters.adapter(for: bid).focusedTitle(appElement: app)
    }

    private struct TabInfo { let cwd: String; let tty: dev_t? }

    private func getFocusedTabInfo(bid: String) -> TabInfo? {
        guard let win = getFocusedWindow(bid: bid) else { return nil }
        var val: AnyObject?
        guard AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &val) == .success,
              let urlStr = val as? String,
              let url = URL(string: urlStr) else { return nil }
        Log.debug("AXDocument raw=\(urlStr)")
        let path = url.path
        guard !path.isEmpty else { return nil }
        let tty = URLComponents(string: urlStr)?.queryItems?
            .first(where: { $0.name == "tty" })?.value
            .flatMap { Self.ttyDev(forName: $0) }
        return TabInfo(cwd: path, tty: tty)
    }

    /// Look up `/dev/<name>`'s rdev so we can compare against `kinfo_proc.e_tdev`.
    /// Exposed (internal) because terminal adapters resolve their own tty names
    /// (AppleScript, CLI output) and need to convert to dev_t for filtering.
    static func ttyDev(forName name: String) -> dev_t? {
        var st = stat()
        guard lstat("/dev/" + name, &st) == 0 else { return nil }
        return st.st_rdev
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

    private func getTerminalCandidateProcesses(bid: String) -> [[String]] {
        // When the user runs multiple instances of the same terminal app
        // (e.g. several kitty windows, each a separate process), prefer the
        // currently active one — that's the instance whose focus event
        // brought us here. Falls back to first match for safety.
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { $0.bundleIdentifier == bid && $0.isActive })
                ?? apps.first(where: { $0.bundleIdentifier == bid }) else { return [] }
        let termPid = app.processIdentifier

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

        // 1. Native tty (Apple Terminal AppleScript, kitty/wezterm CLI). Works
        //    without AXDocument — required for terminals that don't expose cwd.
        if let tty = TerminalAdapters.adapter(for: bid).focusedTty(appPid: termPid) {
            // All processes on this tty, not just the foreground process group.
            // Foreground flips when cc/claude spawns tool subprocesses (bash,
            // grep, ...) — but `claude` is still alive on the tty, so a full
            // listing keeps the claude rule matching during "thinking" pauses.
            let procs = entries.filter { descendants.contains($0.pid) && $0.tdev == tty }.map(\.comm)
            Log.debug("TTY DIRECT: tty=\(tty) source=native procs=\(procs)")
            return procs.isEmpty ? [] : [procs]
        }

        // 2. OSC 7 query tty (shell hook) — needs AXDocument.
        let tabInfo = getFocusedTabInfo(bid: bid)
        if let tty = tabInfo?.tty {
            let procs = entries.filter { descendants.contains($0.pid) && $0.tdev == tty }.map(\.comm)
            Log.debug("TTY DIRECT: tty=\(tty) source=osc7 procs=\(procs)")
            return procs.isEmpty ? [] : [procs]
        }

        // 3. No cwd from AXDocument either (Alacritty and similar minimal
        //    terminals). Return foreground processes of every tty under the
        //    app's process tree. If multiple ttys exist (e.g. several
        //    Alacritty windows sharing one process), try to narrow to the
        //    focused one by matching the AXTitle against fg process names —
        //    Alacritty's title tracks the focused window's running command.
        guard let tabCWD = tabInfo?.cwd else {
            var byTty: [dev_t: [String]] = [:]
            var shellPidPerTty: [dev_t: Int32] = [:]
            let shellNamesFallback: Set<String> = ["zsh", "bash", "fish", "login"]
            for e in entries where descendants.contains(e.pid) && e.tdev != 0 {
                if e.isFg {
                    byTty[e.tdev, default: []].append(e.comm)
                }
                if shellNamesFallback.contains(e.comm) {
                    shellPidPerTty[e.tdev] = e.pid
                }
            }
            let rawTitle = getFocusedWindowTitle(bid: bid) ?? ""
            if byTty.count > 1 {
                // 1. Title literally names a fg process (e.g. "cc-connect",
                //    "✳ Claude Code"). Catches Warp's cc/cc-connect tabs.
                //    Shell process names are excluded so a title like
                //    "Running zsh in foo" doesn't match every candidate.
                for (_, procs) in byTty {
                    let nonShellOnly = procs.filter { !shellNamesFallback.contains($0) }
                    if rawTitle.mentionsAny(of: nonShellOnly) {
                        Log.debug("DESCENDANT FALLBACK: title=\(rawTitle) proc-match → \(procs)")
                        return [procs]
                    }
                }

                // 2. Title is a bare path (Warp tags idle shell tabs with
                //    their cwd). Match against each candidate shell's cwd
                //    to pick the focused one. When multiple ttys share the
                //    cwd, prefer the one whose fg is only a shell — a
                //    bare-cwd title means the user is at a prompt, not
                //    running a foreground command. Gate on `~`/`/` prefix
                //    so titles like "bwg-us:~" (ssh tab) don't false-match.
                if rawTitle.hasPrefix("~") || rawTitle.hasPrefix("/") {
                    let expanded = (rawTitle as NSString).expandingTildeInPath
                    var matches: [(dev_t, [String])] = []
                    for (tdev, procs) in byTty {
                        guard let pid = shellPidPerTty[tdev],
                              let cwd = processCWD(pid) else { continue }
                        if cwd == expanded { matches.append((tdev, procs)) }
                    }
                    if let shellOnly = matches.first(where: { (_, procs) in
                        procs.allSatisfy { shellNamesFallback.contains($0) }
                    }) {
                        Log.debug("DESCENDANT FALLBACK: title=\(rawTitle) cwd+shell-only → \(shellOnly.1)")
                        return [shellOnly.1]
                    }
                    if let first = matches.first {
                        Log.debug("DESCENDANT FALLBACK: title=\(rawTitle) cwd-match \(expanded) → \(first.1)")
                        return [first.1]
                    }
                }
            }
            let result = Array(byTty.values)
            Log.debug("DESCENDANT FALLBACK: \(result.count) ttys title=\(rawTitle) (no narrowing)")
            return result
        }

        let shellNames: Set<String> = ["zsh", "bash", "fish", "login"]
        let shells = entries.filter { descendants.contains($0.pid) && $0.tdev != 0 && shellNames.contains($0.comm) }

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

        // Per-tty foreground process list — used by the heuristics below
        // (e.g. "is this tty currently idle at a shell prompt?").
        let fgByTty: [dev_t: [String]] = {
            var m: [dev_t: [String]] = [:]
            for e in entries where descendants.contains(e.pid) && e.isFg && e.tdev != 0 {
                m[e.tdev, default: []].append(e.comm)
            }
            return m
        }()

        // Full process list per tty — used for what we hand to the rule
        // matcher. Including non-fg processes keeps `claude` discoverable
        // while cc spawns transient tool subprocesses that briefly own
        // the foreground process group.
        func ttyProcs(_ td: dev_t) -> [String] {
            entries.filter { descendants.contains($0.pid) && $0.tdev == td }.map(\.comm)
        }

        if candidateTdevs.count == 1 {
            return [ttyProcs(candidateTdevs[0])]
        }

        let title = getFocusedWindowTitle(bid: bid) ?? ""
        // Shell prompt signal: title equals a bare shell name, or shows the
        // focused tab's own cwd in any of the recognised forms.
        let looksLikeShell = shellNames.contains(title) || title.showsCwd(tabCWD)

        if looksLikeShell {
            let tdev = candidateTdevs.first(where: { td in
                (fgByTty[td] ?? []).allSatisfy { shellNames.contains($0) }
            }) ?? candidateTdevs[0]
            return [ttyProcs(tdev)]
        }

        let nonShellTdevs = candidateTdevs.filter { td in
            (fgByTty[td] ?? []).contains(where: { !shellNames.contains($0) })
        }
        guard nonShellTdevs.count > 1 else {
            return [ttyProcs(nonShellTdevs.first ?? candidateTdevs[0])]
        }

        // Multi non-shell candidates: try to single out the focused one by
        // checking which candidate's fg process name appears in the window
        // title. Works for terminals that auto-set the title to the running
        // command (Ghostty, kitty, etc.) when several tabs share a cwd.
        // Shell processes are excluded so a title like "Running zsh in foo"
        // doesn't accidentally match every candidate (every tty has zsh).
        for td in nonShellTdevs {
            let procs = ttyProcs(td)
            let nonShellOnly = procs.filter { !shellNames.contains($0) }
            if title.mentionsAny(of: nonShellOnly) {
                Log.debug("CWD MULTI title=\(title) → \(procs)")
                return [procs]
            }
        }
        return nonShellTdevs.map { ttyProcs($0) }
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

        var notifs = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] as [CFString]
        if terminalBundleIDs.contains(bid) {
            notifs.append(kAXFocusedUIElementChangedNotification as CFString)
            if TerminalAdapters.adapter(for: bid).needsTitleChangeNotification {
                notifs.append(kAXTitleChangedNotification as CFString)
            }
        }
        for name in notifs { AXObserverAddNotification(observer, el, name, ptr) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func detach(_ bid: String) {
        guard let obs = observers[bid], let el = elements[bid] else { return }
        let notifs = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                      kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification] as [CFString]
        for n in notifs { AXObserverRemoveNotification(obs, el, n) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers.removeValue(forKey: bid)
        elements.removeValue(forKey: bid)
        contexts.removeValue(forKey: bid)
    }
}
