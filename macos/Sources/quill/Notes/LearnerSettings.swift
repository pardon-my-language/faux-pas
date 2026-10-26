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
///       "native_language": "english"
///     }
///
/// Notes are off until the learner turns them on: only their own words ever
/// leave the Mac, and only by their choice. They are written by Pardon's
/// server on the learner's account (D-181), so there is no key to set.
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

    init(
        feedback: Bool = false, meetingLanguage: Language = .english,
        levels: [Language: Level] = [:], nativeLanguage: Language? = nil
    ) {
        self.feedback = feedback
        self.meetingLanguage = meetingLanguage
        self.levels = levels
        self.nativeLanguage = nativeLanguage
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
    /// other key as it was. A Claude API key from builds before #7 is
    /// dropped: notes come from Pardon's server now.
    func merged(into json: [String: Any]) -> [String: Any] {
        var out = json
        var notes = out["notes"] as? [String: Any] ?? out["darn"] as? [String: Any] ?? [:]
        notes.removeValue(forKey: "level")
        notes.removeValue(forKey: "api_key")
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
}
