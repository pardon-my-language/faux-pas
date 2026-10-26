import Foundation
import ServiceManagement

/// Running as Pardon.app (faux-pas#3), opened from Finder or at login, rather
/// than as the `pardon` command in a terminal.
enum AppBundle {
    static var isApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Open at login the way a Mac app does: listed under Login Items in
    /// System Settings, where the learner can turn it off. Only the app does
    /// this; the command keeps `pardon install --launch-at-login`.
    static func openAtLogin() {
        guard isApp, SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            FileHandle.standardError.write(Data("open at login not set: \(error)\n".utf8))
        }
    }
}
