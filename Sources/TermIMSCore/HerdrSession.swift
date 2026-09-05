import Foundation

/// Picking which herdr session the user is actually looking at.
///
/// herdr runs one server per session, each with its own socket, and each server
/// tracks a single globally-focused pane. Several clients — different terminal
/// tabs, different sessions — can be alive at once, so "ask herdr what is
/// focused" is only meaningful once the client in the *focused tab* has been
/// identified. Querying the wrong session reports a pane the user is not
/// looking at.
///
/// Pure so the selection rules can be tested without a running herdr.
public enum HerdrSession {

    /// A running herdr client (the in-terminal process, not the headless
    /// server). `session` is nil for the default session.
    public struct Client: Equatable {
        public let pid: Int32
        public let session: String?
        public let cwd: String?

        public init(pid: Int32, session: String?, cwd: String?) {
            self.pid = pid
            self.session = session
            self.cwd = cwd
        }
    }

    /// Session name a client was started with, or nil for the default session.
    ///
    /// Both spellings are accepted because herdr offers both:
    ///   `herdr --session NAME`
    ///   `herdr session attach NAME`
    public static func name(fromArgv argv: [String]) -> String? {
        if let i = argv.firstIndex(of: "--session"), i + 1 < argv.count {
            let value = argv[i + 1]
            if !value.isEmpty, !value.hasPrefix("-") { return value }
        }
        // `session attach NAME` — the subcommand form. `attach` is optional so
        // future spellings like `session NAME` still resolve.
        if let i = argv.firstIndex(of: "session") {
            var j = i + 1
            if j < argv.count, argv[j] == "attach" { j += 1 }
            if j < argv.count {
                let value = argv[j]
                if !value.isEmpty, !value.hasPrefix("-") { return value }
            }
        }
        return nil
    }

    /// True for the in-terminal client, false for the headless server.
    ///
    /// `herdr server` also runs as a process named `herdr`, shares the cwd it
    /// was launched from, and outlives its client. Counting one as a client
    /// makes every cwd look ambiguous, so both signals are required: the
    /// server takes no `server` subcommand and holds no controlling terminal.
    public static func isClient(argv: [String], hasControllingTty: Bool) -> Bool {
        guard hasControllingTty else { return false }
        return !argv.dropFirst().prefix(1).contains("server")
    }

    /// The client the user is looking at, or nil when it cannot be told apart.
    ///
    /// A single running client is unambiguous. Otherwise the focused tab's cwd
    /// decides: a herdr client inherits the cwd of the shell that launched it,
    /// which is what the terminal reports for that tab. If the cwd matches more
    /// than one client — or none — this returns nil rather than guessing, so
    /// the caller can hold the current input source instead of switching to a
    /// pane the user is not looking at.
    public static func select(clients: [Client], tabCwd: String?) -> Client? {
        if clients.count == 1 { return clients[0] }
        guard clients.count > 1, let tabCwd, !tabCwd.isEmpty else { return nil }
        let matches = clients.filter { $0.cwd == tabCwd }
        return matches.count == 1 ? matches[0] : nil
    }
}
