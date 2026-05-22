import Foundation

/// Single-line append-only log gated by `RuleStore.shared.debugLogEnabled`.
/// All log emission goes through `Log.debug(_:)` — call sites stay short
/// and unaware of file paths, timestamps, or the toggle.
enum Log {
    static let path: String = {
        let dir = NSHomeDirectory() + "/Library/Logs/TermIMS"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/termims.log"
    }()

    private static let formatter = ISO8601DateFormatter()
    private static var handle: FileHandle? = openHandle()

    private static func openHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fh = FileHandle(forWritingAtPath: path)
        fh?.seekToEndOfFile()
        return fh
    }

    static func debug(_ msg: @autoclosure () -> String) {
        guard RuleStore.shared.debugLogEnabled else { return }
        if handle == nil { handle = openHandle() }
        guard let fh = handle else { return }
        let line = "[\(formatter.string(from: Date()))] \(msg())\n"
        guard let data = line.data(using: .utf8) else { return }
        fh.write(data)
    }

    static func clear() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(atPath: path)
    }
}
