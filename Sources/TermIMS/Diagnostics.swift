import Cocoa
import TermIMSCore

/// Headless one-shot dump of what the resolver sees for the frontmost app.
///
/// Exists so the resolution path can be observed from a shell — `TermIMS
/// diagnose` — instead of only through the menu bar. Every signal the matcher
/// consumes is printed, so a wrong switch can be traced to the signal that
/// caused it without reading the debug log.
enum Diagnostics {
    static func run(bundleID: String? = nil, title: String? = nil, cwd: String? = nil) -> Int32 {
        guard AXIsProcessTrusted() else {
            emit(["error": "accessibility-not-trusted",
                  "hint": "run the installed bundle: /Applications/TermIMS.app/Contents/MacOS/TermIMS diagnose"])
            return 2
        }
        // A replay names the app it is replaying: otherwise the result depends
        // on whichever window happens to be in front while the check runs.
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let bid = bundleID ?? frontID else {
            emit(["error": "no-frontmost-app"])
            return 2
        }

        let monitor = FocusMonitor()
        if title != nil || cwd != nil {
            monitor.signalOverride = FocusMonitor.SignalOverride(title: title, cwd: cwd)
        }
        monitor.attach(bid)
        // AX observers deliver asynchronously; a short spin lets the element
        // tree settle before we read it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        var out = monitor.diagnosticSnapshot(bid: bid)
        out["frontmost"] = frontID ?? NSNull()
        out["resolvedFor"] = bid
        if bundleID != nil || title != nil || cwd != nil { out["replayed"] = true }
        // Names come from the system, never assumed: which sources exist and
        // which one is active are both up to the user's setup.
        let available = listInputSources()
        func label(_ id: String?) -> Any {
            guard let id else { return NSNull() }
            guard let name = available.first(where: { $0.id == id })?.name else { return id }
            return "\(name) [\(id)]"
        }
        out["currentInputSource"] = label(currentInputSourceID())
        out["resolvedInputSource"] = label(out["resolved"] as? String)
        out["resolvedOnEntryName"] = label(out["resolvedOnEntry"] as? String)
        out["resolvedWithinName"] = label(out["resolvedWithin"] as? String)
        out["availableInputSources"] = available.map { "\($0.name) [\($0.id)]" }
        emit(out)
        return 0
    }


    /// herdr resolution for a given focused-tab cwd. Needs no Accessibility
    /// grant — the whole path is sysctl plus the herdr socket — so the session
    /// selection can be checked from a plain `swift build` binary instead of a
    /// reinstalled, re-authorised bundle.
    static func herdrProbe(tabCwd: String?) -> Int32 {
        let clients = HerdrClient.runningClients().map { c -> [String: Any] in
            ["pid": Int(c.pid), "session": c.session ?? "«default»", "cwd": (c.cwd as Any?) ?? NSNull()]
        }
        var out: [String: Any] = ["tabCwd": (tabCwd as Any?) ?? NSNull(), "clients": clients]
        if let socket = HerdrClient.socketPath(tabCwd: tabCwd) {
            out["socket"] = socket
            if let pane = HerdrClient.focusedPane(tabCwd: tabCwd) {
                out["pane"] = ["paneID": (pane.paneID as Any?) ?? NSNull(),
                               "agent": (pane.agent as Any?) ?? NSNull(),
                               "title": (pane.title as Any?) ?? NSNull(),
                               "candidates": pane.candidates]
            } else {
                out["pane"] = NSNull()
            }
        } else {
            out["socket"] = NSNull()
            out["reason"] = "ambiguous-or-no-client — holding rather than guessing"
        }
        emit(out)
        return 0
    }

    private static func emit(_ dict: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: dict,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data ?? Data("{}".utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
