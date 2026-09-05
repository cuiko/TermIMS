import Foundation
import Darwin

/// Comparing directories by identity rather than by spelling.
///
/// The same directory reaches us under different names: a terminal reports the
/// shell's `$PWD`, which keeps whatever path the user typed, while the kernel
/// reports a process's working directory with symlinks already resolved. On
/// macOS `/tmp`, `/var` and `/etc` are symlinks into `/private`, and users
/// symlink their own project directories too — so a plain string comparison
/// decides two names for one directory are different places, finds no matching
/// surface, and the tab falls through to the default input source.
public enum CanonicalPath {
    /// Resolved, absolute form of `path`, suitable for equality comparison.
    /// Resolution is best-effort: a path that no longer exists is standardized
    /// but otherwise returned as given.
    public static func of(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        // realpath(3), not Foundation's resolvingSymlinksInPath: the latter
        // rewrites "/private/tmp" to "/tmp" — the opposite direction from the
        // kernel, which is the side we have to agree with.
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // The directory is gone. Standardize what we were given so at least
        // spelling differences like a trailing slash do not matter.
        return (path as NSString).standardizingPath
    }

    /// Convenience for optional paths, so call sites stay free of unwrapping.
    public static func of(_ path: String?) -> String? {
        path.map(of)
    }
}
