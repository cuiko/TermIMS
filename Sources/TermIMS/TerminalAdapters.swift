import Cocoa
import ApplicationServices

// MARK: - Protocol
//
// Strategy pattern: each terminal app encapsulates its own native ways to
// disambiguate the focused tab. Three protocol hooks (all defaulted, all
// optional to override):
//
//   - `focusedTty(appPid:)` — primary disambiguation channel. Returning a
//     non-nil tty lets the matcher skip the cwd-based candidate heuristic.
//   - `focusedTitle(appElement:)` — title source for the rule matcher's
//     heuristics. Override when a terminal's window title doesn't track
//     focus reliably.
//   - `needsTitleChangeNotification` — whether to subscribe to
//     kAXTitleChangedNotification for intra-window pane focus events.
//
// Adapters that don't override anything fall through to the generic
// BFS + cwd-matching path.

protocol TerminalAdapter {
    var bundleID: String { get }

    /// Whether the matcher should also subscribe to `kAXTitleChangedNotification`
    /// for this terminal. Useful for terminals that render multiple panes
    /// inside a single AX window (e.g. kitty splits) and thus signal pane
    /// focus changes only via title updates. Most terminals get this wrong
    /// when foreground programs animate their title (cc's braille spinner),
    /// so default is false.
    var needsTitleChangeNotification: Bool { get }

    /// Resolve the focused tab's tty (e.g. via AppleScript, CLI, IPC).
    /// `appPid` is the PID of the terminal app instance whose focus event
    /// triggered this lookup — adapters use it to disambiguate when the user
    /// runs multiple instances of the same terminal (e.g. several kitty
    /// windows, each with its own listen socket).
    /// Default implementation: nil → caller uses the generic CWD heuristic.
    func focusedTty(appPid: pid_t) -> dev_t?

    /// Title string used by the rule matcher's heuristics. Default returns
    /// the focused window's kAXTitleAttribute. Override for terminals whose
    /// window title doesn't track focus reliably — Warp keeps the window
    /// title at whichever tab most recently set OSC 2, so we read the
    /// focused text area's value (which IS per-tab) instead.
    func focusedTitle(appElement: AXUIElement) -> String?
}

extension TerminalAdapter {
    var needsTitleChangeNotification: Bool { false }
    func focusedTty(appPid: pid_t) -> dev_t? { nil }
    func focusedTitle(appElement: AXUIElement) -> String? {
        defaultFocusedWindowTitle(appElement: appElement)
    }
}

/// Helper exposed to adapter implementations: read kAXTitleAttribute on the
/// focused window. Used as the default `focusedTitle` and as a fallback by
/// adapters that combine it with other signals.
func defaultFocusedWindowTitle(appElement: AXUIElement) -> String? {
    var winObj: AnyObject?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winObj) == .success,
          let raw = winObj,
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    let win = raw as! AXUIElement
    var titleObj: AnyObject?
    guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleObj) == .success else { return nil }
    return titleObj as? String
}

// MARK: - Adapters

struct DefaultTerminalAdapter: TerminalAdapter {
    let bundleID: String
}

/// Apple Terminal exposes the focused tab's tty via AppleScript.
/// First call may prompt for Automation permission (System Settings → Privacy
/// & Security → Automation → TermIMS → Terminal). If denied, returns nil and
/// matching falls back to the generic heuristic.
struct AppleTerminalAdapter: TerminalAdapter {
    let bundleID = "com.apple.Terminal"

    // Apple Terminal is single-instance (one process per user). The
    // AppleScript `front window` always points to the frontmost window,
    // so we don't need to filter by appPid.
    func focusedTty(appPid: pid_t) -> dev_t? {
        let script = """
        tell application "Terminal"
            try
                return tty of selected tab of front window
            on error errMsg
                return "ERR:" & errMsg
            end try
        end tell
        """
        guard let s = NSAppleScript(source: script) else {
            Log.debug("APPLESCRIPT init failed")
            return nil
        }
        var err: NSDictionary?
        let descriptor = s.executeAndReturnError(&err)
        if let err = err {
            Log.debug("APPLESCRIPT exec error: \(err)")
            return nil
        }
        guard let path = descriptor.stringValue else {
            Log.debug("APPLESCRIPT no string result")
            return nil
        }
        if path.hasPrefix("ERR:") {
            Log.debug("APPLESCRIPT terminal error: \(path)")
            return nil
        }
        guard !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        let dev = FocusMonitor.ttyDev(forName: name)
        Log.debug("APPLE-TERMINAL tty=\(path) dev=\(dev.map(String.init(describing:)) ?? "nil")")
        return dev
    }
}

/// iTerm2 exposes the focused pane's tty via AppleScript. Object model is
/// window → tab → session(s); the "current session of current window" is
/// the focused pane (handles split panes correctly because iTerm2 tracks
/// pane focus inside each tab).
struct ITerm2Adapter: TerminalAdapter {
    let bundleID = "com.googlecode.iterm2"

    func focusedTty(appPid: pid_t) -> dev_t? {
        let script = """
        tell application "iTerm"
            try
                return tty of current session of current window
            on error errMsg
                return "ERR:" & errMsg
            end try
        end tell
        """
        guard let s = NSAppleScript(source: script) else {
            Log.debug("ITERM2 init failed")
            return nil
        }
        var err: NSDictionary?
        let descriptor = s.executeAndReturnError(&err)
        if let err = err {
            Log.debug("ITERM2 exec error: \(err)")
            return nil
        }
        guard let path = descriptor.stringValue else {
            Log.debug("ITERM2 no string result")
            return nil
        }
        if path.hasPrefix("ERR:") {
            Log.debug("ITERM2 script error: \(path)")
            return nil
        }
        guard !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        let dev = FocusMonitor.ttyDev(forName: name)
        Log.debug("ITERM2 tty=\(path) dev=\(dev.map(String.init(describing:)) ?? "nil")")
        return dev
    }
}

/// Wezterm: `wezterm cli list-clients` gives the focused_pane_id; `wezterm cli list`
/// maps pane_id → tty_name. Two short-lived subprocess calls per focus event.
struct WezTermAdapter: TerminalAdapter {
    let bundleID = "com.github.wez.wezterm"

    func focusedTty(appPid: pid_t) -> dev_t? {
        guard let bin = resolveSiblingBinary(bundleID: bundleID, name: "wezterm") else {
            Log.debug("WEZTERM binary not found")
            return nil
        }
        guard let clientsData = runCommand(bin, args: ["cli", "list-clients", "--format", "json"]),
              let clients = try? JSONSerialization.jsonObject(with: clientsData) as? [[String: Any]] else {
            Log.debug("WEZTERM list-clients failed")
            return nil
        }
        // Multiple wezterm-gui instances all connect to the same mux daemon
        // and appear as separate clients here. Match by appPid to find the
        // client driven by the focused window; fall back to the first one
        // if no client carries a matching pid (older wezterm versions).
        let client = clients.first { ($0["pid"] as? Int) == Int(appPid) } ?? clients.first
        guard let focusedPaneID = client?["focused_pane_id"] as? Int else {
            Log.debug("WEZTERM no focused_pane_id for pid=\(appPid)")
            return nil
        }
        guard let panesData = runCommand(bin, args: ["cli", "list", "--format", "json"]),
              let panes = try? JSONSerialization.jsonObject(with: panesData) as? [[String: Any]],
              let pane = panes.first(where: { ($0["pane_id"] as? Int) == focusedPaneID }),
              let ttyName = pane["tty_name"] as? String else {
            Log.debug("WEZTERM no pane match for id=\(focusedPaneID)")
            return nil
        }
        let leaf = (ttyName as NSString).lastPathComponent
        let dev = FocusMonitor.ttyDev(forName: leaf)
        Log.debug("WEZTERM tty=\(ttyName) dev=\(dev.map(String.init(describing:)) ?? "nil")")
        return dev
    }
}

/// Kitty: `kitten @ ls` returns nested JSON (OS-windows → tabs → windows).
/// Recurse into the focused chain to find the focused inner window's pid,
/// then look up its tdev. Requires both `allow_remote_control yes` and an
/// explicit `listen_on unix:/path/...` in kitty.conf so external processes
/// know which socket to talk to.
struct KittyAdapter: TerminalAdapter {
    let bundleID = "net.kovidgoyal.kitty"
    // kitty renders panes inside a single AX window; intra-window split
    // focus changes only fire title-change notifications, not focus-element.
    var needsTitleChangeNotification: Bool { true }

    func focusedTty(appPid: pid_t) -> dev_t? {
        guard let bin = resolveSiblingBinary(bundleID: bundleID, name: "kitten") else {
            Log.debug("KITTY kitten binary not found")
            return nil
        }
        var args = ["@", "ls"]
        if let socket = Self.resolveSocket(kittyPid: appPid) {
            args = ["@", "--to", socket, "ls"]
        }
        guard let data = runCommand(bin, args: args),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Log.debug("KITTY @ ls failed (check allow_remote_control + listen_on in kitty.conf)")
            return nil
        }
        guard let pid = Self.focusedWindowPid(in: osWindows) else {
            Log.debug("KITTY no focused window in JSON")
            return nil
        }
        guard let dev = ttyDevForPid(pid_t(pid)) else {
            Log.debug("KITTY pid=\(pid) has no tdev")
            return nil
        }
        Log.debug("KITTY pid=\(pid) dev=\(dev)")
        return dev
    }

    /// Walk OS-window → tab → window picking the entry with `is_focused = true`
    /// at each level. Falls back to first available if any level lacks the flag.
    private static func focusedWindowPid(in osWindows: [[String: Any]]) -> Int? {
        let osWin = osWindows.first(where: { ($0["is_focused"] as? Bool) == true }) ?? osWindows.first
        guard let tabs = osWin?["tabs"] as? [[String: Any]] else { return nil }
        let tab = tabs.first(where: { ($0["is_focused"] as? Bool) == true }) ?? tabs.first
        guard let windows = tab?["windows"] as? [[String: Any]] else { return nil }
        let win = windows.first(where: { ($0["is_focused"] as? Bool) == true }) ?? windows.first
        return win?["pid"] as? Int
    }

    /// Parse the first `listen_on <value>` line from ~/.config/kitty/kitty.conf,
    /// then resolve the actual socket path: kitty appends `-{pid}` to the
    /// configured path (so `listen_on unix:/tmp/kitty` opens `/tmp/kitty-84629`).
    /// `kittyPid` is the specific kitty instance whose focus event triggered
    /// us — necessary when the user runs multiple kitty windows (each gets
    /// its own socket file).
    private static func resolveSocket(kittyPid: pid_t) -> String? {
        let confPath = NSHomeDirectory() + "/.config/kitty/kitty.conf"
        guard let content = try? String(contentsOfFile: confPath, encoding: .utf8) else { return nil }
        var declared: String?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("listen_on") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                declared = parts[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let socket = declared, socket.hasPrefix("unix:") else { return declared }
        let rawPath = String(socket.dropFirst("unix:".count))
        if FileManager.default.fileExists(atPath: rawPath) { return socket }
        let withPid = "\(rawPath)-\(kittyPid)"
        if FileManager.default.fileExists(atPath: withPid) {
            return "unix:\(withPid)"
        }
        return socket  // best effort — kitten will report a clearer error
    }
}

// MARK: - Registry

enum TerminalAdapters {
    static let all: [TerminalAdapter] = [
        DefaultTerminalAdapter(bundleID: "com.mitchellh.ghostty"),
        AppleTerminalAdapter(),
        ITerm2Adapter(),
        KittyAdapter(),
        WezTermAdapter(),
        DefaultTerminalAdapter(bundleID: "dev.warp.Warp-Stable"),
    ]
    private static let byBundleID: [String: TerminalAdapter] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.bundleID, $0) }
    )
    static func adapter(for bid: String) -> TerminalAdapter {
        byBundleID[bid] ?? DefaultTerminalAdapter(bundleID: bid)
    }
}

let terminalBundleIDs: Set<String> = Set(TerminalAdapters.all.map(\.bundleID))

// MARK: - Subprocess helpers

/// Locates a sibling binary inside a running app's bundle, e.g. resolving
/// `kitten` to `/Applications/kitty.app/Contents/MacOS/kitten`. Needed because
/// GUI-launched processes inherit a minimal PATH that often misses Homebrew /
/// `/usr/local/bin`, so we can't rely on bare command names.
func resolveSiblingBinary(bundleID: String, name: String) -> String? {
    guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }),
          let url = app.bundleURL else { return nil }
    let candidate = url.appendingPathComponent("Contents/MacOS/\(name)").path
    return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
}

/// Run a short-lived subprocess and return its stdout as Data, or nil on
/// failure / non-zero exit. Bounded by a timeout — focus handlers run on
/// the main queue so we cannot block long. On failure, stderr is appended
/// to the debug log to make diagnosis straightforward.
func runCommand(_ executable: String, args: [String], timeout: TimeInterval = 2.0) -> Data? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    let outPipe = Pipe(); let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError  = errPipe
    do { try proc.run() } catch {
        Log.debug("CMD launch failed: \(executable) \(args) err=\(error)")
        return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if proc.isRunning {
        proc.terminate()
        Log.debug("CMD timeout: \(executable) \(args)")
        return nil
    }
    guard proc.terminationStatus == 0 else {
        let errOut = (try? errPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Log.debug("CMD exit \(proc.terminationStatus): \(executable) \(args) stderr=\(errOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        return nil
    }
    return try? outPipe.fileHandleForReading.readToEnd()
}

/// Resolves a pid to its controlling terminal's dev_t via sysctl.
func ttyDevForPid(_ pid: pid_t) -> dev_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
    let tdev = info.kp_eproc.e_tdev
    return tdev == 0 ? nil : tdev
}
