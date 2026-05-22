import Foundation

class RuleStore {
    static let shared = RuleStore()
    private let ud = UserDefaults.standard

    private func notify() {
        NotificationCenter.default.post(name: .rulesDidChange, object: nil)
    }

    var rules: [Rule] {
        get { decode("TermIMSRules") ?? [] }
        set { encode(newValue, "TermIMSRules"); notify() }
    }

    var defaultSourceID: String? {
        get { ud.string(forKey: "DefaultSourceID") }
        set { ud.set(newValue, forKey: "DefaultSourceID"); notify() }
    }
    var defaultSourceName: String? {
        get { ud.string(forKey: "DefaultSourceName") }
        set { ud.set(newValue, forKey: "DefaultSourceName") }
    }

    var indicatorEnabled: Bool {
        get { ud.object(forKey: "IndicatorEnabled") as? Bool ?? true }
        set { ud.set(newValue, forKey: "IndicatorEnabled") }
    }
    var indicatorPosition: IndicatorPosition {
        get { IndicatorPosition(rawValue: ud.string(forKey: "IndicatorPosition") ?? "") ?? .centerBottom }
        set { ud.set(newValue.rawValue, forKey: "IndicatorPosition") }
    }

    var hideMenuBarIcon: Bool {
        get { ud.bool(forKey: "HideMenuBarIcon") }
        set { ud.set(newValue, forKey: "HideMenuBarIcon"); notify() }
    }

    var debugLogEnabled: Bool {
        get { ud.bool(forKey: "DebugLogEnabled") }
        set { ud.set(newValue, forKey: "DebugLogEnabled") }
    }

    var terminalRules: [TerminalRule] {
        get { decode("TermIMSTerminalRules") ?? [] }
        set { encode(newValue, "TermIMSTerminalRules"); notify() }
    }

    var terminalDefaultSourceID: String? {
        get { ud.string(forKey: "TerminalDefaultSourceID") }
        set { ud.set(newValue, forKey: "TerminalDefaultSourceID"); notify() }
    }
    var terminalDefaultSourceName: String? {
        get { ud.string(forKey: "TerminalDefaultSourceName") }
        set { ud.set(newValue, forKey: "TerminalDefaultSourceName") }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = ud.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func encode<T: Encodable>(_ val: T, _ key: String) {
        ud.set(try? JSONEncoder().encode(val), forKey: key)
    }
}
