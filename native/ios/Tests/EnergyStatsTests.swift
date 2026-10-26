import XCTest
@testable import WakeOn

final class EnergyStatsTests: XCTestCase {
    private func sample(_ seconds: Double, energyJ: Double, cpuS: Double, battery: Float,
                        charging: Bool = false, background: Bool = true, wakeups: UInt64 = 0) -> EnergySample {
        EnergySample(date: Date(timeIntervalSince1970: seconds), uptime: seconds, batteryLevel: battery,
                     charging: charging, lowPowerMode: false, thermalState: 0, inBackground: background,
                     energyNanojoules: UInt64(energyJ * 1e9), cpuNanoseconds: UInt64(cpuS * 1e9), wakeups: wakeups)
    }

    func testAverageAndBackgroundPowerCpuAndWakeups() {
        // 10 min foreground at 200 mW, then 50 min background at 20 mW.
        let samples = [
            sample(0, energyJ: 0, cpuS: 0, battery: 0.80, background: false, wakeups: 0),
            sample(600, energyJ: 120, cpuS: 30, battery: 0.79, background: false, wakeups: 6_000),
            sample(600, energyJ: 120, cpuS: 30, battery: 0.79, background: true, wakeups: 6_000),
            sample(3_600, energyJ: 180, cpuS: 60, battery: 0.76, background: true, wakeups: 36_000),
        ]
        let stats = EnergyStats(samples: samples)
        XCTAssertEqual(stats.seconds, 3_600)
        XCTAssertEqual(stats.joules, 180, accuracy: 1e-6)
        XCTAssertEqual(stats.averageMilliwatts!, 50, accuracy: 1e-6)
        XCTAssertEqual(stats.backgroundMilliwatts!, 20, accuracy: 1e-6)
        XCTAssertEqual(stats.backgroundSeconds, 3_000, accuracy: 1e-6)
        XCTAssertEqual(stats.cpuPercent!, 60.0 / 3_600 * 100, accuracy: 1e-6)
        XCTAssertEqual(stats.wakeupsPerSecond!, 10, accuracy: 1e-6)
        XCTAssertEqual(stats.batteryDrop!, 4, accuracy: 1e-3)
        XCTAssertEqual(stats.batteryDropPerHour!, 4, accuracy: 1e-3)
        XCTAssertEqual(stats.milliwattHours, 50, accuracy: 1e-6)
    }

    func testChargingTimeIsExcludedFromBatteryDrop() {
        let samples = [
            sample(0, energyJ: 0, cpuS: 0, battery: 0.50),
            sample(1_800, energyJ: 36, cpuS: 9, battery: 0.48),
            sample(3_600, energyJ: 72, cpuS: 18, battery: 0.60, charging: true),
        ]
        let stats = EnergyStats(samples: samples)
        XCTAssertEqual(stats.unpluggedSeconds, 1_800, accuracy: 1e-6)
        XCTAssertEqual(stats.batteryDrop!, 2, accuracy: 1e-3)
        XCTAssertEqual(stats.batteryDropPerHour!, 4, accuracy: 1e-3)
    }

    func testFewerThanTwoSamplesGiveNoRates() {
        let stats = EnergyStats(samples: [sample(0, energyJ: 0, cpuS: 0, battery: 0.5)])
        XCTAssertNil(stats.averageMilliwatts)
        XCTAssertNil(stats.batteryDropPerHour)
    }
}
