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
    private let levelItems: [DarnSettings.Level: NSMenuItem]
    private let languageItems: [DarnSettings.NativeLanguage: NSMenuItem]

    /// One change the learner made in Darn's settings.
    enum SettingsChange {
        case feedback(Bool)
        case level(DarnSettings.Level)
        case nativeLanguage(DarnSettings.NativeLanguage)
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
            title: "Darn's feedback after meetings",
            action: #selector(feedbackClicked),
            keyEquivalent: ""
        )
        menu.addItem(feedbackItem)

        let levelMenu = NSMenu()
        var levels: [DarnSettings.Level: NSMenuItem] = [:]
        for level in DarnSettings.Level.allCases {
            let item = NSMenuItem(
                title: level.label, action: #selector(levelClicked(_:)), keyEquivalent: "")
            item.representedObject = level.rawValue
            levelMenu.addItem(item)
            levels[level] = item
        }
        levelItems = levels
        let levelParent = NSMenuItem(title: "Your English level", action: nil, keyEquivalent: "")
        levelParent.submenu = levelMenu
        menu.addItem(levelParent)

        let languageMenu = NSMenu()
        var languages: [DarnSettings.NativeLanguage: NSMenuItem] = [:]
        for language in DarnSettings.NativeLanguage.allCases {
            let item = NSMenuItem(
                title: language.label, action: #selector(languageClicked(_:)), keyEquivalent: "")
            item.representedObject = language.rawValue
            languageMenu.addItem(item)
            languages[language] = item
        }
        languageItems = languages
        let languageParent = NSMenuItem(title: "Your native language", action: nil, keyEquivalent: "")
        languageParent.submenu = languageMenu
        menu.addItem(languageParent)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit \(Brand.name)",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, openNotes, feedbackItem, quit]
            + Array(levels.values) + Array(languages.values)
        {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.pebbleImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect capture state in the icon tint and menu item titles. The menu
    /// bar shows only the pebble (red while healthy, orange while capture is
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
    func showSettings(_ settings: DarnSettings) {
        feedbackItem.state = settings.feedback ? .on : .off
        for (level, item) in levelItems {
            item.state = level == settings.level ? .on : .off
        }
        for (language, item) in languageItems {
            item.state = language == settings.nativeLanguage ? .on : .off
        }
    }

    // Darn's pebble with its apostrophe (pml designs/darn/logo-english.svg),
    // with the eyes and smile cut out so it works as a template image.
    // Inlined so the executable stays a single binary.
    private static let pebbleSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="34 14 132 168">\
        <circle cx="103" cy="30" r="11"/>\
        <path d="M92 30 C92 44 96 52 90 56 C104 54 114 44 114 30Z"/>\
        <path fill-rule="evenodd" d="M100 66 C134 66 160 90 160 124 C160 158 134 178 100 178 \
        C66 178 40 158 40 124 C40 90 66 66 100 66Z \
        M77 124 a6 8.5 0 1 0 12 0 a6 8.5 0 1 0 -12 0Z \
        M111 124 a6 8.5 0 1 0 12 0 a6 8.5 0 1 0 -12 0Z \
        M90 136 Q100 145 110 136 Q100 152 90 136Z"/>\
        </svg>
        """

    private static func pebbleImage() -> NSImage? {
        guard let data = pebbleSVG.data(using: .utf8),
            let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 14, height: 18)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func openLatestNotesClicked() { onOpenLatestNotes?() }
    @objc private func feedbackClicked() { onSettingsChange?(.feedback(feedbackItem.state != .on)) }

    @objc private func levelClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let level = DarnSettings.Level(rawValue: raw)
        else { return }
        onSettingsChange?(.level(level))
    }

    @objc private func languageClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let language = DarnSettings.NativeLanguage(rawValue: raw)
        else { return }
        onSettingsChange?(.nativeLanguage(language))
    }
}
