import Testing
@testable import TermIMSCore

/// Window-title shapes coding agents actually produce, captured from a live
/// Ghostty window. Title is the one signal a terminal reports per tab without
/// guesswork, so what it looks like decides whether title rules can carry the
/// match — these cases pin the shapes down.
@Suite("Agent title shapes")
struct AgentTitleTests {

    /// Claude Code animates its title with more than one spinner family:
    /// braille (U+2800 block), the ✳ idle marker, and circle quadrants
    /// (U+25D0…). A rule written for only the first two silently stops
    /// matching whenever the third is on screen.
    @Test("a braille + ✳ class does not cover circle spinners")
    func brailleClassMissesCircleSpinners() {
        let brailleAndAsterisk = "/^[⠁-⣿✳] /"
        #expect("⠋ thinking".matches(pattern: brailleAndAsterisk))
        #expect("✳ Claude Code".matches(pattern: brailleAndAsterisk))
        // Observed live; U+25D0 is outside the class above.
        #expect("◐ 查看终端程序进程读取方式".matches(pattern: brailleAndAsterisk) == false)
    }

    @Test("a class spanning all observed spinners covers them", arguments: [
        "⠋ thinking",
        "✳ Claude Code",
        "◐ 查看终端程序进程读取方式",
        "◓ building",
    ])
    func widenedClassCoversAll(title: String) {
        #expect(title.matches(pattern: "/^[⠁-⣿✳◐-◓] /"))
    }

    @Test("plain shell and path titles stay unmatched", arguments: [
        "~/.config/herdr",
        "zsh",
        "herdr",
    ])
    func nonAgentTitlesUnmatched(title: String) {
        #expect(title.matches(pattern: "/^[⠁-⣿✳◐-◓] /") == false)
    }
}
