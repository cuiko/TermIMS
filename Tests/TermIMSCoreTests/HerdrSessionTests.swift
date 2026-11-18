import Testing
@testable import TermIMSCore

@Suite("herdr session selection")
struct HerdrSessionTests {

    // MARK: argv → session name

    @Test("recognises both session spellings", arguments: [
        (["herdr"], String?.none),
        (["herdr", "--session", "work"], "work"),
        (["herdr", "session", "attach", "work"], "work"),
        (["herdr", "session", "work"], "work"),
        (["herdr", "--session"], nil),              // missing value
        (["herdr", "--session", "--flag"], nil),    // value is a flag
    ])
    func sessionName(argv: [String], expected: String?) {
        #expect(HerdrSession.name(fromArgv: argv) == expected)
    }

    // MARK: client vs server

    /// The server shares the client's process name and launch cwd, so failing
    /// to exclude it makes every cwd ambiguous and nothing ever resolves.
    @Test("only the in-terminal client counts", arguments: [
        (["herdr"], true, true),
        (["herdr", "session", "attach", "work"], true, true),
        (["herdr", "server"], false, false),          // headless server
        (["herdr", "server"], true, false),           // server, even with a tty
        (["herdr"], false, false),                    // no controlling terminal
    ])
    func clientDetection(argv: [String], hasTty: Bool, expected: Bool) {
        #expect(HerdrSession.isClient(argv: argv, hasControllingTty: hasTty) == expected)
    }

    // MARK: client selection

    static let first = HerdrSession.Client(pid: 1, session: nil, cwd: "/Users/x/.config/editor")
    static let other = HerdrSession.Client(pid: 2, session: "work",
                                           cwd: "/Users/x/go/work")

    /// What the machine actually looks like: herdr forwards the focused pane's
    /// cwd to the host terminal, so the tab reports a directory the client was
    /// never launched from.
    static let firstWithPane = HerdrSession.Client(pid: 1, session: nil,
                                                  cwd: "/Users/x/.config/editor",
                                                  paneCwd: "/Users/x/repo/api")
    static let otherWithPane = HerdrSession.Client(pid: 2, session: "work",
                                                   cwd: "/Users/x/go/work",
                                                   paneCwd: "/Users/x/go/work")

    @Test("a lone client needs no disambiguation")
    func singleClient() {
        #expect(HerdrSession.select(clients: [Self.other], tabCwd: nil) == Self.other)
    }

    @Test("clients attached to one session need no disambiguation", arguments: [
        String?.none, "work",
    ])
    func sharedSession(session: String?) {
        let a = HerdrSession.Client(pid: 1, session: session, cwd: "/Users/x")
        let b = HerdrSession.Client(pid: 2, session: session, cwd: "/elsewhere")
        // A pane can forward a cwd neither client was launched from.
        for tabCwd in [String?.none, "/pane/project"] {
            #expect(HerdrSession.select(clients: [a, b], tabCwd: tabCwd) == a)
        }
    }

    @Test("nil and empty session names use the same default socket")
    func defaultSessionSpellings() {
        let a = HerdrSession.Client(pid: 1, session: nil, cwd: "/Users/x")
        let b = HerdrSession.Client(pid: 2, session: "", cwd: "/Users/x")
        #expect(HerdrSession.select(clients: [a, b], tabCwd: nil) == a)
    }

    @Test("cwd matches may name several clients in one session", arguments: [false, true])
    func sharedSessionCwd(usePaneCwd: Bool) {
        let a = HerdrSession.Client(pid: 1, session: nil,
                                   cwd: usePaneCwd ? "/launch/a" : "/shared",
                                   paneCwd: usePaneCwd ? "/shared" : nil)
        let b = HerdrSession.Client(pid: 2, session: nil,
                                   cwd: usePaneCwd ? "/launch/b" : "/shared",
                                   paneCwd: usePaneCwd ? "/shared" : nil)
        let other = HerdrSession.Client(pid: 3, session: "work", cwd: "/other")
        #expect(HerdrSession.select(clients: [a, b, other], tabCwd: "/shared") == a)
    }

    @Test("every client's cwd remains available when sessions have multiple clients")
    func duplicateSessionKeepsCwds() {
        let a = HerdrSession.Client(pid: 1, session: nil, cwd: "/first")
        let b = HerdrSession.Client(pid: 2, session: nil, cwd: "/second")
        let other = HerdrSession.Client(pid: 3, session: "work", cwd: "/other")
        #expect(HerdrSession.select(clients: [a, b, other], tabCwd: "/second") == b)
    }

    @Test("multiple clients do not resolve ambiguity between different sessions")
    func sharedPaneCwdAcrossSessions() {
        let a = HerdrSession.Client(pid: 1, session: nil, cwd: "/launch/a", paneCwd: "/shared")
        let b = HerdrSession.Client(pid: 2, session: nil, cwd: "/launch/b", paneCwd: "/shared")
        let other = HerdrSession.Client(pid: 3, session: "work", cwd: "/launch/c", paneCwd: "/shared")
        #expect(HerdrSession.select(clients: [a, b, other], tabCwd: "/shared") == nil)
    }

    @Test("the focused tab's cwd picks the client")
    func cwdPicksClient() {
        let clients = [Self.first, Self.other]
        #expect(HerdrSession.select(clients: clients, tabCwd: Self.other.cwd) == Self.other)
        #expect(HerdrSession.select(clients: clients, tabCwd: Self.first.cwd) == Self.first)
    }

    @Test("the focused pane's cwd picks the client when the launch cwd cannot")
    func paneCwdPicksClient() {
        let clients = [Self.firstWithPane, Self.otherWithPane]
        // The tab reports the pane directory; no client was launched there.
        #expect(HerdrSession.select(clients: clients, tabCwd: "/Users/x/repo/api") == Self.firstWithPane)
    }

    @Test("the launch cwd still resolves when no pane cwd is known")
    func launchCwdStillWorks() {
        #expect(HerdrSession.select(clients: [Self.first, Self.other],
                                    tabCwd: "/Users/x/.config/editor") == Self.first)
    }

    /// A pane cwd is current, a launch cwd is fixed at startup, so when both
    /// could match the pane must win — otherwise a stale directory decides.
    @Test("pane cwd outranks another client's launch cwd")
    func paneCwdOutranksLaunchCwd() {
        let a = HerdrSession.Client(pid: 1, session: nil, cwd: "/shared", paneCwd: "/work/a")
        let b = HerdrSession.Client(pid: 2, session: "b", cwd: "/work/a", paneCwd: "/work/b")
        #expect(HerdrSession.select(clients: [a, b], tabCwd: "/work/a") == a)
    }

    /// Guessing here would report a pane from a session the user is not
    /// looking at — exactly the failure this selection exists to prevent.
    @Test("ambiguity yields no client rather than a guess", arguments: [
        String?.none,                       // no cwd from the terminal
        "/somewhere/else",                  // matches neither
    ])
    func ambiguityYieldsNil(tabCwd: String?) {
        #expect(HerdrSession.select(clients: [Self.first, Self.other], tabCwd: tabCwd) == nil)
    }

    @Test("two clients sharing a cwd stay ambiguous")
    func sharedCwdAmbiguous() {
        let a = HerdrSession.Client(pid: 1, session: nil, cwd: "/Users/x")
        let b = HerdrSession.Client(pid: 2, session: "other", cwd: "/Users/x")
        #expect(HerdrSession.select(clients: [a, b], tabCwd: "/Users/x") == nil)
    }
}
