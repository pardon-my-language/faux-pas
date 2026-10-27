import Foundation
import Sparkle

/// Pardon.app updates itself with Sparkle (faux-pas#3). It checks on its own
/// and asks before installing (D-221): Info.plist turns automatic checks on
/// and automatic installs off, so a restart never lands in the middle of a
/// meeting. The `pardon` command in a terminal has no updater.
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        guard AppBundle.isApp else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// False for the command, which has nothing to update.
    var available: Bool { controller != nil }

    /// "Check for updates..." in the menu.
    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    /// Pardon lives in the menu bar with no Dock icon, so Sparkle may show the
    /// update window on its own schedule instead of waiting for the app to be
    /// in front.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
