import Foundation

/// Choosing which terminal surface has focus when the working directory alone
/// cannot say.
///
/// Terminals like Ghostty report the focused tab's cwd and title but never its
/// tty, so several tabs open on the same directory look identical from outside.
/// The title is the tie-breaker: it is genuinely per-tab, and its *shape* says
/// whether a foreground program owns the tab or the user is sitting at a
/// prompt. Correlating that with which surface actually runs a non-shell
/// process separates "the tab running an agent" from "the tab at a shell
/// prompt" even though both report the same directory.
///
/// Pure, so each rule can be exercised against a fixed set of surfaces.
public enum SurfaceNarrowing {

    /// One candidate surface (a tty) under the terminal.
    public struct Surface: Equatable {
        /// Opaque key — the caller maps it back to its own tty handle.
        public let id: String
        /// Processes in the surface's foreground process group.
        public let foreground: [String]
        /// Every process on the surface. A foreground group flips while an
        /// agent shells out, so the full list is what rules match against.
        public let all: [String]

        public init(id: String, foreground: [String], all: [String]) {
            self.id = id
            self.foreground = foreground
            self.all = all
        }
    }

    public static let shellNames: Set<String> = ["zsh", "bash", "fish", "login"]

    private static func isShell(_ name: String) -> Bool {
        shellNames.contains(name)
    }

    /// The focused surface, or every surface still in contention.
    ///
    /// Returning more than one is a deliberate "cannot tell": the caller is
    /// expected to require agreement across them rather than pick one, so an
    /// idle tab is never switched on account of what a sibling tab is running.
    public static func narrow(_ surfaces: [Surface], title: String, cwd: String) -> [Surface] {
        guard surfaces.count > 1 else { return surfaces }

        // A title that is a bare shell name, or that shows this tab's own cwd,
        // means no foreground program has claimed it — the user is at a prompt.
        if isShell(title) || title.showsCwd(cwd) {
            let atPrompt = surfaces.first { $0.foreground.allSatisfy(isShell) }
            return [atPrompt ?? surfaces[0]]
        }

        // Otherwise a foreground program set the title, so surfaces sitting at
        // a bare prompt are not the focused one.
        var busy = surfaces.filter { $0.foreground.contains(where: { !isShell($0) }) }

        // A multiplexer client is not the program the title describes. A
        // surface running only `herdr` is then a sibling tab, and keeping it
        // would make every candidate disagree.
        //
        // The title must be tested by mention, not equality: a herdr tab's
        // title is whatever herdr or the shell put there — `herdr`, but also
        // `herdr session attach work` or `π - herdr`. Demanding an exact match
        // discards the focused herdr tab itself, leaving only its shell.
        if !title.mentionsAny(of: ["herdr"]) {
            busy = busy.filter { surface in
                let nonShell = surface.all.filter { !isShell($0) }
                return !(nonShell.count == 1 &&
                         nonShell[0].caseInsensitiveCompare("herdr") == .orderedSame)
            }
        }

        guard busy.count > 1 else {
            return [busy.first ?? surfaces[0]]
        }

        // Several busy surfaces: the title may name the program on one of them.
        // Shell names are excluded so "running zsh in foo" does not match every
        // surface — they all have a shell.
        for surface in busy {
            let nonShell = surface.all.filter { !isShell($0) }
            if title.mentionsAny(of: nonShell) { return [surface] }
            // Ghostty titles "Pi" while p_comm reads `pi`; mentionsAny needs the
            // title to contain the name, equality covers the short-name case.
            if nonShell.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
                return [surface]
            }
        }
        return busy
    }
}
