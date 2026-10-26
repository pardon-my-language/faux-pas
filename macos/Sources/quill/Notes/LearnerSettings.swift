import Foundation

/// The four languages Pardon teaches, and so the four a meeting can be in
/// (D-175).
enum Language: String, CaseIterable, Sendable {
    case english, french, german, spanish

    var label: String { rawValue.capitalized }
}

/// The learner's settings, stored under "notes" in the config file:
///
///     "notes": {
///       "feedback": true,
///       "meeting_language": "french",
///       "levels": { "french": "B1", "german": "A2" },
///       "native_language": "english",
///       "api_key": "sk-ant-..."
///     }
///
/// Notes are off until the learner turns them on: only their own words ever
/// leave the Mac, and only by their choice.
struct LearnerSettings: Equatable, Sendable {
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

    static let defaultLevel = Level.b1

    var feedback = false
    var meetingLanguage = Language.english
    var levels: [Language: Level] = [:]
    /// nil when the learner picked Other.
    var nativeLanguage: Language?
    var apiKey: String?

    init(
        feedback: Bool = false, meetingLanguage: Language = .english,
        levels: [Language: Level] = [:], nativeLanguage: Language? = nil, apiKey: String? = nil
    ) {
        self.feedback = feedback
        self.meetingLanguage = meetingLanguage
        self.levels = levels
        self.nativeLanguage = nativeLanguage
        self.apiKey = apiKey
    }

    init(json: [String: Any]?) {
        // Builds before D-174 kept these under "darn"; carry them over.
        let notes = json?["notes"] as? [String: Any] ?? json?["darn"] as? [String: Any] ?? [:]
        feedback = notes["feedback"] as? Bool ?? false
        meetingLanguage =
            (notes["meeting_language"] as? String).flatMap(Language.init(rawValue:)) ?? .english
        for (name, value) in notes["levels"] as? [String: String] ?? [:] {
            if let language = Language(rawValue: name), let level = Level(rawValue: value) {
                levels[language] = level
            }
        }
        nativeLanguage = (notes["native_language"] as? String).flatMap(Language.init(rawValue:))
        let key = notes["api_key"] as? String
        apiKey = (key?.isEmpty ?? true) ? nil : key
    }

    /// The learner's level in the language of this meeting.
    var level: Level { level(in: meetingLanguage) }

    func level(in language: Language) -> Level { levels[language] ?? Self.defaultLevel }

    /// Explanations follow the learner's native language, English for Other
    /// (D-176). Corrections always stay in the meeting's language.
    var explanationLanguage: Language { nativeLanguage ?? .english }

    /// No notes for a meeting held in the learner's own language.
    var meetingIsInNativeLanguage: Bool { nativeLanguage == meetingLanguage }

    /// Write these settings back into a config dictionary, leaving every
    /// other key (and the stored API key) as it was.
    func merged(into json: [String: Any]) -> [String: Any] {
        var out = json
        var notes = out["notes"] as? [String: Any] ?? out["darn"] as? [String: Any] ?? [:]
        notes.removeValue(forKey: "level")
        notes["feedback"] = feedback
        notes["meeting_language"] = meetingLanguage.rawValue
        notes["levels"] = Dictionary(
            uniqueKeysWithValues: levels.map { ($0.key.rawValue, $0.value.rawValue) })
        notes["native_language"] = nativeLanguage?.rawValue ?? "other"
        out["notes"] = notes
        out.removeValue(forKey: "darn")
        return out
    }

    static func load() -> LearnerSettings {
        LearnerSettings(json: Config.loadJSON())
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
