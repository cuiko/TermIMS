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
    /// Polls herdr's socket while the frontmost terminal is hosting herdr.
    /// herdr keeps the host window title at `herdr`, so AX title/focus
    /// notifications do not fire on internal tab switches.
    private var herdrPoll: Timer?
    private var herdrPollBid: String?
    private var lastHerdrFingerprint: String?

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
        stopHerdrPolling()
        for bid in Array(observers.keys) { detach(bid) }
    }

    @objc func reload() {
        let store = RuleStore.shared
        var needed = Set(store.rules.filter(\.enabled).map(\.appBundleID))
        let termRulesOn = store.terminalRules.contains(where: \.enabled)
        if termRulesOn {
            needed.formUnion(terminalBundleIDs)
        } else {
            // Terminal rules all off — drop herdr polling so a leftover timer
            // cannot keep switching via app/global defaults.
            stopHerdrPolling()
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

        // Resolve host-tab candidates first so we know whether herdr is the
        // focused host surface (gate). Only then may we trust herdr's socket —
        // the server stays up even when Ghostty is on a non-herdr tab.
        let hostTitle = getFocusedWindowTitle(bid: bid)
        let hostCandidates = getTerminalCandidateProcesses(bid: bid)
        let herdrPane = hostLooksLikeHerdr(hostCandidates, title: hostTitle)
            ? HerdrClient.focusedPane() : nil
        let candidates = herdrPane.map { [$0.candidates] } ?? hostCandidates
        updateHerdrPolling(bid: bid, pane: herdrPane)

        if !titleRules.isEmpty {
            // Prefer herdr's per-pane title; the host window title is usually
            // just "herdr" and would miss Claude-style glyph title rules.
            let title = herdrPane?.title ?? hostTitle
            if let title {
                for rule in titleRules where !rule.pattern.isEmpty {
                    if title.matches(pattern: rule.pattern) {
                        Log.debug("TITLE RULE HIT: pattern=\(rule.pattern) title=\(title) via=\(herdrPane != nil ? "herdr" : "host")")
                        return rule.inputSourceID
                    }
                }
            }
        }

        if !processRules.isEmpty {
            let titleForLog = herdrPane?.title ?? hostTitle ?? ""
            Log.debug("PROCESS MATCH: title=\(titleForLog) candidates=\(candidates) herdr=\(herdrPane != nil) rules=\(processRules.map { "\($0.pattern)" })")

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

    /// True when the host terminal's focused surface is the herdr client.
    /// Requires either a unique host-tty candidate listing `herdr`, or a host
    /// window title of `herdr` (Ghostty/iTerm typically keep it there). The
    /// title fallback covers cases where cwd heuristics stay ambiguous.
    private func hostLooksLikeHerdr(_ candidates: [[String]], title: String?) -> Bool {
        let hasHerdr: ([String]) -> Bool = { procs in
            procs.contains { $0.caseInsensitiveCompare("herdr") == .orderedSame }
        }
        if candidates.count == 1, hasHerdr(candidates[0]) { return true }
        if let title, title.caseInsensitiveCompare("herdr") == .orderedSame {
            // Title says herdr; still require that we didn't confidently resolve
            // a *different* single tty (e.g. nvim) — that would mean the title
            // is stale or user-set and the process tree is more trustworthy.
            if candidates.count == 1 { return hasHerdr(candidates[0]) }
            return true
        }
        return false
    }

    private func updateHerdrPolling(bid: String, pane: HerdrClient.FocusedPane?) {
        guard let pane else {
            stopHerdrPolling()
            return
        }
        lastHerdrFingerprint = pane.fingerprint
        herdrPollBid = bid
        guard herdrPoll == nil else { return }
        // 250ms is snappy enough for tab switches without hammering the socket
        // (each tick is two short AF_UNIX RPCs, ~sub-ms when local).
        herdrPoll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.herdrPollTick()
        }
    }

    private func stopHerdrPolling() {
        herdrPoll?.invalidate()
        herdrPoll = nil
        herdrPollBid = nil
        lastHerdrFingerprint = nil
    }

    private func herdrPollTick() {
        guard enabled, let bid = herdrPollBid, isFrontmost(bid), isTerminalWithRules(bid) else {
            stopHerdrPolling()
            return
        }
        // Socket-only check: leaving herdr (Ghostty tab switch / app deactivate)
        // is caught by AX / activation handlers, which re-run matchTerminalRule
        // and call updateHerdrPolling(nil). Avoid a full process-table scan here.
        // A single RPC failure is treated as transient — stopping the timer
        // here would miss later herdr tab switches until some unrelated AX event.
        guard let pane = HerdrClient.focusedPane() else { return }
        let fp = pane.fingerprint
        guard fp != lastHerdrFingerprint else { return }
        Log.debug("HERDR FOCUS CHANGE: \(lastHerdrFingerprint ?? "nil") → \(fp)")
        lastHerdrFingerprint = fp
        if let id = resolveInputSource(for: bid) { selectInputSource(id) }
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

    // Runtimes that launch an agent as a script argument (e.g. `node
    // .../claude`, `Python .../aider`). For these the kernel `p_comm` names
    // the interpreter, not the tool the user wrote a rule for, so we recover
    // the wrapped script's name from argv instead.
    private static let genericRuntimes: Set<String> = ["node", "bun", "deno", "python", "python3"]
    // Argv flags that mean "no script file follows" (inline eval / module),
    // so there is no basename worth extracting.
    private static let runtimeEvalFlags: Set<String> = ["-e", "--eval", "-p", "--print", "-c", "-m"]
    // Runtime flags that consume the following argv token as their value —
    // skipped so the value isn't mistaken for the script path.
    private static let runtimeValueFlags: Set<String> = [
        "-r", "--require", "--loader", "--import", "--experimental-loader", "--conditions",
    ]
    // Launcher subcommands that precede the real script (`bun run …`,
    // `deno run …`). Must not be treated as the script path themselves.
    private static let runtimeLauncherSubcommands: Set<String> = ["run"]

    /// Best-effort "real" process name for rule matching. Kernel `p_comm` is
    /// capped at `MAXCOMLEN` chars and, for agents launched through a runtime,
    /// only names the runtime (`node`, `python`, …). This recovers the wrapped
    /// script's basename and un-truncates long native names — so a user rule
    /// like `claude` still matches `node .../claude`. Falls back to `comm`.
    /// Reads argv (one sysctl) only when there is something to gain.
    private func resolvedProcName(pid: Int32, comm: String) -> String {
        let lower = comm.lowercased()
        let isRuntime = Self.genericRuntimes.contains(lower) || lower.hasPrefix("python")
        // A fully-populated p_comm means the real name was likely truncated.
        let truncated = comm.utf8.count >= Int(MAXCOMLEN) - 1
        guard isRuntime || truncated, let argv = processArgv(pid) else { return comm }

        if isRuntime, let wrapped = wrappedScriptName(argv: argv) {
            return wrapped
        }
        // Node.js `process.title = "pi"` (and similar) rewrites argv[0] so
        // `ps -o comm` shows `pi`, while kinfo `p_comm` stays `node`. When
        // there's no script path in argv — just `["pi"]` — treat argv0 as
        // the real name for rule matching.
        if isRuntime, let argv0 = argv.first {
            let base = (argv0 as NSString).lastPathComponent
            let cleaned = base.hasPrefix("-") ? String(base.dropFirst()) : base
            let cl = cleaned.lowercased()
            if !cleaned.isEmpty,
               !Self.genericRuntimes.contains(cl),
               !cl.hasPrefix("python") {
                return cleaned
            }
        }
        // De-truncate a native binary via argv[0]. Guard with a prefix check so
        // a login shell's `-zsh` argv[0] never replaces a clean `comm`.
        if truncated, let argv0 = argv.first {
            let base = (argv0 as NSString).lastPathComponent
            if base.lowercased().hasPrefix(lower), base.utf8.count > comm.utf8.count {
                return base
            }
        }
        return comm
    }

    /// Extract the wrapped script's name from a runtime's argv (skipping flags),
    /// e.g. `["node", "-r", "x", "/opt/claude", …]` → `claude`,
    /// `["bun", "run", "claude", …]` → `claude`. Returns nil for inline-eval /
    /// module invocations that name no script file.
    private func wrappedScriptName(argv: [String]) -> String? {
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" {
                return i + 1 < argv.count ? scriptBasename(argv[i + 1]) : nil
            }
            if Self.runtimeEvalFlags.contains(arg) { return nil }
            if Self.runtimeLauncherSubcommands.contains(arg) {
                i += 1
                continue
            }
            if arg.hasPrefix("-") {
                if Self.runtimeValueFlags.contains(arg) { i += 1 }
                i += 1
                continue
            }
            return scriptBasename(arg)
        }
        return nil
    }

    // Generic entrypoint basenames that hide the real tool — climb to the
    // package directory instead (e.g. `…/pi-coding-agent/dist/cli.js` →
    // `pi-coding-agent`, which still substring-matches a `pi` process rule).
    private static let genericScriptNames: Set<String> = [
        "cli", "index", "main", "bin", "app", "run", "start", "bundle",
    ]

    /// Basename of a script path with a common script extension stripped, so
    /// `.../gemini.js` reads as `gemini`. npm bin symlinks are extensionless
    /// and already yield the tool name directly. Generic entrypoints climb
    /// one packaging directory (`dist`/`bin`/…) so `dist/cli.js` maps to the
    /// package folder. If that folder looks like a version/build id (e.g.
    /// `2026.07.23-e383d2b`), return nil so the caller can fall through to
    /// argv0 — many tools set argv0/`process.title` to the real command name.
    private func scriptBasename(_ token: String) -> String? {
        let ns = token as NSString
        let base = ns.lastPathComponent
        guard !base.isEmpty else { return nil }
        let lower = base.lowercased()
        var stripped = base
        for ext in [".js", ".mjs", ".cjs", ".ts", ".py"] where lower.hasSuffix(ext) {
            stripped = String(base.dropLast(ext.count))
            break
        }
        guard Self.genericScriptNames.contains(stripped.lowercased()) else {
            return stripped
        }
        // …/pkg/dist/cli.js → pkg
        var dir = ns.deletingLastPathComponent
        let leaf = (dir as NSString).lastPathComponent.lowercased()
        if ["dist", "bin", "build", "lib", "src"].contains(leaf) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        let pkg = (dir as NSString).lastPathComponent
        if pkg.isEmpty || pkg == "node_modules" || pkg.hasPrefix("@") { return nil }
        // Version/build directories are not tool names — refuse so argv0 wins.
        if Self.looksLikeVersionDir(pkg) { return nil }
        return pkg
    }

    /// True for directory names that are build ids / versions, not packages
    /// (`2026.07.23-e383d2b`, long hex hashes).
    private static func looksLikeVersionDir(_ name: String) -> Bool {
        if name.count >= 7, name.allSatisfy(\.isHexDigit) { return true }
        if name.first?.isNumber == true,
           name.contains(where: { $0 == "." || $0 == "-" }) {
            return true
        }
        return false
    }

    /// Read a process's argument vector via `KERN_PROCARGS2`. Returns nil when
    /// the process is gone or owned by another user (foreign argv is
    /// restricted). Buffer layout: `int argc` · exec_path · NUL padding · argc
    /// NUL-terminated argv strings · environment.
    private func processArgv(_ pid: Int32) -> [String]? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: Int(argmax))
        var size = Int(argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        // Skip the exec_path string and the NUL padding before argv[0].
        while cursor < size && buf[cursor] != 0 { cursor += 1 }
        while cursor < size && buf[cursor] == 0 { cursor += 1 }

        var argv: [String] = []
        var parsed: Int32 = 0
        while parsed < argc && cursor < size {
            let start = cursor
            while cursor < size && buf[cursor] != 0 { cursor += 1 }
            if cursor > start, let s = String(bytes: buf[start..<cursor], encoding: .utf8) {
                argv.append(s)
            }
            cursor += 1   // step over the NUL terminator
            parsed += 1
        }
        return argv.isEmpty ? nil : argv
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

        // Real names for the candidate lists handed to the rule matcher.
        // Cached per call — resolvedProcName may read argv (a sysctl) for
        // runtime-wrapped or truncated names, so we resolve each pid at most
        // once. Shell heuristics below keep using raw `comm` intentionally.
        var nameCache: [Int32: String] = [:]
        func resolved(_ pe: PE) -> String {
            if let cached = nameCache[pe.pid] { return cached }
            let name = self.resolvedProcName(pid: pe.pid, comm: pe.comm)
            nameCache[pe.pid] = name
            return name
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
            let procs = entries.filter { descendants.contains($0.pid) && $0.tdev == tty }.map(resolved)
            Log.debug("TTY DIRECT: tty=\(tty) source=native procs=\(procs)")
            return procs.isEmpty ? [] : [procs]
        }

        // 2. OSC 7 query tty (shell hook) — needs AXDocument.
        let tabInfo = getFocusedTabInfo(bid: bid)
        if let tty = tabInfo?.tty {
            let procs = entries.filter { descendants.contains($0.pid) && $0.tdev == tty }.map(resolved)
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
                    byTty[e.tdev, default: []].append(resolved(e))
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
            entries.filter { descendants.contains($0.pid) && $0.tdev == td }.map(resolved)
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

        var nonShellTdevs = candidateTdevs.filter { td in
            (fgByTty[td] ?? []).contains(where: { !shellNames.contains($0) })
        }

        // Sibling herdr host tab often shares $HOME with other Ghostty tabs.
        // When the window title isn't "herdr", drop herdr-only ttys so they
        // don't poison the "all candidates must agree" process-rule check
        // (e.g. focused Pi tab + idle herdr both under /Users/… → miss).
        if title.caseInsensitiveCompare("herdr") != .orderedSame {
            nonShellTdevs = nonShellTdevs.filter { td in
                let nonShell = ttyProcs(td).filter { !shellNames.contains($0) }
                if nonShell.count == 1,
                   nonShell[0].caseInsensitiveCompare("herdr") == .orderedSame {
                    return false
                }
                return true
            }
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
            // Exact title ↔ process name (Ghostty titles "Pi" while p_comm
            // is `pi`). mentionsAny requires title ⊇ name; equality covers
            // the short-name case in either direction.
            if nonShellOnly.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
                Log.debug("CWD MULTI title=\(title) exact → \(procs)")
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
        // AX window / focused-element / title notifications also fire while an
        // app is in the *background* — most painfully for a terminal whose
        // foreground program animates its title (e.g. Claude Code's braille
        // spinner). Without this guard those background ticks would let the
        // terminal's rule reach across and switch the input method of whatever
        // app is actually in front (Obsidian, a browser, …). Only act when the
        // event's app is the one the user is currently looking at.
        guard isFrontmost(bid) else { return }
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
            // Re-check at fire time: during the debounce the user may have
            // switched away from the terminal (e.g. to Obsidian), and we must
            // not yank the now-frontmost app's input method.
            guard self.isFrontmost(bid) else { return }
            if let id = self.resolveInputSource(for: bid) {
                selectInputSource(id)
            }
        }
    }

    private func isFrontmost(_ bid: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid
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
