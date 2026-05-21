import Foundation

// Shared predicates used by terminals that fall through to the generic
// matching path (no native tty channel). Both Ghostty (cwd-based path) and
// Warp (descendant fallback) use these to ask the same two questions about
// the focused window's title; the orchestration around them stays per-path
// because the upstream signals differ (Ghostty has AXDocument cwd, Warp
// doesn't).

extension String {
    /// Match self against a user-supplied rule pattern.
    /// `/body/` or `/body/i` is treated as an ICU regex (case-insensitive
    /// with `i`); anything else is a case-insensitive substring match.
    /// Patterns missing the closing slash, with empty body, or with
    /// unknown flags fall back to literal substring so users can still
    /// match strings like "/usr/bin/foo" without escaping.
    func matches(pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if pattern.count >= 2, pattern.first == "/",
           let lastSlash = pattern.lastIndex(of: "/"),
           lastSlash != pattern.startIndex {
            let flagsStr = pattern[pattern.index(after: lastSlash)...]
            let body = pattern[pattern.index(after: pattern.startIndex)..<lastSlash]
            if !body.isEmpty, flagsStr.allSatisfy({ $0 == "i" }) {
                var opts: NSRegularExpression.Options = []
                if flagsStr.contains("i") { opts.insert(.caseInsensitive) }
                if let re = try? NSRegularExpression(pattern: String(body), options: opts) {
                    let range = NSRange(self.startIndex..., in: self)
                    return re.firstMatch(in: self, range: range) != nil
                }
            }
        }
        return self.localizedCaseInsensitiveContains(pattern)
    }

    /// Does this title contain any of `processNames` as a case-insensitive
    /// substring? Empty names never match.
    func mentionsAny(of processNames: [String]) -> Bool {
        let lower = self.lowercased()
        return processNames.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
    }

    /// Does this title look like it is displaying `cwd` (the focused tab's
    /// own working directory)? Matches: the cwd's basename exactly, the
    /// absolute path as substring, the tilde-collapsed form as substring,
    /// and Ghostty's "…/tail/of/path" truncation. A title that mentions some
    /// other path will not match — useful to distinguish a shell prompt
    /// showing the tab's cwd from a foreground command title that happens
    /// to contain unrelated paths.
    func showsCwd(_ cwd: String) -> Bool {
        guard !self.isEmpty else { return false }
        let base = (cwd as NSString).lastPathComponent
        if self == base { return true }
        if self.contains(cwd) { return true }
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            let tilded = "~" + cwd.dropFirst(home.count)
            if self.contains(tilded) { return true }
        }
        if self.hasPrefix("…"), cwd.hasSuffix(String(self.dropFirst())) { return true }
        return false
    }
}
