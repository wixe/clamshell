import Foundation

public final class ClamshellGovernor {
    public private(set) var config: ClamshellConfig
    public private(set) var state: GovernorState = .initial
    private let monitor = HardwareMonitor()
    private let power = PowerAssertionController()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.github.wixe.clamshell.governor", qos: .utility)

    private var wasClamshellClosed: Bool? = nil
    private var wasIdleBlackedOut: Bool = false
    private var manualBlackoutActive: Bool = false

    public init(config: ClamshellConfig) {
        self.config = config
    }

    public func start() {
        evaluateTick()

        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(1.0, config.pollIntervalSeconds)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.evaluateTick()
        }
        t.resume()
        self.timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        let tel = monitor.readTelemetry()
        power.releaseAll()
        power.setKernelClamshellSleepDisabled(false, currentKernelState: tel.sleepDisabledKernel)
        if state.isBacklightBlackedOut && !tel.isClamshellClosed {
            _ = DisplayBacklightController.shared.setBrightness(config.savedBrightness)
        }
    }

    public func updateConfig(_ newConfig: ClamshellConfig, reason: String = "User updated configuration") {
        queue.sync {
            self.config = newConfig
            _ = ConfigManager.shared.save(newConfig)
            self.state.lastActionReason = reason
            self.evaluateTick()
        }
    }

    public func setManualBrightness(_ value: Double) {
        queue.sync {
            let clamped = max(0.0, min(1.0, value))
            _ = DisplayBacklightController.shared.setBrightness(clamped)
            if clamped > 0.02 {
                self.manualBlackoutActive = false
                self.wasIdleBlackedOut = false
                self.config.savedBrightness = clamped
                _ = ConfigManager.shared.save(self.config)
                self.state.isBacklightBlackedOut = false
                self.state.blackoutReason = "Active (Open Lid)"
                self.state.lastActionReason = String(format: "Set brightness to %.0f%%", clamped * 100.0)
            } else {
                self.manualBlackoutActive = true
                self.state.isBacklightBlackedOut = true
                self.state.blackoutReason = "Manual Blackout (0%)"
                self.state.lastActionReason = "Display backlight manually turned off (0%)"
            }
        }
    }

    public func getCombinedReport() -> [String: Any] {
        return queue.sync {
            let tel = monitor.readTelemetry()
            return ClamshellReport.dictionary(telemetry: tel, config: config, state: state)
        }
    }

    private func evaluateTick() {
        let tel = monitor.readTelemetry()
        let now = Date().timeIntervalSince1970

        // 1. Check timed session expiration
        var remainingTimed: Int? = nil
        if config.mode == .timed {
            if let exp = config.timedExpiresAtEpoch {
                let rem = Int((exp - now).rounded())
                if rem <= 0 {
                    config.mode = .off
                    config.timedExpiresAtEpoch = nil
                    _ = ConfigManager.shared.save(config)
                    state.lastActionReason = "Timed awake session expired"
                } else {
                    remainingTimed = rem
                }
            } else {
                let exp = now + Double(config.timedDurationMinutes * 60)
                config.timedExpiresAtEpoch = exp
                _ = ConfigManager.shared.save(config)
                remainingTimed = config.timedDurationMinutes * 60
            }
        }
        state.remainingTimedSeconds = remainingTimed

        // 2. Determine whether system should be kept awake
        let batterySafe = tel.isACConnected || tel.batteryPercent > config.batteryFloorPercent
        let wantAwake: Bool
        let modeDesc: String

        if !batterySafe && config.mode != .off {
            wantAwake = false
            modeDesc = "Battery Safety Pause (< \(config.batteryFloorPercent)%)"
        } else {
            switch config.mode {
            case .indefinite:
                wantAwake = true
                modeDesc = tel.isClamshellClosed
                    ? "Clamshell Closed • Server Awake (Backlight Off)"
                    : "Awake Indefinitely (24/7)"
            case .timed:
                wantAwake = true
                let mins = max(1, (remainingTimed ?? 60) / 60)
                modeDesc = "Timed Session (\(mins)m remaining)"
            case .acOnly:
                wantAwake = tel.isACConnected
                modeDesc = tel.isACConnected
                    ? (tel.isClamshellClosed ? "AC Power • Clamshell Awake" : "Awake on AC Power")
                    : "On Battery (Sleep Allowed)"
            case .off:
                wantAwake = false
                modeDesc = "Normal macOS Sleep (Off)"
            }
        }

        state.isAwakeAsserted = wantAwake
        state.modeDescription = modeDesc

        power.setAwakeAssertions(
            systemAwake: wantAwake,
            displayWindowServerAwake: wantAwake && config.preventDisplaySleep
        )
        power.setKernelClamshellSleepDisabled(wantAwake, currentKernelState: tel.sleepDisabledKernel)

        // 3. Clamshell & Idle Display Backlight State Machine
        let prevClosed = wasClamshellClosed
        wasClamshellClosed = tel.isClamshellClosed

        if tel.isClamshellClosed {
            if config.clamshellBlackoutEnabled {
                // Save open-lid brightness if it was previously lit
                if prevClosed == false && tel.currentBrightness > 0.03 {
                    config.savedBrightness = tel.currentBrightness
                    _ = ConfigManager.shared.save(config)
                }
                if tel.currentBrightness > 0.005 {
                    _ = DisplayBacklightController.shared.setBrightness(0.0)
                    state.lastActionReason = "Clamshell closed → Display backlight off (0%)"
                }
                state.isBacklightBlackedOut = true
                state.blackoutReason = "Clamshell Closed (0% Backlight)"
            } else {
                state.isBacklightBlackedOut = (tel.currentBrightness <= 0.01)
                state.blackoutReason = "Clamshell Closed"
            }
            return
        }

        // Clamshell is OPEN:
        if prevClosed == true {
            // Lid just opened! Restore saved brightness immediately
            manualBlackoutActive = false
            wasIdleBlackedOut = false
            let restoreVal = max(0.10, min(1.0, config.savedBrightness))
            _ = DisplayBacklightController.shared.setBrightness(restoreVal)
            state.isBacklightBlackedOut = false
            state.blackoutReason = "Active (Open Lid)"
            state.lastActionReason = String(format: "Clamshell opened → Restored brightness to %.0f%%", restoreVal * 100.0)
            return
        }

        // Check open-lid idle timeout
        if config.idleDimSeconds > 0 && tel.hidIdleSeconds >= Double(config.idleDimSeconds) {
            if !wasIdleBlackedOut {
                if tel.currentBrightness > 0.03 {
                    config.savedBrightness = tel.currentBrightness
                    _ = ConfigManager.shared.save(config)
                }
                _ = DisplayBacklightController.shared.setBrightness(0.0)
                wasIdleBlackedOut = true
                state.lastActionReason = "Idle timeout (\(config.idleDimSeconds)s) → Display backlight off"
            } else if tel.currentBrightness > 0.005 {
                _ = DisplayBacklightController.shared.setBrightness(0.0)
            }
            state.isBacklightBlackedOut = true
            state.blackoutReason = "Idle Dimmed (\(Int(tel.hidIdleSeconds))s idle)"
            return
        }

        if wasIdleBlackedOut && tel.hidIdleSeconds < 3.0 {
            // User touched keyboard/trackpad while open-lid idle dimmed
            wasIdleBlackedOut = false
            manualBlackoutActive = false
            let restoreVal = max(0.10, min(1.0, config.savedBrightness))
            _ = DisplayBacklightController.shared.setBrightness(restoreVal)
            state.isBacklightBlackedOut = false
            state.blackoutReason = "Active (Open Lid)"
            state.lastActionReason = String(format: "Input detected → Restored brightness to %.0f%%", restoreVal * 100.0)
            return
        }

        // Normal open-lid operation: track user's manual brightness adjustments (F1/F2 or Control Center)
        if !manualBlackoutActive && tel.currentBrightness > 0.03 {
            if abs(tel.currentBrightness - config.savedBrightness) >= 0.03 {
                config.savedBrightness = tel.currentBrightness
                _ = ConfigManager.shared.save(config)
            }
            state.isBacklightBlackedOut = false
            state.blackoutReason = "Active (Open Lid)"
        } else if manualBlackoutActive {
            if tel.currentBrightness > 0.03 {
                // User pressed F2 Brightness Up key after manual blackout
                manualBlackoutActive = false
                config.savedBrightness = tel.currentBrightness
                _ = ConfigManager.shared.save(config)
                state.isBacklightBlackedOut = false
                state.blackoutReason = "Active (Open Lid)"
            } else {
                state.isBacklightBlackedOut = true
                state.blackoutReason = "Manual Blackout (0%)"
            }
        }
    }
}
