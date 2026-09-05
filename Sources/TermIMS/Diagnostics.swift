import Cocoa
import TermIMSCore

/// Headless one-shot dump of what the resolver sees for the frontmost app.
///
/// Exists so the resolution path can be observed from a shell — `TermIMS
/// diagnose` — instead of only through the menu bar. Every signal the matcher
/// consumes is printed, so a wrong switch can be traced to the signal that
/// caused it without reading the debug log.
enum Diagnostics {
    static func run() -> Int32 {
        guard AXIsProcessTrusted() else {
            emit(["error": "accessibility-not-trusted",
                  "hint": "run the installed bundle: /Applications/TermIMS.app/Contents/MacOS/TermIMS diagnose"])
            return 2
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bid = front.bundleIdentifier else {
            emit(["error": "no-frontmost-app"])
            return 2
        }

        let monitor = FocusMonitor()
        monitor.attach(bid)
        // AX observers deliver asynchronously; a short spin lets the element
        // tree settle before we read it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        var out = monitor.diagnosticSnapshot(bid: bid)
        out["frontmost"] = bid
        out["currentInputSource"] = currentInputSourceID() ?? "unknown"
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

    private static func currentInputSourceID() -> String? {
        listInputSources().first { $0.name == currentInputSourceName() }?.id
    }

    private static func emit(_ dict: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: dict,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data ?? Data("{}".utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
