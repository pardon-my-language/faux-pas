import Foundation

/// Darn's notes on one meeting. Property names are the JSON schema the model
/// fills (structured output) and the shape of darn.json.
struct DarnSummary: Codable, Equatable, Sendable {
    struct Mistake: Codable, Equatable, Sendable {
        let said: String
        let better: String
        let reason: String
        let native_language_habit: Bool
    }

    struct Pattern: Codable, Equatable, Sendable {
        let pattern: String
        let example: String
        let native_language_habit: Bool
    }

    let greeting: String
    let went_well: [String]
    let mistakes: [Mistake]
    let patterns: [Pattern]
    let practice: String

    static var schema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            [
                "type": "object",
                "additionalProperties": false,
                "required": properties.keys.sorted(),
                "properties": properties,
            ]
        }
        let text: [String: Any] = ["type": "string"]
        let flag: [String: Any] = ["type": "boolean"]
        return object([
            "greeting": text,
            "went_well": ["type": "array", "items": text],
            "mistakes": [
                "type": "array",
                "items": object([
                    "said": text, "better": text, "reason": text, "native_language_habit": flag,
                ]),
            ],
            "patterns": [
                "type": "array",
                "items": object(["pattern": text, "example": text, "native_language_habit": flag]),
            ],
            "practice": text,
        ])
    }

    /// The readable summary, darn.md. Model text passes through `clean` so
    /// house style holds even when the model slips.
    func rendered(title: String, settings: DarnSettings) -> String {
        let habit =
            settings.nativeLanguage == .other
            ? nil : "A habit many \(settings.nativeLanguage.label) speakers have."
        var lines = ["# Darn's notes: \(title)", "", Self.clean(greeting), ""]

        if !went_well.isEmpty {
            lines += ["## What went well", ""]
            lines += went_well.map { "- \(Self.clean($0))" }
            lines.append("")
        }
        if !mistakes.isEmpty {
            lines += ["## Worth fixing", ""]
            for (i, m) in mistakes.enumerated() {
                lines.append("\(i + 1). You said: \"\(Self.clean(m.said))\"")
                lines.append("   Try: \"\(Self.clean(m.better))\"")
                var why = "   Why: \(Self.clean(m.reason))"
                if m.native_language_habit, let habit { why += " (\(habit))" }
                lines.append(why)
                lines.append("")
            }
        }
        if !patterns.isEmpty {
            lines += ["## Patterns", ""]
            for p in patterns {
                var line = "- \(Self.sentence(p.pattern)) For example: \"\(Self.clean(p.example))\""
                if p.native_language_habit, let habit { line += " (\(habit))" }
                lines.append(line)
            }
            lines.append("")
        }
        lines += ["## Practice before your next meeting", "", Self.clean(practice), ""]
        return lines.joined(separator: "\n")
    }

    /// A cleaned line that ends like a sentence, so the text after it
    /// ("For example: ...") never runs on from it.
    static func sentence(_ text: String) -> String {
        let cleaned = clean(text)
        guard let last = cleaned.last, !".!?:".contains(last) else { return cleaned }
        return cleaned + "."
    }

    /// No long dashes and no emojis, anywhere Darn writes.
    static func clean(_ text: String) -> String {
        let dashed =
            text
            .replacingOccurrences(of: " \u{2014} ", with: ", ")
            .replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: " \u{2013} ", with: ", ")
        let scalars = dashed.unicodeScalars.filter {
            !($0.properties.isEmojiPresentation || $0.value == 0xFE0F
                || ($0.properties.isEmoji && $0.value > 0x2000))
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
