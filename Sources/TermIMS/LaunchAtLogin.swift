import Foundation

/// Launch-at-login backed by a LaunchAgent plist in ~/Library/LaunchAgents.
/// The plist's presence is the source of truth for the enabled state, so the
/// status-menu toggle and the Settings checkbox always agree without any
/// stored flag of their own.
enum LaunchAtLogin {
    private static let label = "top.cuiko.termims"

    private static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func setEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            try? fm.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                    withIntermediateDirectories: true)
            let plist: NSDictionary = [
                "Label": label,
                "ProgramArguments": [Bundle.main.executablePath ?? ""],
                "RunAtLoad": true,
            ]
            plist.write(toFile: plistPath, atomically: true)
        } else {
            try? fm.removeItem(atPath: plistPath)
        }
    }
}
