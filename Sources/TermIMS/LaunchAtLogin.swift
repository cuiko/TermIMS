import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp` (macOS 13+). Registering the
/// app bundle this way makes it appear in System Settings → General → Login
/// Items under "Open at Login" with the real app icon and name — unlike the
/// legacy LaunchAgent plist, which lands in "Allow in the Background" as a
/// raw `exec` entry from an "unidentified developer".
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        // Drop any agent left by older plist-based builds so the user isn't
        // launched twice (once by the stale agent, once by SMAppService).
        removeLegacyAgent()
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.debug("LaunchAtLogin set(\(enabled)) failed: \(error)")
        }
    }

    private static func removeLegacyAgent() {
        let path = NSHomeDirectory() + "/Library/LaunchAgents/top.cuiko.termims.plist"
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
