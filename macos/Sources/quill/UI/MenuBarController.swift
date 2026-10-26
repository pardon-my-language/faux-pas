import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    /// What the menu communicates about capture. Recovering and degraded are
    /// distinct from healthy recording so a user glancing mid-meeting can see
    /// that something happened; elapsed time stays visible in every recording
    /// state.
    enum Display: Equatable {
        case idle
        case recording(elapsed: String)
        case recovering(track: String, elapsed: String)
        case degraded(track: String, elapsed: String)
    }

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let warningLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let feedbackItem: NSMenuItem
    private let meetingItems: [Language: NSMenuItem]
    private let levelParent: NSMenuItem
    private let levelItems: [LearnerSettings.Level: NSMenuItem]
    /// Keyed by Language raw value, plus "other".
    private let nativeItems: [String: NSMenuItem]

    /// One change the learner made in the notes settings.
    enum SettingsChange {
        case feedback(Bool)
        case meetingLanguage(Language)
        /// The level in the meeting's current language.
        case level(LearnerSettings.Level)
        /// nil is Other.
        case nativeLanguage(Language?)
    }

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenLatestNotes: (() -> Void)?
    var onSettingsChange: ((SettingsChange) -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        warningLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningLabel.isEnabled = false
        warningLabel.isHidden = true
        menu.addItem(warningLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        let openNotes = NSMenuItem(
            title: "Open latest notes",
            action: #selector(openLatestNotesClicked),
            keyEquivalent: "n"
        )
        menu.addItem(openNotes)

        menu.addItem(.separator())

        feedbackItem = NSMenuItem(
            title: "Notes after meetings",
            action: #selector(feedbackClicked),
            keyEquivalent: ""
        )
        menu.addItem(feedbackItem)

        func submenu(_ title: String, _ items: [(String, String, Selector)]) -> (NSMenuItem, [String: NSMenuItem]) {
            let sub = NSMenu()
            var byKey: [String: NSMenuItem] = [:]
            for (key, label, action) in items {
                let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
                item.representedObject = key
                sub.addItem(item)
                byKey[key] = item
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
            return (parent, byKey)
        }

        let (_, meeting) = submenu(
            "This meeting is in",
            Language.allCases.map { ($0.rawValue, $0.label, #selector(meetingClicked(_:))) })
        meetingItems = Dictionary(uniqueKeysWithValues: Language.allCases.map { ($0, meeting[$0.rawValue]!) })

        let (levelParent, level) = submenu(
            "Your level",
            LearnerSettings.Level.allCases.map { ($0.rawValue, $0.label, #selector(levelClicked(_:))) })
        self.levelParent = levelParent
        levelItems = Dictionary(
            uniqueKeysWithValues: LearnerSettings.Level.allCases.map { ($0, level[$0.rawValue]!) })

        let (_, native) = submenu(
            "Your native language",
            Language.allCases.map { ($0.rawValue, $0.label, #selector(nativeClicked(_:))) }
                + [("other", "Other", #selector(nativeClicked(_:)))])
        nativeItems = native

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit \(Brand.name)",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, openNotes, feedbackItem, quit]
            + Array(meeting.values) + Array(level.values) + Array(native.values)
        {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.asteriskImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect capture state in the icon tint and menu item titles. The menu
    /// bar shows only the asterisk (red while healthy, orange while capture is
    /// recovering or lost); the elapsed counter lives in the menu's state
    /// label. Call once a second while recording and on every status change.
    /// `signalWarning` is a secondary diagnostic (exact digital silence on a
    /// track that is still delivering callbacks) — its own line, never the
    /// same visual state as stopped callbacks.
    func update(_ display: Display, signalWarning: Bool = false) {
        switch display {
        case .idle:
            stateLabel.title = "idle"
            toggleItem.title = "Start recording"
            statusItem.button?.contentTintColor = nil
        case .recording(let elapsed):
            stateLabel.title = "● recording · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemRed
        case .recovering(let track, let elapsed):
            stateLabel.title = "◐ recovering \(track) · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemOrange
        case .degraded(let track, let elapsed):
            stateLabel.title = "⚠ \(track) capture lost · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemOrange
        }
        let warn = signalWarning && display != .idle
        warningLabel.title = warn ? "△ system audio silent" : ""
        warningLabel.isHidden = !warn
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Tick the current settings. Called at launch and after every change.
    func showSettings(_ settings: LearnerSettings) {
        feedbackItem.state = settings.feedback ? .on : .off
        for (language, item) in meetingItems {
            item.state = language == settings.meetingLanguage ? .on : .off
        }
        levelParent.title = "Your level in \(settings.meetingLanguage.label)"
        for (level, item) in levelItems {
            item.state = level == settings.level ? .on : .off
        }
        let native = settings.nativeLanguage?.rawValue ?? "other"
        for (key, item) in nativeItems {
            item.state = key == native ? .on : .off
        }
    }

    /// The Pardon brush asterisk (pml public/asterisk-mark.svg), drawn as a
    /// template image so macOS tints it for light and dark menu bars.
    private static func asteriskImage() -> NSImage? {
        guard let data = PardonMark.svg.data(using: .utf8),
            let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 17, height: 17)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func openLatestNotesClicked() { onOpenLatestNotes?() }
    @objc private func feedbackClicked() { onSettingsChange?(.feedback(feedbackItem.state != .on)) }

    @objc private func meetingClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let language = Language(rawValue: raw)
        else { return }
        onSettingsChange?(.meetingLanguage(language))
    }

    @objc private func levelClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let level = LearnerSettings.Level(rawValue: raw)
        else { return }
        onSettingsChange?(.level(level))
    }

    @objc private func nativeClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        onSettingsChange?(.nativeLanguage(Language(rawValue: raw)))
    }
}
