import Testing
import Foundation
@testable import TermIMSCore

@Suite("Title heuristics")
struct TitleHeuristicsTests {

    // MARK: rule pattern matching

    @Test("slash-delimited patterns are treated as regex")
    func regexPatterns() {
        #expect("π - herdr".matches(pattern: "/^π/"))
        #expect("herdr - π".matches(pattern: "/^π/") == false)
        #expect("✳ Claude Code".matches(pattern: "/claude/i"))
        #expect("✳ Claude Code".matches(pattern: "/claude/") == false)  // case-sensitive without /i
    }

    /// A path-looking pattern is not a regex — users must be able to match
    /// literal strings like "/usr/bin/foo" without escaping.
    @Test("path-like patterns fall back to literal substring")
    func pathPatternsAreLiteral() {
        #expect("running /usr/bin/foo now".matches(pattern: "/usr/bin/foo"))
        #expect("nothing here".matches(pattern: "/usr/bin/foo") == false)
    }

    @Test("bare patterns are case-insensitive substrings")
    func bareSubstring() {
        #expect("✳ Claude Code".matches(pattern: "claude"))
        #expect("✳ Claude Code".matches(pattern: "CLAUDE"))
        #expect("zsh".matches(pattern: "claude") == false)
    }

    @Test("empty pattern never matches")
    func emptyPattern() {
        #expect("anything".matches(pattern: "") == false)
    }

    // MARK: title ↔ process-name association

    @Test("mentionsAny finds a process name inside the title")
    func mentionsAny() {
        #expect("✳ Claude Code".mentionsAny(of: ["claude"]))
        #expect("✳ Claude Code".mentionsAny(of: ["vim", "claude"]))
        #expect("✳ Claude Code".mentionsAny(of: ["vim"]) == false)
        #expect("✳ Claude Code".mentionsAny(of: [""]) == false)   // empty names never match
        #expect("✳ Claude Code".mentionsAny(of: []) == false)
    }

    // MARK: title ↔ cwd association

    @Test("showsCwd accepts the forms terminals actually render")
    func showsCwdForms() {
        let cwd = "/Users/x/workspace/TermIMS"
        #expect("TermIMS".showsCwd(cwd))                    // basename only
        #expect("/Users/x/workspace/TermIMS".showsCwd(cwd)) // absolute path
        #expect("…/workspace/TermIMS".showsCwd(cwd))        // Ghostty truncation
    }

    @Test("showsCwd accepts the tilde-collapsed form")
    func showsCwdTilde() {
        let cwd = NSHomeDirectory() + "/projects/demo"
        #expect("~/projects/demo".showsCwd(cwd))
    }

    @Test("showsCwd rejects unrelated titles")
    func showsCwdRejects() {
        let cwd = "/Users/x/workspace/TermIMS"
        #expect("Obsidian".showsCwd(cwd) == false)
        #expect("/etc/hosts".showsCwd(cwd) == false)
        #expect("".showsCwd(cwd) == false)
    }
}
