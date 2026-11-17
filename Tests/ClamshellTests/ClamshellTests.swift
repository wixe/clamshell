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

    func testFunctionalPolicyTimedExpirationAndSafetyFloor() {
        let now = 1_795_000_000.0
        let expiredCfg = ClamshellConfig(
            mode: .timed,
            timedDurationMinutes: 60,
            timedExpiresAtEpoch: now - 30.0
        )
        let openTel = HardwareTelemetry(
            isClamshellClosed: false,
            currentBrightness: 0.75,
            displayOnline: true,
            displayResolution: "1680×1050",
            builtInSpeakersMuted: false,
            audioOutputDeviceName: "MacBook Pro Speakers",
            hidIdleSeconds: 2.0,
            isACConnected: true,
            isCharging: false,
            batteryPercent: 80,
            wattageW: 0.0,
            sleepDisabledKernel: true,
            screenLocked: false,
            thermalState: "Nominal"
        )

        let expiredStep = ClamshellPolicy.evaluate(
            config: expiredCfg,
            state: .initial,
            tracker: .initial,
            telemetry: openTel,
            brightnessReadable: true,
            nowEpoch: now
        )
        XCTAssertEqual(expiredStep.config.mode, .off)
        XCTAssertNil(expiredStep.config.timedExpiresAtEpoch)
        XCTAssertFalse(expiredStep.state.isAwakeAsserted)
        XCTAssertTrue(expiredStep.effects.contains {
            if case .saveConfig = $0 { return true }
            return false
        })
        XCTAssertEqual(
            ClamshellPolicy.menuBarTitle(isClamshellClosed: false, currentBrightness: 0.75, config: expiredCfg, nowEpoch: now),
            "🌙 Off"
        )

        // Battery safety floor pauses keep-awake when on battery at or below floor
        let lowBattTel = HardwareTelemetry(
            isClamshellClosed: false,
            currentBrightness: 0.5,
            displayOnline: true,
            displayResolution: "1680×1050",
            hidIdleSeconds: 0,
            isACConnected: false,
            isCharging: false,
            batteryPercent: 18,
            wattageW: -8.5,
            sleepDisabledKernel: true,
            screenLocked: false,
            thermalState: "Nominal"
        )
        let floorStep = ClamshellPolicy.evaluate(
            config: .default,
            state: .initial,
            tracker: .initial,
            telemetry: lowBattTel,
            brightnessReadable: true,
            nowEpoch: now
        )
        XCTAssertFalse(floorStep.state.isAwakeAsserted)
        XCTAssertTrue(floorStep.effects.contains(.setAwakeAssertions(systemAwake: false, displayAwake: false)))
    }

    func testFunctionalPolicyClosedLidNoSpamAndOpenRestore() {
        let now = 1_795_000_000.0
        let closedUnreadableTel = HardwareTelemetry(
            isClamshellClosed: true,
            currentBrightness: 0.0,
            displayOnline: false,
            displayResolution: "Headless/Virtual",
            builtInSpeakersMuted: false,
            hidIdleSeconds: 0,
            isACConnected: true,
            isCharging: false,
            batteryPercent: 55,
            wattageW: 0,
            sleepDisabledKernel: true,
            screenLocked: false,
            thermalState: "Nominal"
        )

        // First closed-lid tick drives 0% brightness and mutes speakers once
        let firstClosed = ClamshellPolicy.evaluate(
            config: .default,
            state: .initial,
            tracker: .initial,
            telemetry: closedUnreadableTel,
            brightnessReadable: false,
            nowEpoch: now
        )
        XCTAssertTrue(firstClosed.effects.contains(.setBrightness(0.0)))
        XCTAssertTrue(firstClosed.effects.contains(.setSpeakersMuted(true)))

        // Steady-state closed-lid tick with speakers already muted and unreadable display does NOT spam brightness or mute
        let steadyTel = HardwareTelemetry(
            isClamshellClosed: true,
            currentBrightness: 0.0,
            displayOnline: false,
            displayResolution: "Headless/Virtual",
            builtInSpeakersMuted: true,
            hidIdleSeconds: 0,
            isACConnected: true,
            isCharging: false,
            batteryPercent: 55,
            wattageW: 0,
            sleepDisabledKernel: true,
            screenLocked: false,
            thermalState: "Nominal"
        )
        let secondClosed = ClamshellPolicy.evaluate(
            config: firstClosed.config,
            state: firstClosed.state,
            tracker: firstClosed.tracker,
            telemetry: steadyTel,
            brightnessReadable: false,
            nowEpoch: now + 10
        )
        XCTAssertFalse(secondClosed.effects.contains {
            if case .setBrightness = $0 { return true }
            if case .setSpeakersMuted = $0 { return true }
            return false
        })

        // Opening lid restores saved brightness (0.65) and unmutes speakers
        let openedTel = HardwareTelemetry(
            isClamshellClosed: false,
            currentBrightness: 0.0,
            displayOnline: true,
            displayResolution: "1680×1050",
            builtInSpeakersMuted: true,
            hidIdleSeconds: 0,
            isACConnected: true,
            isCharging: false,
            batteryPercent: 55,
            wattageW: 0,
            sleepDisabledKernel: true,
            screenLocked: false,
            thermalState: "Nominal"
        )
        let openedStep = ClamshellPolicy.evaluate(
            config: secondClosed.config,
            state: secondClosed.state,
            tracker: secondClosed.tracker,
            telemetry: openedTel,
            brightnessReadable: true,
            nowEpoch: now + 12
        )
        XCTAssertTrue(openedStep.effects.contains(.setBrightness(0.65)))
        XCTAssertTrue(openedStep.effects.contains(.setSpeakersMuted(false)))
        XCTAssertFalse(openedStep.state.isSpeakerMutedByClamshell)
    }

    func testSocketIPCRoundTripAndMissingSocket() {
        let missingPath = "/tmp/cs-missing-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertFalse(UnixSocketClient.isSocketPresent(missingPath))
        XCTAssertNil(UnixSocketClient.send("STATUS", socketPath: missingPath))

        let sockPath = "/tmp/cs-ipc-\(UUID().uuidString.prefix(8)).sock"
        let gov = ClamshellGovernor(config: .default)
        let server = UnixSocketServer(socketPath: sockPath, governor: gov)
        server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertTrue(UnixSocketClient.isSocketPresent(sockPath))
        let statusResp = UnixSocketClient.send("STATUS", socketPath: sockPath)
        XCTAssertTrue(statusResp?.contains("\"governor\"") == true)
        XCTAssertFalse(UnixSocketClient.isSuccess(UnixSocketClient.send("FLOOR 99", socketPath: sockPath)))
        XCTAssertFalse(UnixSocketClient.isSuccess(UnixSocketClient.send("IDLE -5", socketPath: sockPath)))
    }
}
