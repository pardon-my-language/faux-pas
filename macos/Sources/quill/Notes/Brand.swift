import Foundation

/// User-facing names. The Swift target and source folders keep Quill's names
/// so upstream changes keep merging cleanly; everything a person sees says
/// Pardon (D-174 in the pml decision log).
enum Brand {
    static let name = "Pardon"
    static let command = "pardon"
    static let bundleID = "com.joinpardon.meetings"

    /// Notification title, e.g. "Pardon: transcript ready".
    static func title(_ event: String) -> String {
        "\(name): \(event)"
    }
}
