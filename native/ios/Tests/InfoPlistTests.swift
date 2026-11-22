import XCTest
@testable import WakeOn

/// App Store Connect rejects an upload whose code references a sensitive API without a purpose
/// string, even an API the app never calls (error 90683, Nov 22 2026: WebRTC references the camera).
final class InfoPlistTests: XCTestCase {
    func testPurposeStringsAppStoreConnectRequires() {
        for key in ["NSMicrophoneUsageDescription", "NSCameraUsageDescription"] {
            let text = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
            XCTAssertFalse(text.isEmpty, "\(key) is missing: App Store Connect rejects the build")
        }
    }

    func testAppIsCalledPixie() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Pixie")
    }
}
