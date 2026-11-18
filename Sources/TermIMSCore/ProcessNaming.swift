import Foundation
import Darwin

/// Pure derivation of a process's "real" name for rule matching.
///
/// The kernel's `kinfo_proc.p_comm` is a poor identity for the tools users
/// write rules against: it is capped at `MAXCOMLEN` characters, and for agents
/// launched through a runtime it names the interpreter (`node`, `python`)
/// rather than the tool. These helpers recover the intended name from the
/// process's argument vector.
///
/// Everything here is a pure function of `(comm, argv)` — no syscalls — so the
/// naming rules can be exercised directly in tests. The caller owns reading
/// argv (a sysctl) and should skip it when `needsArgv(comm:)` is false.
public enum ProcessNaming {

    // Runtimes that launch an agent as a script argument (e.g. `node
    // .../claude`, `Python .../aider`). For these the kernel `p_comm` names
    // the interpreter, not the tool the user wrote a rule for, so we recover
    // the wrapped script's name from argv instead.
    static let genericRuntimes: Set<String> = ["node", "bun", "deno", "python", "python3"]

    // Argv flags that mean "no script file follows" (inline eval / module),
    // so there is no basename worth extracting.
    static let runtimeEvalFlags: Set<String> = ["-e", "--eval", "-p", "--print", "-c", "-m"]

    // Runtime flags that consume the following argv token as their value —
    // skipped so the value isn't mistaken for the script path.
    static let runtimeValueFlags: Set<String> = [
        "-r", "--require", "--loader", "--import", "--experimental-loader", "--conditions",
    ]

    // Launcher subcommands that precede the real script (`bun run …`,
    // `deno run …`). Must not be treated as the script path themselves.
    static let runtimeLauncherSubcommands: Set<String> = ["run"]

    // Generic entrypoint basenames that hide the real tool — climb to the
    // package directory instead (e.g. `…/pi-coding-agent/dist/cli.js` →
    // `pi-coding-agent`, which still substring-matches a `pi` process rule).
    static let genericScriptNames: Set<String> = [
        "cli", "index", "main", "bin", "app", "run", "start", "bundle",
    ]

    /// True when reading argv could improve on `comm` — either `comm` names a
    /// generic runtime, looks like a version string, or is long enough to have
    /// been truncated. Lets the caller avoid a sysctl for most processes.
    public static func needsArgv(comm: String) -> Bool {
        isGenericRuntime(comm) || isVersionLikeName(comm) || isTruncated(comm)
    }

    /// Best-effort real name for rule matching. `argv` is the process's
    /// argument vector, or nil when it could not be read (process gone, or
    /// owned by another user). Falls back to `comm` whenever argv adds nothing.
    public static func resolve(comm: String, argv: [String]?) -> String {
        let lower = comm.lowercased()
        let isRuntime = isGenericRuntime(comm)
        let truncated = isTruncated(comm)
        let versionLike = isVersionLikeName(comm)
        guard isRuntime || truncated || versionLike, let argv, !argv.isEmpty else { return comm }

        if isRuntime, let wrapped = wrappedScriptName(argv: argv) {
            return wrapped
        }

        // Node.js `process.title = "pi"` (and similar) rewrites argv[0] so
        // `ps -o comm` shows `pi`, while kinfo `p_comm` stays `node`. When
        // there's no script path in argv — just `["pi"]` — treat argv0 as
        // the real name for rule matching.
        if isRuntime, let argv0 = argv.first {
            let base = (argv0 as NSString).lastPathComponent
            let cleaned = base.hasPrefix("-") ? String(base.dropFirst()) : base
            let cl = cleaned.lowercased()
            if !cleaned.isEmpty,
               !genericRuntimes.contains(cl),
               !cl.hasPrefix("python") {
                return cleaned
            }
        }

        // Some native launchers expose their installed version as `comm` and
        // rewrite argv[0] to the command name. Restore that name only when it
        // is not itself version-shaped; paths ending in a version directory
        // therefore leave the original `comm` untouched.
        if versionLike, let argv0 = argv.first {
            let base = (argv0 as NSString).lastPathComponent
            if !base.isEmpty, !base.hasPrefix("-"), !isVersionLikeName(base) {
                return base
            }
        }

        // De-truncate a native binary via argv[0]. Guard with a prefix check so
        // a login shell's `-zsh` argv[0] never replaces a clean `comm`.
        if truncated, let argv0 = argv.first {
            let base = (argv0 as NSString).lastPathComponent
            if base.lowercased().hasPrefix(lower), base.utf8.count > comm.utf8.count {
                return base
            }
        }
        return comm
    }

    /// Extract the wrapped script's name from a runtime's argv (skipping flags),
    /// e.g. `["node", "-r", "x", "/opt/claude", …]` → `claude`,
    /// `["bun", "run", "claude", …]` → `claude`. Returns nil for inline-eval /
    /// module invocations that name no script file.
    static func wrappedScriptName(argv: [String]) -> String? {
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" {
                return i + 1 < argv.count ? scriptBasename(argv[i + 1]) : nil
            }
            if runtimeEvalFlags.contains(arg) { return nil }
            if runtimeLauncherSubcommands.contains(arg) {
                i += 1
                continue
            }
            if arg.hasPrefix("-") {
                if runtimeValueFlags.contains(arg) { i += 1 }
                i += 1
                continue
            }
            return scriptBasename(arg)
        }
        return nil
    }

    /// Basename of a script path with a common script extension stripped, so
    /// `.../gemini.js` reads as `gemini`. npm bin symlinks are extensionless
    /// and already yield the tool name directly. Generic entrypoints climb
    /// one packaging directory (`dist`/`bin`/…) so `dist/cli.js` maps to the
    /// package folder. If that folder looks like a version/build id (e.g.
    /// `2026.07.23-e383d2b`), return nil so the caller can fall through to
    /// argv0 — many tools set argv0/`process.title` to the real command name.
    static func scriptBasename(_ token: String) -> String? {
        let ns = token as NSString
        let base = ns.lastPathComponent
        guard !base.isEmpty else { return nil }
        let lower = base.lowercased()
        var stripped = base
        for ext in [".js", ".mjs", ".cjs", ".ts", ".py"] where lower.hasSuffix(ext) {
            stripped = String(base.dropLast(ext.count))
            break
        }
        guard genericScriptNames.contains(stripped.lowercased()) else {
            return stripped
        }
        // …/pkg/dist/cli.js → pkg
        var dir = ns.deletingLastPathComponent
        let leaf = (dir as NSString).lastPathComponent.lowercased()
        if ["dist", "bin", "build", "lib", "src"].contains(leaf) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        let pkg = (dir as NSString).lastPathComponent
        if pkg.isEmpty || pkg == "node_modules" || pkg.hasPrefix("@") { return nil }
        // Version/build directories are not tool names — refuse so argv0 wins.
        if looksLikeVersionDir(pkg) { return nil }
        return pkg
    }

    /// True for directory names that are build ids / versions, not packages
    /// (`2026.07.23-e383d2b`, long hex hashes).
    static func looksLikeVersionDir(_ name: String) -> Bool {
        if name.count >= 7, name.allSatisfy(\.isHexDigit) { return true }
        if name.first?.isNumber == true,
           name.contains(where: { $0 == "." || $0 == "-" }) {
            return true
        }
        return false
    }

    // MARK: - Predicates

    static func isGenericRuntime(_ comm: String) -> Bool {
        let lower = comm.lowercased()
        return genericRuntimes.contains(lower) || lower.hasPrefix("python")
    }

    /// Dotted numeric names are likely launcher versions rather than useful
    /// process names (e.g. 2.1.303). Requiring two numeric components avoids
    /// treating ordinary names such as `3d-renderer` as versions.
    static func isVersionLikeName(_ name: String) -> Bool {
        let components = name.split(separator: ".")
        guard components.count >= 2 else { return false }
        return components.prefix(2).allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// A fully-populated `p_comm` means the real name was likely truncated.
    static func isTruncated(_ comm: String) -> Bool {
        comm.utf8.count >= Int(MAXCOMLEN) - 1
    }
}
