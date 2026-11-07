import XCTest
@testable import ClamshellCore

final class ClamshellTests: XCTestCase {
    func testDefaultConfigValues() {
        let cfg = ClamshellConfig.default
        XCTAssertEqual(cfg.mode, .indefinite)
        XCTAssertTrue(cfg.clamshellBlackoutEnabled)
        XCTAssertEqual(cfg.idleDimSeconds, 300)
        XCTAssertEqual(cfg.savedBrightness, 0.65, accuracy: 0.001)
        XCTAssertEqual(cfg.batteryFloorPercent, 20)
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("0.2.0", newerThan: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.1.0", newerThan: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.0.9", newerThan: "0.1.0"))
    }

    func testHardwareTelemetryRead() {
        let monitor = HardwareMonitor()
        let tel = monitor.readTelemetry()
        XCTAssertGreaterThanOrEqual(tel.currentBrightness, 0.0)
        XCTAssertLessThanOrEqual(tel.currentBrightness, 1.0)
        XCTAssertGreaterThanOrEqual(tel.batteryPercent, 0)
        XCTAssertLessThanOrEqual(tel.batteryPercent, 100)
    }

    func testLayoutPathsAreLowercaseForCommandsAndDaemon() {
        XCTAssertEqual(ClamshellLayout.cliBinary, "/usr/local/bin/clamshell")
        XCTAssertEqual(ClamshellLayout.supportDirectory, "/Library/Application Support/clamshell")
        XCTAssertEqual(ClamshellLayout.daemonBinary, "/Library/Application Support/clamshell/clamshelld")
        XCTAssertEqual(ClamshellLayout.appBundle, "/Applications/Clamshell.app")
    }
}
