import Foundation

/// Imperative shell driving `ClamshellPolicy` via instant kernel `IOPMrootDomain` lid events
/// and an adaptive fallback `DispatchSourceTimer` with deterministic autorelease draining.
public final class ClamshellGovernor {
    public private(set) var config: ClamshellConfig
    public private(set) var state: GovernorState = .initial
    private var tracker: ClamshellTracker = .initial

    private let monitor = HardwareMonitor()
    private let power = PowerAssertionController()
    private var timer: DispatchSourceTimer?
    private var eventObserver: ClamshellEventObserver?
    private var currentTimerInterval: Double = 0
    private let queue = DispatchQueue(
        label: "io.github.wixe.clamshell.governor",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    public init(config: ClamshellConfig) {
        self.config = config
    }

    deinit {
        eventObserver?.stop()
        timer?.cancel()
    }

    public func start() {
        queue.sync {
            autoreleasepool {
                self.evaluateTick()
            }
        }

        let observer = ClamshellEventObserver(queue: queue) { [weak self] in
            self?.evaluateTick()
        }
        observer.start()
        self.eventObserver = observer

        let interval = desiredTimerInterval()
        self.currentTimerInterval = interval
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in
            autoreleasepool {
                self?.evaluateTick()
            }
        }
        t.resume()
        self.timer = t
    }

    public func stop() {
        eventObserver?.stop()
        eventObserver = nil
        timer?.cancel()
        timer = nil
        autoreleasepool {
            let tel = monitor.readTelemetry()
            power.releaseAll()
            power.setKernelClamshellSleepDisabled(false, currentKernelState: tel.sleepDisabledKernel)
            if state.isBacklightBlackedOut && !tel.isClamshellClosed {
                _ = DisplayBacklightController.shared.setBrightness(config.savedBrightness)
            }
            if state.isSpeakerMutedByClamshell && !tel.isClamshellClosed {
                _ = AudioOutputController.shared.setBuiltInSpeakersMuted(false)
            }
        }
    }

    public func updateConfig(_ newConfig: ClamshellConfig, reason: String = "User updated configuration") {
        queue.sync {
            autoreleasepool {
                let prevMutePolicy = self.config.muteSpeakersWhenClosed
                self.config = newConfig
                _ = ConfigManager.shared.save(newConfig)
                self.state.lastActionReason = reason
                if prevMutePolicy && !newConfig.muteSpeakersWhenClosed {
                    _ = AudioOutputController.shared.setBuiltInSpeakersMuted(false)
                    self.state.isSpeakerMutedByClamshell = false
                }
                self.evaluateTick()
            }
        }
    }

    public func setManualBrightness(_ value: Double) {
        queue.sync {
            autoreleasepool {
                let transition = ClamshellPolicy.applyManualBrightness(
                    value,
                    config: self.config,
                    state: self.state,
                    tracker: self.tracker
                )
                self.applyTransition(transition, currentKernelState: false)
            }
        }
    }

    public func getCombinedReport() -> [String: Any] {
        queue.sync {
            autoreleasepool {
                let tel = monitor.readTelemetry()
                return ClamshellReport.dictionary(telemetry: tel, config: config, state: state)
            }
        }
    }

    private func desiredTimerInterval() -> Double {
        if tracker.wasClamshellClosed == true && config.mode != .timed {
            // Kernel IOPMrootDomain interest notification wakes < 2ms on lid open; 10s safety heartbeat.
            return max(config.pollIntervalSeconds, 10.0)
        }
        if config.idleDimSeconds > 0 || config.mode == .timed {
            return max(2.0, config.pollIntervalSeconds)
        }
        return max(config.pollIntervalSeconds, 6.0)
    }

    private func rescheduleTimerIfNeeded() {
        let next = desiredTimerInterval()
        guard abs(next - currentTimerInterval) >= 0.5, let timer else { return }
        currentTimerInterval = next
        timer.schedule(deadline: .now() + next, repeating: next, leeway: .milliseconds(250))
    }

    private func evaluateTick() {
        autoreleasepool {
            let diskCfg = ConfigManager.shared.load()
            if diskCfg != config {
                config = diskCfg
            }
            let snap = monitor.readGuardSnapshot(includeIdleTime: config.idleDimSeconds > 0)
            let transition = ClamshellPolicy.evaluate(
                config: config,
                state: state,
                tracker: tracker,
                telemetry: snap.telemetry,
                brightnessReadable: snap.brightnessReadable,
                managePowerAssertions: true,
                manageKernelSleep: getuid() == 0,
                nowEpoch: Date().timeIntervalSince1970
            )
            applyTransition(transition, currentKernelState: snap.telemetry.sleepDisabledKernel)
            rescheduleTimerIfNeeded()
        }
    }

    private func applyTransition(_ transition: ClamshellTransition, currentKernelState: Bool) {
        self.config = transition.config
        self.state = transition.state
        self.tracker = transition.tracker

        for effect in transition.effects {
            switch effect {
            case let .saveConfig(cfg):
                _ = ConfigManager.shared.save(cfg)
            case let .setAwakeAssertions(systemAwake, displayAwake):
                power.setAwakeAssertions(systemAwake: systemAwake, displayWindowServerAwake: displayAwake)
            case let .setKernelSleepDisabled(disabled):
                power.setKernelClamshellSleepDisabled(disabled, currentKernelState: currentKernelState)
            case let .setBrightness(val):
                _ = DisplayBacklightController.shared.setBrightness(val)
            case let .setSpeakersMuted(muted):
                _ = AudioOutputController.shared.setBuiltInSpeakersMuted(muted)
            }
        }
    }
}
