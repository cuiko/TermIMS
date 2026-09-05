import Testing
import Darwin
@testable import TermIMSCore

/// Every case here is a real misidentification hit while building terminal
/// rules — the reason this logic exists. Keeping them as tests means a future
/// tweak to one rule cannot silently break another.
@Suite("ProcessNaming")
struct ProcessNamingTests {

    // MARK: needsArgv — the sysctl-avoidance gate

    @Test("plain binaries never trigger an argv read")
    func plainBinarySkipsArgv() {
        #expect(ProcessNaming.needsArgv(comm: "zsh") == false)
        #expect(ProcessNaming.needsArgv(comm: "claude") == false)
        #expect(ProcessNaming.needsArgv(comm: "vim") == false)
    }

    @Test("runtimes and truncated names do trigger an argv read")
    func runtimeOrTruncatedNeedsArgv() {
        #expect(ProcessNaming.needsArgv(comm: "node"))
        #expect(ProcessNaming.needsArgv(comm: "Python"))
        #expect(ProcessNaming.needsArgv(comm: "python3.12"))
        // A fully populated p_comm (MAXCOMLEN - 1) means likely truncation.
        #expect(ProcessNaming.needsArgv(comm: String(repeating: "a", count: Int(MAXCOMLEN) - 1)))
    }

    // MARK: runtime unwrapping

    @Test("node-wrapped agent resolves to the tool name", arguments: [
        (["node", "/opt/homebrew/bin/claude"], "claude"),
        (["node", "-r", "./preload.js", "/opt/claude"], "claude"),   // value flag skipped
        (["node", "--", "/opt/claude"], "claude"),                   // -- separator
        (["bun", "run", "/pkg/claude"], "claude"),                   // launcher subcommand
        (["node", "/usr/local/lib/gemini.js"], "gemini"),            // extension stripped
    ])
    func unwrapsRuntimeScript(argv: [String], expected: String) {
        #expect(ProcessNaming.resolve(comm: "node", argv: argv) == expected)
    }

    @Test("python-wrapped tool resolves to the tool name")
    func unwrapsPython() {
        #expect(ProcessNaming.resolve(comm: "Python", argv: ["Python", "/usr/local/bin/aider"]) == "aider")
    }

    /// Node's `process.title = "pi"` rewrites argv[0] so `ps -o comm` shows
    /// `pi` while kinfo `p_comm` stays `node`, and argv carries no script path.
    @Test("process.title rewrite is honoured when argv has no script path")
    func honoursProcessTitleRewrite() {
        #expect(ProcessNaming.resolve(comm: "node", argv: ["pi"]) == "pi")
    }

    /// A generic entrypoint hides the tool; climb to the package directory.
    @Test("generic entrypoint climbs to the package directory")
    func climbsToPackageDir() {
        let argv = ["node", "/Users/x/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"]
        #expect(ProcessNaming.resolve(comm: "node", argv: argv) == "pi-coding-agent")
    }

    /// A version/build directory is not a tool name — fall through to argv0.
    @Test("version directory falls through to argv0")
    func versionDirFallsThroughToArgv0() {
        let argv = ["claude", "/opt/foo/2026.07.23-e383d2b/cli.js"]
        #expect(ProcessNaming.resolve(comm: "node", argv: argv) == "claude")
    }

    @Test("inline eval has no script name and keeps comm", arguments: [
        ["node", "-e", "console.log(1)"],
        ["node", "--eval", "1+1"],
        ["python3", "-c", "print(1)"],
        ["python3", "-m", "http.server"],
    ])
    func inlineEvalKeepsComm(argv: [String]) {
        let comm = argv[0] == "node" ? "node" : "python3"
        #expect(ProcessNaming.resolve(comm: comm, argv: argv) == comm)
    }

    // MARK: truncation repair

    @Test("truncated comm is de-truncated from argv0")
    func deTruncatesFromArgv0() {
        let comm = "some-very-long-"   // 15 chars == MAXCOMLEN - 1
        #expect(comm.utf8.count == Int(MAXCOMLEN) - 1)
        let argv = ["/usr/local/bin/some-very-long-binary"]
        #expect(ProcessNaming.resolve(comm: comm, argv: argv) == "some-very-long-binary")
    }

    /// argv0 must share the comm prefix, otherwise a login shell's `-zsh`
    /// (or any rewritten argv0) could replace a perfectly good comm.
    @Test("mismatched argv0 does not replace a truncated comm")
    func mismatchedArgv0Rejected() {
        let comm = String(repeating: "a", count: Int(MAXCOMLEN) - 1)
        #expect(ProcessNaming.resolve(comm: comm, argv: ["/bin/-zsh"]) == comm)
    }

    // MARK: degradation

    @Test("unreadable argv degrades to comm")
    func unreadableArgvKeepsComm() {
        #expect(ProcessNaming.resolve(comm: "node", argv: nil) == "node")
        #expect(ProcessNaming.resolve(comm: "node", argv: []) == "node")
    }

    @Test("non-runtime binaries are returned untouched")
    func nonRuntimeUntouched() {
        #expect(ProcessNaming.resolve(comm: "zsh", argv: ["-zsh"]) == "zsh")
        #expect(ProcessNaming.resolve(comm: "herdr", argv: ["herdr"]) == "herdr")
    }
}
