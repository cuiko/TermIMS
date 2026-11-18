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
        /// Directory the client was launched from — it inherits the shell's cwd.
        public let cwd: String?
        /// Working directory of the session's focused pane, as herdr reports
        /// it. Filled in only when the launch cwd was not decisive, since
        /// reading it costs a socket round trip per session.
        public let paneCwd: String?

        public init(pid: Int32, session: String?, cwd: String?, paneCwd: String? = nil) {
            self.pid = pid
            self.session = session
            self.cwd = cwd
            self.paneCwd = paneCwd
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

    /// A client for the session the user is looking at, or nil when sessions
    /// cannot be told apart. Clients attached to the same session share a
    /// socket and focused pane, so any one of them represents that session.
    ///
    /// A single running session is unambiguous. Otherwise the working directory
    /// the terminal reports for its focused tab decides, matched against two
    /// candidates, because which one the terminal shows depends on herdr:
    ///
    ///   - the client's launch cwd, inherited from the shell that started it;
    ///   - the focused pane's cwd, which herdr forwards to the host terminal —
    ///     so a tab often reports the pane's directory, not the client's.
    ///
    /// The pane cwd is tried first: it tracks the current pane, while the
    /// launch cwd is fixed at startup and can belong to a different session
    /// entirely. If neither yields exactly one session this returns nil rather
    /// than guessing, so the caller holds the current input source instead of
    /// switching to a pane the user is not looking at.
    public static func select(clients: [Client], tabCwd: String?) -> Client? {
        func uniqueSession(_ candidates: [Client]) -> Client? {
            guard let first = candidates.first,
                  candidates.allSatisfy({ ($0.session ?? "") == (first.session ?? "") }) else {
                return nil
            }
            return first
        }

        if let client = uniqueSession(clients) { return client }
        guard clients.count > 1, let tabCwd, !tabCwd.isEmpty else { return nil }
        for key in [\Client.paneCwd, \Client.cwd] {
            let matches = clients.filter { $0[keyPath: key] == tabCwd }
            if let client = uniqueSession(matches) { return client }
        }
        return nil
    }
}
