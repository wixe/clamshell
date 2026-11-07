import Foundation
import IOKit
import IOKit.pwr_mgt
import CoreGraphics
import Darwin

public final class DisplayBacklightController {
    public static let shared = DisplayBacklightController()

    private typealias DSGetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSetBrightnessFn = @convention(c) (UInt32, Float) -> Int32
    private typealias CDGetBrightnessFn = @convention(c) (UInt32) -> Double
    private typealias CDSetBrightnessFn = @convention(c) (UInt32, Double) -> Void

    private var dsHandle: UnsafeMutableRawPointer?
    private var cdHandle: UnsafeMutableRawPointer?
    private var dsGet: DSGetBrightnessFn?
    private var dsSet: DSSetBrightnessFn?
    private var cdGet: CDGetBrightnessFn?
    private var cdSet: CDSetBrightnessFn?

    private init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            self.dsHandle = h
            if let symGet = dlsym(h, "DisplayServicesGetBrightness") {
                self.dsGet = unsafeBitCast(symGet, to: DSGetBrightnessFn.self)
            }
            if let symSet = dlsym(h, "DisplayServicesSetBrightness") {
                self.dsSet = unsafeBitCast(symSet, to: DSSetBrightnessFn.self)
            }
        }
        if let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) {
            self.cdHandle = h
            if let symGet = dlsym(h, "CoreDisplay_Display_GetUserBrightness") {
                self.cdGet = unsafeBitCast(symGet, to: CDGetBrightnessFn.self)
            }
            if let symSet = dlsym(h, "CoreDisplay_Display_SetUserBrightness") {
                self.cdSet = unsafeBitCast(symSet, to: CDSetBrightnessFn.self)
            }
        }
    }

    public func getBrightness() -> Double {
        let did = CGMainDisplayID()
        if let dsGet = dsGet {
            var val: Float = 0.0
            if dsGet(did, &val) == 0 {
                return Double(max(0.0, min(1.0, val)))
            }
        }
        if let cdGet = cdGet {
            let val = cdGet(did)
            if val >= 0.0 && val <= 1.0 {
                return val
            }
        }
        return 0.65
    }

    @discardableResult
    public func setBrightnessDirect(_ value: Double) -> Bool {
        let clamped = Float(max(0.0, min(1.0, value)))
        let did = CGMainDisplayID()
        var ok = false
        if let dsSet = dsSet {
            if dsSet(did, clamped) == 0 {
                ok = true
            }
        }
        if !ok, let cdSet = cdSet {
            cdSet(did, Double(clamped))
            ok = true
        }
        return ok
    }

    @discardableResult
    public func setBrightness(_ value: Double) -> Bool {
        let clamped = max(0.0, min(1.0, value))
        let directOK = setBrightnessDirect(clamped)

        // If running as root daemon (UID 0), also dispatch inside the active GUI console user session
        // so WindowServer / DisplayServices always receives the update even when Menu Bar app is closed.
        if getuid() == 0 {
            var st = stat()
            if stat("/dev/console", &st) == 0 && st.st_uid != 0 {
                let uid = st.st_uid
                let bin = FileManager.default.isExecutableFile(atPath: ClamshellLayout.cliBinary)
                    ? ClamshellLayout.cliBinary
                    : ClamshellLayout.daemonBinary
                let arg = String(format: "%.3f", clamped)
                _ = Shell.run("/bin/launchctl", ["asuser", "\(uid)", bin, "brightness-sync", arg])
                return true
            }
        }
        return directOK
    }
}

public final class HardwareMonitor {
    public init() {}

    public func readTelemetry() -> HardwareTelemetry {
        let rootStatus = readPMRootDomain()
        let idleSec = readHIDIdleSeconds()
        let batt = readBatteryInfo()
        let brightness = DisplayBacklightController.shared.getBrightness()

        let mainID = CGMainDisplayID()
        let online = CGDisplayIsOnline(mainID) != 0
        let w = CGDisplayPixelsWide(mainID)
        let h = CGDisplayPixelsHigh(mainID)
        let res = (w > 0 && h > 0) ? "\(w)×\(h)" : "Headless/Virtual"

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Nominal"
        }

        return HardwareTelemetry(
            isClamshellClosed: rootStatus.clamshellClosed,
            currentBrightness: brightness,
            displayOnline: online,
            displayResolution: res,
            hidIdleSeconds: idleSec,
            isACConnected: batt.isAC,
            isCharging: batt.isCharging,
            batteryPercent: batt.percent,
            wattageW: batt.wattageW,
            sleepDisabledKernel: rootStatus.sleepDisabled,
            screenLocked: rootStatus.screenLocked,
            thermalState: thermal
        )
    }

    private func readPMRootDomain() -> (clamshellClosed: Bool, sleepDisabled: Bool, screenLocked: Bool) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else {
            return (false, false, false)
        }
        defer { IOObjectRelease(service) }

        var closed = false
        if let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            closed = prop
        }

        var sleepDis = false
        if let prop = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            sleepDis = prop
        }

        var locked = false
        let rootEntry = IORegistryGetRootEntry(kIOMainPortDefault)
        if rootEntry != IO_OBJECT_NULL {
            defer { IOObjectRelease(rootEntry) }
            if let users = IORegistryEntryCreateCFProperty(rootEntry, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] {
                for u in users {
                    if let l = u["CGSSessionScreenIsLocked"] as? Bool, l {
                        locked = true
                        break
                    }
                }
            }
        }

        return (closed, sleepDis, locked)
    }

    private func readHIDIdleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return 0.0 }
        defer { IOObjectRelease(service) }

        if let num = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            return max(0.0, num.doubleValue / 1_000_000_000.0)
        }
        return 0.0
    }

    private func readBatteryInfo() -> (isAC: Bool, isCharging: Bool, percent: Int, wattageW: Double) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            return (true, false, 100, 0.0)
        }
        defer { IOObjectRelease(service) }

        var dictRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &dictRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = dictRef?.takeRetainedValue() as? [String: Any] else {
            return (true, false, 100, 0.0)
        }

        let isAC = (dict["ExternalConnected"] as? Bool) ?? true
        let isCharging = (dict["IsCharging"] as? Bool) ?? false

        var pct = 100
        if let cur = dict["CurrentCapacity"] as? Int, let maxCap = dict["MaxCapacity"] as? Int, maxCap > 0 {
            if maxCap == 100 {
                pct = max(0, min(100, cur))
            } else {
                pct = max(0, min(100, Int((Double(cur) / Double(maxCap) * 100.0).rounded())))
            }
        }

        let mv = (dict["Voltage"] as? Int) ?? 0
        let ma = (dict["InstantAmperage"] as? Int) ?? (dict["Amperage"] as? Int) ?? 0
        let watts = (Double(mv) * Double(ma)) / 1_000_000.0

        return (isAC, isCharging, pct, watts)
    }
}

public final class PowerAssertionController {
    private var systemAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var displayAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var isHoldingSystemAssertion = false
    private var isHoldingDisplayAssertion = false

    public init() {}

    deinit {
        releaseAll()
    }

    public func setAwakeAssertions(systemAwake: Bool, displayWindowServerAwake: Bool) {
        if systemAwake && !isHoldingSystemAssertion {
            var id = IOPMAssertionID(0)
            let kr = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Clamshell Keep-Awake Engine (System)" as CFString,
                &id
            )
            if kr == kIOReturnSuccess {
                systemAssertionID = id
                isHoldingSystemAssertion = true
            }
        } else if !systemAwake && isHoldingSystemAssertion {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = IOPMAssertionID(0)
            isHoldingSystemAssertion = false
        }

        if displayWindowServerAwake && !isHoldingDisplayAssertion {
            var id = IOPMAssertionID(0)
            let kr = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Clamshell Keep-Awake Engine (WindowServer Online)" as CFString,
                &id
            )
            if kr == kIOReturnSuccess {
                displayAssertionID = id
                isHoldingDisplayAssertion = true
            }
        } else if !displayWindowServerAwake && isHoldingDisplayAssertion {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = IOPMAssertionID(0)
            isHoldingDisplayAssertion = false
        }
    }

    public func setKernelClamshellSleepDisabled(_ disabled: Bool, currentKernelState: Bool) {
        guard getuid() == 0 else { return }
        guard disabled != currentKernelState else { return }
        _ = Shell.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    public func releaseAll() {
        if isHoldingSystemAssertion {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = IOPMAssertionID(0)
            isHoldingSystemAssertion = false
        }
        if isHoldingDisplayAssertion {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = IOPMAssertionID(0)
            isHoldingDisplayAssertion = false
        }
    }
}
