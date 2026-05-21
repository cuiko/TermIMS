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
    /// Free-form annotation shown in the rule table. Purely cosmetic — not
    /// used by the matcher. `decodeIfPresent` lets older stored rules (saved
    /// before this field existed) round-trip cleanly with an empty note.
    var note: String = ""

    init(enabled: Bool = true,
         matchType: TerminalMatchType = .title,
         pattern: String = "",
         inputSourceID: String,
         inputSourceName: String,
         note: String = "") {
        self.enabled = enabled
        self.matchType = matchType
        self.pattern = pattern
        self.inputSourceID = inputSourceID
        self.inputSourceName = inputSourceName
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matchType = try c.decodeIfPresent(TerminalMatchType.self, forKey: .matchType) ?? .title
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        inputSourceID = try c.decode(String.self, forKey: .inputSourceID)
        inputSourceName = try c.decode(String.self, forKey: .inputSourceName)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

enum IndicatorPosition: String, Codable, CaseIterable {
    case screenCenter  = "Screen Center"
    case centerBottom  = "Center Bottom"
    case topLeft       = "Top Left"
    case topRight      = "Top Right"
    case bottomLeft    = "Bottom Left"
    case bottomRight   = "Bottom Right"
}

// MARK: - Terminal Adapters
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
fileprivate func defaultFocusedWindowTitle(appElement: AXUIElement) -> String? {
    var winObj: AnyObject?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winObj) == .success,
          let raw = winObj,
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    let win = raw as! AXUIElement
    var titleObj: AnyObject?
    guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleObj) == .success else { return nil }
    return titleObj as? String
}

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

/// Locates a sibling binary inside a running app's bundle, e.g. resolving
/// `kitten` to `/Applications/kitty.app/Contents/MacOS/kitten`. Needed because
/// GUI-launched processes inherit a minimal PATH that often misses Homebrew /
/// `/usr/local/bin`, so we can't rely on bare command names.
fileprivate func resolveSiblingBinary(bundleID: String, name: String) -> String? {
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
fileprivate func runCommand(_ executable: String, args: [String], timeout: TimeInterval = 2.0) -> Data? {
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

/// Resolves a pid to its controlling terminal's dev_t via sysctl.
fileprivate func ttyDevForPid(_ pid: pid_t) -> dev_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
    let tdev = info.kp_eproc.e_tdev
    return tdev == 0 ? nil : tdev
}

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

extension Notification.Name {
    static let rulesDidChange = Notification.Name("RulesDidChange")
    static let imDidSwitch    = Notification.Name("IMDidSwitch")
}

// MARK: - Title Heuristics
//
// Shared predicates used by terminals that fall through to the generic
// matching path (no native tty channel). Both Ghostty (cwd-based path) and
// Warp (descendant fallback) use these to ask the same two questions about
// the focused window's title; the orchestration around them stays per-path
// because the upstream signals differ (Ghostty has AXDocument cwd, Warp
// doesn't).

fileprivate extension String {
    /// Match self against a user-supplied rule pattern.
    /// `/body/` or `/body/i` is treated as an ICU regex (case-insensitive
    /// with `i`); anything else is a case-insensitive substring match.
    /// Patterns missing the closing slash, with empty body, or with
    /// unknown flags fall back to literal substring so users can still
    /// match strings like "/usr/bin/foo" without escaping.
    func matches(pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if pattern.count >= 2, pattern.first == "/",
           let lastSlash = pattern.lastIndex(of: "/"),
           lastSlash != pattern.startIndex {
            let flagsStr = pattern[pattern.index(after: lastSlash)...]
            let body = pattern[pattern.index(after: pattern.startIndex)..<lastSlash]
            if !body.isEmpty, flagsStr.allSatisfy({ $0 == "i" }) {
                var opts: NSRegularExpression.Options = []
                if flagsStr.contains("i") { opts.insert(.caseInsensitive) }
                if let re = try? NSRegularExpression(pattern: String(body), options: opts) {
                    let range = NSRange(self.startIndex..., in: self)
                    return re.firstMatch(in: self, range: range) != nil
                }
            }
        }
        return self.localizedCaseInsensitiveContains(pattern)
    }

    /// Does this title contain any of `processNames` as a case-insensitive
    /// substring? Empty names never match.
    func mentionsAny(of processNames: [String]) -> Bool {
        let lower = self.lowercased()
        return processNames.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
    }

    /// Does this title look like it is displaying `cwd` (the focused tab's
    /// own working directory)? Matches: the cwd's basename exactly, the
    /// absolute path as substring, the tilde-collapsed form as substring,
    /// and Ghostty's "…/tail/of/path" truncation. A title that mentions some
    /// other path will not match — useful to distinguish a shell prompt
    /// showing the tab's cwd from a foreground command title that happens
    /// to contain unrelated paths.
    func showsCwd(_ cwd: String) -> Bool {
        guard !self.isEmpty else { return false }
        let base = (cwd as NSString).lastPathComponent
        if self == base { return true }
        if self.contains(cwd) { return true }
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            let tilded = "~" + cwd.dropFirst(home.count)
            if self.contains(tilded) { return true }
        }
        if self.hasPrefix("…"), cwd.hasSuffix(String(self.dropFirst())) { return true }
        return false
    }
}

// MARK: - Log
//
// Single-line append-only log gated by RuleStore.debugLogEnabled.
// All log emission goes through `Log.debug(_:)` — call sites stay short
// and unaware of file paths, timestamps, or the toggle.
enum Log {
    static let path: String = {
        let dir = NSHomeDirectory() + "/Library/Logs/TermIMS"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/termims.log"
    }()

    private static let formatter = ISO8601DateFormatter()
    private static var handle: FileHandle? = openHandle()

    private static func openHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fh = FileHandle(forWritingAtPath: path)
        fh?.seekToEndOfFile()
        return fh
    }

    static func debug(_ msg: @autoclosure () -> String) {
        guard RuleStore.shared.debugLogEnabled else { return }
        if handle == nil { handle = openHandle() }
        guard let fh = handle else { return }
        let line = "[\(formatter.string(from: Date()))] \(msg())\n"
        guard let data = line.data(using: .utf8) else { return }
        fh.write(data)
    }

    static func clear() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(atPath: path)
    }
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

    var debugLogEnabled: Bool {
        get { ud.bool(forKey: "DebugLogEnabled") }
        set { ud.set(newValue, forKey: "DebugLogEnabled") }
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

    fileprivate static func ttyDev(forName name: String) -> dev_t? {
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

// MARK: - Settings Window

/// NSTableView that only allows row drag when the mouse-down originated in
/// a designated drag-handle column. Without this filter NSTableView happily
/// starts a drag from anywhere on the row, so a user adjusting a popup risks
/// accidentally reordering the table.
final class RuleTableView: NSTableView {
    /// Column identifier that acts as the row-drag grabber. Mouse-downs
    /// outside this column are still delivered normally (clicks, popup
    /// activation, text editing) but won't initiate drag.
    var dragHandleColumnID: String?
    fileprivate(set) var dragInitiatedFromHandle = false

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let col = column(at: pt)
        if col >= 0, col < tableColumns.count,
           tableColumns[col].identifier.rawValue == dragHandleColumnID {
            dragInitiatedFromHandle = true
        } else {
            dragInitiatedFromHandle = false
        }
        super.mouseDown(with: event)
    }
}

/// Small "grip" icon shown at the start of each rule row. Purely visual: the
/// row's drag is initiated by NSTableView when the user mouse-drags anywhere
/// inside a row (see `tableView(_:pasteboardWriterForRow:)`). The handle's
/// jobs are (a) signal draggability with an open-hand cursor on hover, and
/// (b) give users an obvious target to grab when they don't want to risk
/// clicking a checkbox / popup by accident.
final class DragHandleView: NSView {
    private var trackingArea: NSTrackingArea?
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: "line.3.horizontal",
                            accessibilityDescription: "Drag to reorder")
        img.contentTintColor = .tertiaryLabelColor
        img.translatesAutoresizingMaskIntoConstraints = false
        addSubview(img)
        NSLayoutConstraint.activate([
            img.centerXAnchor.constraint(equalTo: centerXAnchor),
            img.centerYAnchor.constraint(equalTo: centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 14),
            img.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // NSTableView aggressively manages cursor rects, so addCursorRect doesn't
    // stick. A tracking area + explicit push/pop in mouseEntered/Exited makes
    // the hand cursor reliably appear over the handle.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }
}

class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var appTableView: NSTableView!
    private var termTableView: NSTableView!
    private let inputSources = listInputSources()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "TermIMS Settings"
        w.center()
        w.minSize = NSSize(width: 620, height: 380)
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
        appTableView.registerForDraggedTypes([Self.appRowDragType])
        termTableView.registerForDraggedTypes([Self.termRowDragType])
        appTableView.draggingDestinationFeedbackStyle = .gap
        termTableView.draggingDestinationFeedbackStyle = .gap
    }

    static let appRowDragType  = NSPasteboard.PasteboardType("top.cuiko.termims.app-rule-row")
    static let termRowDragType = NSPasteboard.PasteboardType("top.cuiko.termims.term-rule-row")

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

        let sep3 = separator()
        let debugLabel = label("Debug")
        debugLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let debugCheck = NSButton(checkboxWithTitle: "Enable debug logging",
                                  target: self, action: #selector(debugLogToggled(_:)))
        debugCheck.translatesAutoresizingMaskIntoConstraints = false
        debugCheck.state = store.debugLogEnabled ? .on : .off

        let clearBtn = NSButton(title: "Clear Log", target: self, action: #selector(clearDebugLog(_:)))
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .regular

        for sub in [defLabel, defPopup, sep1, indLabel, indCheck, posLabel, posPopup,
                    sep2, appLabel, hideCheck,
                    sep3, debugLabel, debugCheck, clearBtn] { v.addSubview(sub) }
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

            sep3.topAnchor.constraint(equalTo: hideCheck.bottomAnchor, constant: 20),
            sep3.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            sep3.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),

            debugLabel.topAnchor.constraint(equalTo: sep3.bottomAnchor, constant: 16),
            debugLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            debugCheck.topAnchor.constraint(equalTo: debugLabel.bottomAnchor, constant: 10),
            debugCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            clearBtn.centerYAnchor.constraint(equalTo: debugCheck.centerYAnchor),
            clearBtn.leadingAnchor.constraint(equalTo: debugCheck.trailingAnchor, constant: 12),
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
    @objc private func debugLogToggled(_ sender: NSButton) {
        RuleStore.shared.debugLogEnabled = sender.state == .on
    }
    @objc private func clearDebugLog(_ sender: NSButton) {
        Log.clear()
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
        let rtv = RuleTableView()
        rtv.dragHandleColumnID = "tdrag"
        tv = rtv
        tv.usesAlternatingRowBackgroundColors = true; tv.rowHeight = 24
        let colDrag = NSTableColumn(identifier: .init("tdrag")); colDrag.title = ""; colDrag.width = 24; colDrag.minWidth = 24; colDrag.maxWidth = 24
        let colOn = NSTableColumn(identifier: .init("ton")); colOn.title = ""; colOn.width = 30; colOn.minWidth = 30; colOn.maxWidth = 30
        let colType = NSTableColumn(identifier: .init("ttype")); colType.title = "Match"; colType.width = 100; colType.minWidth = 80
        let colPat = NSTableColumn(identifier: .init("tpat")); colPat.title = "Pattern"; colPat.width = 140; colPat.minWidth = 80
        let colIM = NSTableColumn(identifier: .init("tim")); colIM.title = "Input Method"; colIM.width = 160; colIM.minWidth = 120
        let colNote = NSTableColumn(identifier: .init("tnote")); colNote.title = "Note"; colNote.width = 140; colNote.minWidth = 80
        tv.addTableColumn(colDrag); tv.addTableColumn(colOn); tv.addTableColumn(colType); tv.addTableColumn(colPat); tv.addTableColumn(colIM); tv.addTableColumn(colNote)
        sv.documentView = tv; return sv
    }

    // MARK: Table Drag Reordering

    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Only allow drag when the mouse-down was on the drag handle column —
        // see RuleTableView.mouseDown. Prevents accidental row reorder when a
        // user drags a popup or text field to select / scroll.
        if let rtv = tv as? RuleTableView, !rtv.dragInitiatedFromHandle { return nil }
        let item = NSPasteboardItem()
        let type = (tv === termTableView) ? Self.termRowDragType : Self.appRowDragType
        item.setString("\(row)", forType: type)
        return item
    }

    func tableView(_ tv: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .above else { return [] }
        return .move
    }

    func tableView(_ tv: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation op: NSTableView.DropOperation) -> Bool {
        let type = (tv === termTableView) ? Self.termRowDragType : Self.appRowDragType
        guard let items = info.draggingPasteboard.pasteboardItems,
              let str = items.first?.string(forType: type),
              let src = Int(str), src != row, src != row - 1 else { return false }

        if tv === termTableView {
            var rules = RuleStore.shared.terminalRules
            let dst = src < row ? row - 1 : row
            let moved = rules.remove(at: src)
            rules.insert(moved, at: dst)
            RuleStore.shared.terminalRules = rules
        } else {
            var rules = RuleStore.shared.rules
            let dst = src < row ? row - 1 : row
            let moved = rules.remove(at: src)
            rules.insert(moved, at: dst)
            RuleStore.shared.rules = rules
        }
        tv.reloadData()
        return true
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
        case "adrag":
            return centeredNarrowCellView(tv, id: "adrag\(row)", control: DragHandleView())
        case "on":
            let btn = recycledCheckbox(tv, id: "aon")
            btn.state = rule.enabled ? .on : .off; btn.tag = row
            btn.target = self; btn.action = #selector(appToggle(_:))
            return centeredNarrowCellView(tv, id: "aon\(row)", control: btn)
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

    /// Stretches the control to fill the full cell width — used for wide
    /// controls (popup buttons, text fields). The table's default 3pt
    /// horizontal intercell spacing keeps a small gap between columns
    /// (macOS standard), while controls themselves occupy 100% of their
    /// own cell.
    private func centeredCellView(_ tv: NSTableView, id: String, control: NSView) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(id + "cell")
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Centers a narrow control (checkbox, drag handle) at its intrinsic size
    /// inside the cell. Stretching a checkbox via leading/trailing pins the
    /// visible glyph to the left of the cell — using centerX keeps it
    /// visually centered under the column header.
    private func centeredNarrowCellView(_ tv: NSTableView, id: String, control: NSView) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(id + "cell")
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func termTableCellView(_ col: NSTableColumn?, row: Int) -> NSView? {
        let rules = RuleStore.shared.terminalRules
        guard row < rules.count else { return nil }
        let rule = rules[row]
        switch col?.identifier.rawValue {
        case "tdrag":
            return centeredNarrowCellView(termTableView, id: "tdrag\(row)", control: DragHandleView())
        case "ton":
            let btn = recycledCheckbox(termTableView, id: "ton")
            btn.state = rule.enabled ? .on : .off; btn.tag = row
            btn.target = self; btn.action = #selector(termToggle(_:))
            return centeredNarrowCellView(termTableView, id: "ton\(row)", control: btn)
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
        case "tnote":
            let tf = recycledNoteField(termTableView)
            tf.stringValue = rule.note; tf.tag = row
            tf.target = self; tf.action = #selector(termNoteChanged(_:))
            return centeredCellView(termTableView, id: "tnote\(row)", control: tf)
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
    @objc private func termNoteChanged(_ s: NSTextField) {
        var r = RuleStore.shared.terminalRules; guard s.tag < r.count else { return }
        r[s.tag].note = s.stringValue; RuleStore.shared.terminalRules = r
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
        let rtv = RuleTableView()
        rtv.dragHandleColumnID = "adrag"
        tv = rtv
        tv.usesAlternatingRowBackgroundColors = true; tv.rowHeight = 24
        let colDrag = NSTableColumn(identifier: .init("adrag")); colDrag.title = ""; colDrag.width = 24; colDrag.minWidth = 24; colDrag.maxWidth = 24
        let colOn = NSTableColumn(identifier: .init("on")); colOn.title = ""; colOn.width = 30; colOn.minWidth = 30; colOn.maxWidth = 30
        let colApp = NSTableColumn(identifier: .init("app")); colApp.title = "Application"; colApp.width = 200; colApp.minWidth = 120
        let colIM = NSTableColumn(identifier: .init("im")); colIM.title = "Input Method"; colIM.width = 200; colIM.minWidth = 120
        tv.addTableColumn(colDrag); tv.addTableColumn(colOn); tv.addTableColumn(colApp); tv.addTableColumn(colIM)
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
        tf.placeholderString = "e.g. opencode, nvim"
        tf.lineBreakMode = .byTruncatingTail; tf.cell?.sendsActionOnEndEditing = true
        return tf
    }

    private func recycledNoteField(_ tv: NSTableView) -> NSTextField {
        let uid = NSUserInterfaceItemIdentifier("tnote")
        if let v = tv.makeView(withIdentifier: uid, owner: nil) as? NSTextField { return v }
        let tf = NSTextField()
        tf.identifier = uid; tf.controlSize = .small; tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.placeholderString = ""
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
        Log.debug("=== TermIMS started ===")
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
