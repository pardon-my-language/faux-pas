import Foundation
import XCTest

@testable import quill

/// Pardon.app's Info.plist (faux-pas#3): what macOS reads to name the app in
/// permission prompts, keep it out of the Dock and find its icon.
final class PackagingTests: XCTestCase {
    private func plist(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packaging/\(name)")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheAppIsPardonWithNoDockIcon() throws {
        let info = try plist("Info.plist")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, Brand.bundleID)
        XCTAssertEqual(info["CFBundleName"] as? String, Brand.name)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, Brand.command)
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "15.0")
    }

    func testBothPermissionsAreExplainedInPardonsWords() throws {
        let info = try plist("Info.plist")
        for key in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription"] {
            let text = try XCTUnwrap(info[key] as? String, key)
            XCTAssertTrue(text.hasPrefix("Pardon "), key)
            XCTAssertTrue(text.contains("never leaves this Mac"), key)
            XCTAssertFalse(text.contains("\u{2014}"), "no long dashes")
        }
    }

    func testTheHardenedRuntimeMayUseTheMicrophone() throws {
        XCTAssertEqual(try plist("Pardon.entitlements")["com.apple.security.device.audio-input"] as? Bool, true)
    }

    func testTestsDoNotRunAsTheApp() {
        XCTAssertFalse(AppBundle.isApp)
    }
}
