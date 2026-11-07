import UIKit
import XCTest
@testable import WakeOn

final class ScreenAwakeTests: XCTestCase {
    func testOnlyWhileChargingOrFull() {
        XCTAssertTrue(ScreenAwake.keepsScreenOn(enabled: true, battery: .charging))
        XCTAssertTrue(ScreenAwake.keepsScreenOn(enabled: true, battery: .full))
        XCTAssertFalse(ScreenAwake.keepsScreenOn(enabled: true, battery: .unplugged))
        XCTAssertFalse(ScreenAwake.keepsScreenOn(enabled: true, battery: .unknown))
        XCTAssertFalse(ScreenAwake.keepsScreenOn(enabled: false, battery: .charging))
    }
}
