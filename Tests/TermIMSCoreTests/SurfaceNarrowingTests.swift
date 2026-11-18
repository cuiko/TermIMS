import Testing
@testable import TermIMSCore

@Suite("Surface narrowing")
struct SurfaceNarrowingTests {
    typealias Surface = SurfaceNarrowing.Surface

    static let cwd = "/Users/x/workspace/proj"
    /// A tab running Claude Code: the agent owns the foreground group.
    static let agentTab = Surface(id: "ttys001",
                                  foreground: ["claude", "node"],
                                  all: ["claude", "node", "zsh"])
    /// A tab sitting at a prompt in the same directory.
    static let shellTab = Surface(id: "ttys002",
                                  foreground: ["zsh"],
                                  all: ["zsh", "login"])

    /// The case that makes cwd alone useless: same directory, different
    /// programs, and they must not resolve to the same input source.
    @Test("same cwd, agent vs prompt — the agent title picks the agent tab", arguments: [
        "◐ 查看终端程序进程读取方式",   // circle spinner
        "✳ Claude Code",
        "⠋ thinking",
    ])
    func agentTitlePicksAgentTab(title: String) {
        let picked = SurfaceNarrowing.narrow([Self.shellTab, Self.agentTab], title: title, cwd: Self.cwd)
        #expect(picked == [Self.agentTab])
    }

    @Test("same cwd — a cwd-shaped title picks the tab at a prompt", arguments: [
        "/Users/x/workspace/proj",   // absolute
        "proj",                      // basename
        "…/workspace/proj",          // Ghostty truncation
        "zsh",                       // bare shell name
    ])
    func cwdTitlePicksShellTab(title: String) {
        let picked = SurfaceNarrowing.narrow([Self.agentTab, Self.shellTab], title: title, cwd: Self.cwd)
        #expect(picked == [Self.shellTab])
    }

    @Test("a lone surface needs no narrowing")
    func singleSurface() {
        #expect(SurfaceNarrowing.narrow([Self.agentTab], title: "anything", cwd: Self.cwd) == [Self.agentTab])
    }

    @Test("the title naming a program picks that surface")
    func titleNamesProgram() {
        let vim = Surface(id: "a", foreground: ["first"], all: ["first", "zsh"])
        let make = Surface(id: "b", foreground: ["make"], all: ["make", "zsh"])
        #expect(SurfaceNarrowing.narrow([vim, make], title: "first README.md", cwd: Self.cwd) == [vim])
        // Ghostty titles "Pi" while the process reads `pi` — equality, not containment.
        let pi = Surface(id: "c", foreground: ["pi"], all: ["pi", "zsh"])
        #expect(SurfaceNarrowing.narrow([pi, make], title: "Pi", cwd: Self.cwd) == [pi])
    }

    /// Two busy surfaces the title cannot tell apart stay ambiguous, so the
    /// caller holds instead of switching on a coin flip.
    @Test("indistinguishable busy surfaces stay ambiguous")
    func ambiguousStaysAmbiguous() {
        let a = Surface(id: "a", foreground: ["node"], all: ["node", "zsh"])
        let b = Surface(id: "b", foreground: ["node"], all: ["node", "zsh"])
        #expect(SurfaceNarrowing.narrow([a, b], title: "something else", cwd: Self.cwd).count == 2)
    }

    static let herdrTab = Surface(id: "h", foreground: ["herdr"], all: ["herdr", "zsh", "login"])

    /// An idle herdr client shares $HOME with other tabs; counting it would
    /// make every candidate disagree and sink the match.
    @Test("an idle herdr sibling is dropped when the title belongs elsewhere")
    func herdrSiblingDropped() {
        #expect(SurfaceNarrowing.narrow([Self.herdrTab, Self.agentTab],
                                        title: "✳ Claude Code", cwd: Self.cwd) == [Self.agentTab])
    }

    /// Observed live. A herdr tab's title is whatever herdr or the shell put
    /// there, so matching it by equality against "herdr" discarded the focused
    /// herdr tab and left only its shell — the tab then resolved to the
    /// terminal default instead of the agent in its pane.
    @Test("a focused herdr tab survives, whatever its title spells", arguments: [
        "herdr",
        "herdr session attach work",
        "π - herdr",
        "✳ Claude Code - herdr",
    ])
    func focusedHerdrTabSurvives(title: String) {
        let plainShell = Surface(id: "s", foreground: ["zsh"], all: ["zsh", "login"])
        #expect(SurfaceNarrowing.narrow([plainShell, Self.herdrTab],
                                        title: title, cwd: Self.cwd) == [Self.herdrTab])
    }
}
