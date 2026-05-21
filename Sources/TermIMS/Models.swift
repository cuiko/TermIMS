import Foundation

struct Rule: Codable {
    var enabled: Bool = true
    var appBundleID: String
    var appName: String
    var inputSourceID: String
    var inputSourceName: String
}

enum TerminalMatchType: String, Codable, CaseIterable {
    case process = "Process Name"
    case title   = "Tab Title"
}

struct TerminalRule: Codable {
    var enabled: Bool = true
    var matchType: TerminalMatchType = .title
    var pattern: String = ""
    var inputSourceID: String
    var inputSourceName: String
    /// Free-form annotation shown in the rule table. Purely cosmetic — not
    /// used by the matcher. `decodeIfPresent` lets older stored rules (saved
    /// before this field existed) round-trip cleanly with an empty note.
    var note: String = ""

    init(enabled: Bool = true,
         matchType: TerminalMatchType = .title,
         pattern: String = "",
         inputSourceID: String,
         inputSourceName: String,
         note: String = "") {
        self.enabled = enabled
        self.matchType = matchType
        self.pattern = pattern
        self.inputSourceID = inputSourceID
        self.inputSourceName = inputSourceName
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matchType = try c.decodeIfPresent(TerminalMatchType.self, forKey: .matchType) ?? .title
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        inputSourceID = try c.decode(String.self, forKey: .inputSourceID)
        inputSourceName = try c.decode(String.self, forKey: .inputSourceName)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

enum IndicatorPosition: String, Codable, CaseIterable {
    case screenCenter  = "Screen Center"
    case centerBottom  = "Center Bottom"
    case topLeft       = "Top Left"
    case topRight      = "Top Right"
    case bottomLeft    = "Bottom Left"
    case bottomRight   = "Bottom Right"
}

extension Notification.Name {
    static let rulesDidChange = Notification.Name("RulesDidChange")
    static let imDidSwitch    = Notification.Name("IMDidSwitch")
}
