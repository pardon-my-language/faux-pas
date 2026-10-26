import Foundation

/// The learner's settings, stored under "darn" in the config file:
///
///     "darn": {
///       "feedback": true,
///       "level": "B1",
///       "native_language": "french",
///       "api_key": "sk-ant-..."
///     }
///
/// Feedback is off until the learner turns it on: only their own words ever
/// leave the Mac, and only by their choice.
struct DarnSettings: Equatable, Sendable {
    enum Level: String, CaseIterable, Sendable {
        case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2"

        var label: String {
            switch self {
            case .a1: "A1 (beginner)"
            case .a2: "A2 (elementary)"
            case .b1: "B1 (intermediate)"
            case .b2: "B2 (upper intermediate)"
            }
        }
    }

    enum NativeLanguage: String, CaseIterable, Sendable {
        case french, german, spanish, other

        var label: String { rawValue.capitalized }
    }

    var feedback = false
    var level = Level.b1
    var nativeLanguage = NativeLanguage.other
    var apiKey: String?

    init(feedback: Bool = false, level: Level = .b1, nativeLanguage: NativeLanguage = .other, apiKey: String? = nil) {
        self.feedback = feedback
        self.level = level
        self.nativeLanguage = nativeLanguage
        self.apiKey = apiKey
    }

    init(json: [String: Any]?) {
        let darn = json?["darn"] as? [String: Any] ?? [:]
        feedback = darn["feedback"] as? Bool ?? false
        level = (darn["level"] as? String).flatMap(Level.init(rawValue:)) ?? .b1
        nativeLanguage =
            (darn["native_language"] as? String).flatMap(NativeLanguage.init(rawValue:)) ?? .other
        let key = darn["api_key"] as? String
        apiKey = (key?.isEmpty ?? true) ? nil : key
    }

    /// Write these settings back into a config dictionary, leaving every
    /// other key (and the stored API key) as it was.
    func merged(into json: [String: Any]) -> [String: Any] {
        var out = json
        var darn = out["darn"] as? [String: Any] ?? [:]
        darn["feedback"] = feedback
        darn["level"] = level.rawValue
        darn["native_language"] = nativeLanguage.rawValue
        out["darn"] = darn
        return out
    }

    static func load() -> DarnSettings {
        DarnSettings(json: Config.loadJSON())
    }

    func save() throws {
        try Config.writeJSON(merged(into: Config.loadJSON() ?? [:]))
    }

    /// The config key wins; ANTHROPIC_API_KEY covers runs from a terminal.
    var resolvedAPIKey: String? {
        if let apiKey { return apiKey }
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        return (env?.isEmpty ?? true) ? nil : env
    }
}
