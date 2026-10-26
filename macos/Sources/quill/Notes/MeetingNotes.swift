import Foundation

/// Pardon's notes on one meeting. Property names are the JSON schema the
/// model fills (structured output) and the shape of notes.json.
struct MeetingNotes: Codable, Equatable, Sendable {
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

    /// The readable notes, notes.md, with headings in the learner's native
    /// language (D-176). Model text passes through `clean` so house style
    /// holds even when the model slips.
    func rendered(title: String, settings: LearnerSettings) -> String {
        let words = Labels.for(settings.explanationLanguage)
        // The habit tag names the learner's native language, which is also
        // the language the notes are written in; Other gets no tag.
        let habit = settings.nativeLanguage.map { Labels.for($0).habit }
        var lines = ["# \(words.title): \(title)", "", Self.clean(greeting), ""]

        if !went_well.isEmpty {
            lines += ["## \(words.wentWell)", ""]
            lines += went_well.map { "- \(Self.clean($0))" }
            lines.append("")
        }
        if !mistakes.isEmpty {
            lines += ["## \(words.worthFixing)", ""]
            for (i, m) in mistakes.enumerated() {
                lines.append("\(i + 1). \(words.youSaid) \"\(Self.clean(m.said))\"")
                lines.append("   \(words.tryThis) \"\(Self.clean(m.better))\"")
                var why = "   \(words.why) \(Self.clean(m.reason))"
                if m.native_language_habit, let habit { why += " (\(habit))" }
                lines.append(why)
                lines.append("")
            }
        }
        if !patterns.isEmpty {
            lines += ["## \(words.patterns)", ""]
            for p in patterns {
                var line =
                    "- \(Self.sentence(p.pattern)) \(words.forExample) \"\(Self.clean(p.example))\""
                if p.native_language_habit, let habit { line += " (\(habit))" }
                lines.append(line)
            }
            lines.append("")
        }
        lines += ["## \(words.practice)", "", Self.clean(practice), ""]
        return lines.joined(separator: "\n")
    }

    /// A cleaned line that ends like a sentence, so the text after it
    /// ("For example: ...") never runs on from it.
    static func sentence(_ text: String) -> String {
        let cleaned = clean(text)
        guard let last = cleaned.last, !".!?:".contains(last) else { return cleaned }
        return cleaned + "."
    }

    /// No long dashes and no emojis, anywhere Pardon writes.
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

    /// The fixed words around the model's text, in each explanation
    /// language. Informal register (tu, du, tú), as everywhere Pardon talks
    /// to learners.
    struct Labels: Equatable {
        let title: String
        let wentWell: String
        let worthFixing: String
        let youSaid: String
        let tryThis: String
        let why: String
        let patterns: String
        let forExample: String
        let practice: String
        /// "A habit many <native language> speakers have."
        let habit: String

        static func `for`(_ language: Language) -> Labels {
            switch language {
            case .english:
                Labels(
                    title: "Pardon's notes", wentWell: "What went well", worthFixing: "Worth fixing",
                    youSaid: "You said:", tryThis: "Try:", why: "Why:", patterns: "Patterns",
                    forExample: "For example:", practice: "Practice before your next meeting",
                    habit: "A habit many English speakers have.")
            case .french:
                Labels(
                    title: "Les notes de Pardon", wentWell: "Ce qui a bien marché",
                    worthFixing: "À corriger", youSaid: "Tu as dit :", tryThis: "Essaie :",
                    why: "Pourquoi :", patterns: "Ce qui revient souvent", forExample: "Par exemple :",
                    practice: "À pratiquer avant ta prochaine réunion",
                    habit: "Une habitude fréquente chez les francophones.")
            case .german:
                Labels(
                    title: "Notizen von Pardon", wentWell: "Was gut lief", worthFixing: "Zum Verbessern",
                    youSaid: "Du hast gesagt:", tryThis: "Besser:", why: "Warum:",
                    patterns: "Was öfter vorkam", forExample: "Zum Beispiel:",
                    practice: "Zum Üben vor deinem nächsten Meeting",
                    habit: "Typisch, wenn Deutsch die Muttersprache ist.")
            case .spanish:
                Labels(
                    title: "Notas de Pardon", wentWell: "Lo que salió bien", worthFixing: "Para corregir",
                    youSaid: "Dijiste:", tryThis: "Prueba:", why: "Por qué:",
                    patterns: "Lo que se repite", forExample: "Por ejemplo:",
                    practice: "Para practicar antes de tu próxima reunión",
                    habit: "Un hábito común entre hispanohablantes.")
            }
        }
    }
}
