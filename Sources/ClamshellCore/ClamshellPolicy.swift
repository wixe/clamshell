import Foundation

/// Immutable edge-detection tracker carried purely from tick to tick.
public struct ClamshellTracker: Equatable, Sendable {
    public let wasClamshellClosed: Bool?
    public let wasIdleBlackedOut: Bool
    public let manualBlackoutActive: Bool
    public let pendingOpenBrightnessRestore: Bool

    public init(
        wasClamshellClosed: Bool? = nil,
        wasIdleBlackedOut: Bool = false,
        manualBlackoutActive: Bool = false,
        pendingOpenBrightnessRestore: Bool = false
    ) {
        self.wasClamshellClosed = wasClamshellClosed
        self.wasIdleBlackedOut = wasIdleBlackedOut
        self.manualBlackoutActive = manualBlackoutActive
        self.pendingOpenBrightnessRestore = pendingOpenBrightnessRestore
    }

    public func withPendingOpenBrightnessRestore(_ pending: Bool) -> ClamshellTracker {
        ClamshellTracker(
            wasClamshellClosed: wasClamshellClosed,
            wasIdleBlackedOut: wasIdleBlackedOut,
            manualBlackoutActive: manualBlackoutActive,
            pendingOpenBrightnessRestore: pending
        )
    }

    public static let initial = ClamshellTracker()
}

/// Side-effect descriptor emitted by `ClamshellPolicy`.
public enum ClamshellEffect: Equatable, Sendable {
    case saveConfig(ClamshellConfig)
    case setAwakeAssertions(systemAwake: Bool, displayAwake: Bool)
    case setKernelSleepDisabled(Bool)
    case setBrightness(Double)
    case setSpeakersMuted(Bool)
}

/// Pure output of a single Clamshell evaluation step.
public struct ClamshellTransition: Equatable, Sendable {
    public let config: ClamshellConfig
    public let state: GovernorState
    public let tracker: ClamshellTracker
    public let effects: [ClamshellEffect]

    public init(
        config: ClamshellConfig,
        state: GovernorState,
        tracker: ClamshellTracker,
        effects: [ClamshellEffect]
    ) {
        self.config = config
        self.state = state
        self.tracker = tracker
        self.effects = effects
    }
}

/// Pure functional core for Clamshell's keep-awake, lid blackout, idle dim, and speaker mute policy.
public enum ClamshellPolicy {
    public static func evaluate(
        config: ClamshellConfig,
        state: GovernorState,
        tracker: ClamshellTracker,
        telemetry tel: HardwareTelemetry,
        brightnessReadable: Bool = true,
        managePowerAssertions: Bool = true,
        manageKernelSleep: Bool = true,
        nowEpoch: Double
    ) -> ClamshellTransition {
        var nextConfig = config
        var nextState = state
        var configChanged = false
        var effects: [ClamshellEffect] = []

        // 1. Timed session expiration check (shared across both daemon and menu-bar session mode).
        var remainingTimed: Int? = nil
        if nextConfig.mode == .timed {
            if let exp = nextConfig.timedExpiresAtEpoch {
                let rem = Int((exp - nowEpoch).rounded())
                if rem <= 0 {
                    nextConfig.mode = .off
                    nextConfig.timedExpiresAtEpoch = nil
                    configChanged = true
                    nextState.lastActionReason = "Timed awake session expired"
                } else {
                    remainingTimed = rem
                }
            } else {
                let exp = nowEpoch + Double(nextConfig.timedDurationMinutes * 60)
                nextConfig.timedExpiresAtEpoch = exp
                configChanged = true
                remainingTimed = nextConfig.timedDurationMinutes * 60
            }
        }
        nextState.remainingTimedSeconds = remainingTimed

        // 2. Keep-awake assertion & kernel sleep policy.
        let batterySafe = tel.isACConnected || tel.batteryPercent > nextConfig.batteryFloorPercent
        let wantAwake: Bool
        let modeDesc: String

        if !batterySafe && nextConfig.mode != .off {
            wantAwake = false
            modeDesc = "Battery Safety Pause (< \(nextConfig.batteryFloorPercent)%)"
        } else {
            switch nextConfig.mode {
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

        nextState.isAwakeAsserted = wantAwake
        nextState.modeDescription = modeDesc

        if managePowerAssertions {
            effects.append(.setAwakeAssertions(
                systemAwake: wantAwake,
                displayAwake: wantAwake && nextConfig.preventDisplaySleep
            ))
        }
        if manageKernelSleep && wantAwake != tel.sleepDisabledKernel {
            effects.append(.setKernelSleepDisabled(wantAwake))
        }

        // 3. Clamshell & Idle Display Backlight + Built-in Speaker Mute State Machine.
        let prevClosed = tracker.wasClamshellClosed
        var nextIdleBlackout = tracker.wasIdleBlackedOut
        var nextManualBlackout = tracker.manualBlackoutActive

        if tel.isClamshellClosed {
            if nextConfig.muteSpeakersWhenClosed {
                if !tel.builtInSpeakersMuted {
                    effects.append(.setSpeakersMuted(true))
                }
                nextState.isSpeakerMutedByClamshell = true
            }
            if nextConfig.clamshellBlackoutEnabled {
                if prevClosed == false && brightnessReadable && tel.currentBrightness > 0.03 {
                    nextConfig.savedBrightness = tel.currentBrightness
                    configChanged = true
                }
                let shouldDriveZero = brightnessReadable
                    ? (tel.currentBrightness > 0.005)
                    : (prevClosed != true)
                if shouldDriveZero {
                    effects.append(.setBrightness(0.0))
                    nextState.lastActionReason = "Clamshell closed → 0% backlight & speakers muted"
                }
                nextState.isBacklightBlackedOut = true
                nextState.blackoutReason = "Clamshell Closed (0% Backlight)"
            } else {
                nextState.isBacklightBlackedOut = !brightnessReadable || (tel.currentBrightness <= 0.01)
                nextState.blackoutReason = "Clamshell Closed"
            }

            if configChanged {
                effects.insert(.saveConfig(nextConfig), at: 0)
            }
            let nextTracker = ClamshellTracker(
                wasClamshellClosed: true,
                wasIdleBlackedOut: nextIdleBlackout,
                manualBlackoutActive: nextManualBlackout
            )
            return ClamshellTransition(config: nextConfig, state: nextState, tracker: nextTracker, effects: effects)
        }

        // Clamshell is OPEN:
        if prevClosed == true {
            nextManualBlackout = false
            nextIdleBlackout = false
            let restoreVal = max(0.10, min(1.0, nextConfig.savedBrightness))
            effects.append(.setBrightness(restoreVal))
            if nextConfig.muteSpeakersWhenClosed && nextState.isSpeakerMutedByClamshell {
                effects.append(.setSpeakersMuted(false))
                nextState.isSpeakerMutedByClamshell = false
            }
            nextState.isBacklightBlackedOut = false
            nextState.blackoutReason = "Active (Open Lid)"
            nextState.lastActionReason = String(format: "Clamshell opened → Restored %.0f%% brightness & unmuted speakers", restoreVal * 100.0)
            if configChanged {
                effects.insert(.saveConfig(nextConfig), at: 0)
            }
            let nextTracker = ClamshellTracker(
                wasClamshellClosed: false,
                wasIdleBlackedOut: false,
                manualBlackoutActive: false
            )
            return ClamshellTransition(config: nextConfig, state: nextState, tracker: nextTracker, effects: effects)
        }

        // Open-lid idle timeout:
        if nextConfig.idleDimSeconds > 0 && tel.hidIdleSeconds >= Double(nextConfig.idleDimSeconds) {
            if !nextIdleBlackout {
                if brightnessReadable && tel.currentBrightness > 0.03 {
                    nextConfig.savedBrightness = tel.currentBrightness
                    configChanged = true
                }
                effects.append(.setBrightness(0.0))
                nextIdleBlackout = true
                nextState.lastActionReason = "Idle timeout (\(nextConfig.idleDimSeconds)s) → Display backlight off"
            } else if brightnessReadable && tel.currentBrightness > 0.005 {
                effects.append(.setBrightness(0.0))
            }
            nextState.isBacklightBlackedOut = true
            nextState.blackoutReason = "Idle Dimmed (\(Int(tel.hidIdleSeconds))s idle)"
            if configChanged {
                effects.insert(.saveConfig(nextConfig), at: 0)
            }
            let nextTracker = ClamshellTracker(
                wasClamshellClosed: false,
                wasIdleBlackedOut: nextIdleBlackout,
                manualBlackoutActive: nextManualBlackout
            )
            return ClamshellTransition(config: nextConfig, state: nextState, tracker: nextTracker, effects: effects)
        }

        if nextIdleBlackout && tel.hidIdleSeconds < 3.0 {
            nextIdleBlackout = false
            nextManualBlackout = false
            let restoreVal = max(0.10, min(1.0, nextConfig.savedBrightness))
            effects.append(.setBrightness(restoreVal))
            nextState.isBacklightBlackedOut = false
            nextState.blackoutReason = "Active (Open Lid)"
            nextState.lastActionReason = String(format: "Input detected → Restored brightness to %.0f%%", restoreVal * 100.0)
            if configChanged {
                effects.insert(.saveConfig(nextConfig), at: 0)
            }
            let nextTracker = ClamshellTracker(
                wasClamshellClosed: false,
                wasIdleBlackedOut: false,
                manualBlackoutActive: false
            )
            return ClamshellTransition(config: nextConfig, state: nextState, tracker: nextTracker, effects: effects)
        }

        if brightnessReadable {
            if !nextManualBlackout && tel.currentBrightness > 0.03 {
                if abs(tel.currentBrightness - nextConfig.savedBrightness) >= 0.03 {
                    nextConfig.savedBrightness = tel.currentBrightness
                    configChanged = true
                }
                nextState.isBacklightBlackedOut = false
                nextState.blackoutReason = "Active (Open Lid)"
            } else if nextManualBlackout {
                if tel.currentBrightness > 0.03 {
                    nextManualBlackout = false
                    nextConfig.savedBrightness = tel.currentBrightness
                    configChanged = true
                    nextState.isBacklightBlackedOut = false
                    nextState.blackoutReason = "Active (Open Lid)"
                } else {
                    nextState.isBacklightBlackedOut = true
                    nextState.blackoutReason = "Manual Blackout (0%)"
                }
            }
        }

        if configChanged {
            effects.insert(.saveConfig(nextConfig), at: 0)
        }
        let nextTracker = ClamshellTracker(
            wasClamshellClosed: false,
            wasIdleBlackedOut: nextIdleBlackout,
            manualBlackoutActive: nextManualBlackout
        )
        return ClamshellTransition(config: nextConfig, state: nextState, tracker: nextTracker, effects: effects)
    }

    public static func applyManualBrightness(
        _ value: Double,
        config: ClamshellConfig,
        state: GovernorState,
        tracker: ClamshellTracker
    ) -> ClamshellTransition {
        let clamped = max(0.0, min(1.0, value))
        var nextConfig = config
        var nextState = state
        var effects: [ClamshellEffect] = [.setBrightness(clamped)]
        let nextTracker: ClamshellTracker

        if clamped > 0.02 {
            nextConfig.savedBrightness = clamped
            effects.insert(.saveConfig(nextConfig), at: 0)
            nextState.isBacklightBlackedOut = false
            nextState.blackoutReason = "Active (Open Lid)"
            nextState.lastActionReason = String(format: "Set brightness to %.0f%%", clamped * 100.0)
            nextTracker = ClamshellTracker(
                wasClamshellClosed: tracker.wasClamshellClosed,
                wasIdleBlackedOut: false,
                manualBlackoutActive: false
            )
        } else {
            nextState.isBacklightBlackedOut = true
            nextState.blackoutReason = "Manual Blackout (0%)"
            nextState.lastActionReason = "Display backlight manually turned off (0%)"
            nextTracker = ClamshellTracker(
                wasClamshellClosed: tracker.wasClamshellClosed,
                wasIdleBlackedOut: tracker.wasIdleBlackedOut,
                manualBlackoutActive: true
            )
        }

        return ClamshellTransition(config: nextConfig, state: nextState, tracker: nextTracker, effects: effects)
    }

    public static func menuBarSymbol(isClamshellClosed: Bool, mode: AwakeMode) -> String {
        if mode == .off { return "🌙" }
        if isClamshellClosed { return "🦪" }
        if mode == .timed { return "⏱️" }
        return "☕"
    }

    public static func menuBarTitle(
        isClamshellClosed: Bool,
        currentBrightness: Double,
        config: ClamshellConfig,
        nowEpoch: Double
    ) -> String {
        let symbol = menuBarSymbol(isClamshellClosed: isClamshellClosed, mode: config.mode)
        let brightPct = Int((currentBrightness * 100.0).rounded())
        if config.mode == .off {
            return "\(symbol) Off"
        }
        if isClamshellClosed {
            return "\(symbol) \(brightPct)%"
        }
        if config.mode == .timed, let exp = config.timedExpiresAtEpoch {
            let remSecs = exp - nowEpoch
            if remSecs <= 0 {
                return "🌙 Off"
            }
            let remMins = max(1, Int((remSecs / 60.0).rounded()))
            return "\(symbol) \(remMins)m · \(brightPct)%"
        }
        return "\(symbol) \(brightPct)%"
    }
}
