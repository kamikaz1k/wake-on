import AVFoundation
import XCTest
@testable import WakeOn

final class ListenerSettingsTests: XCTestCase {
    func testDefaultsShareAudioAndKeepHeadphonesInHighQuality() {
        let options = ListenerSettings().categoryOptions
        XCTAssertTrue(options.contains(.mixWithOthers))
        XCTAssertTrue(options.contains(.allowBluetoothA2DP))
        XCTAssertFalse(options.contains(.allowBluetoothHFP))
        XCTAssertTrue(options.contains(.defaultToSpeaker))
    }

    func testTurningOptionsOffRestoresThePreviousBehaviour() {
        let options = ListenerSettings(shareAudio: false, autoResume: false, builtInMicrophone: false).categoryOptions
        XCTAssertFalse(options.contains(.mixWithOthers))
        XCTAssertTrue(options.contains(.allowBluetoothHFP))
    }

    func testModeIsDefaultOnlyWhenSharingWithFullSound() {
        XCTAssertEqual(ListenerSettings().mode, .default)
        XCTAssertEqual(ListenerSettings(fullSoundForOthers: false).mode, .measurement)
        XCTAssertEqual(ListenerSettings(shareAudio: false).mode, .measurement)
    }

    func testMigrationResetsEarlierChoicesOnceThenKeepsNewOnes() {
        let defaults = UserDefaults(suiteName: "ListenerSettingsTests.migration")!
        defaults.removePersistentDomain(forName: "ListenerSettingsTests.migration")
        defaults.set(false, forKey: ListenerSettings.Key.shareAudio)   // saved by a test build
        ListenerSettings.migrate(defaults)
        XCTAssertNil(defaults.object(forKey: ListenerSettings.Key.shareAudio))
        defaults.set(false, forKey: ListenerSettings.Key.shareAudio)   // the user's new choice
        ListenerSettings.migrate(defaults)
        XCTAssertEqual(defaults.object(forKey: ListenerSettings.Key.shareAudio) as? Bool, false)
    }

    func testUnsetDefaultsReadAsOn() {
        let defaults = UserDefaults.standard
        let keys = [ListenerSettings.Key.shareAudio, ListenerSettings.Key.autoResume, ListenerSettings.Key.builtInMicrophone,
                    ListenerSettings.Key.fullSoundForOthers]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        XCTAssertEqual(ListenerSettings.current, ListenerSettings())
    }
}
