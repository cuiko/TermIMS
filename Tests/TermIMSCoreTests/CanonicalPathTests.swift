import Testing
import Foundation
@testable import TermIMSCore

@Suite("Canonical path")
struct CanonicalPathTests {

    /// macOS ships these as symlinks into /private. A terminal reporting
    /// `/tmp/x` and the kernel reporting `/private/tmp/x` mean one directory,
    /// and comparing the spellings decides otherwise.
    @Test("system symlinks resolve the way the kernel reports them",
          arguments: ["/tmp", "/var", "/etc"])
    func systemSymlinks(path: String) {
        #expect(CanonicalPath.of(path) == "/private" + path)
    }

    @Test("both spellings of one directory compare equal")
    func bothSpellingsAgree() throws {
        let dir = "/tmp/termims-canonical-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(CanonicalPath.of(dir) == CanonicalPath.of("/private" + dir))
    }

    @Test("an already-resolved path is unchanged")
    func resolvedPathUnchanged() {
        let home = NSHomeDirectory()
        #expect(CanonicalPath.of(home) == home)
    }

    @Test("a trailing slash does not change identity")
    func trailingSlash() {
        #expect(CanonicalPath.of("/private/tmp/") == CanonicalPath.of("/private/tmp"))
    }

    /// A directory can vanish between being reported and being resolved; the
    /// path still has to compare sanely rather than becoming empty.
    @Test("a path that no longer exists is still usable")
    func missingPath() {
        let p = "/private/tmp/termims-gone-\(UUID().uuidString)"
        #expect(CanonicalPath.of(p) == p)
    }

    @Test("optional paths pass through")
    func optionalPassthrough() {
        #expect(CanonicalPath.of(String?.none) == nil)
        #expect(CanonicalPath.of("/tmp" as String?) == "/private/tmp")
    }
}
