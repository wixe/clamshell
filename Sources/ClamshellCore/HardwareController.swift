import Foundation
import IOKit
import IOKit.pwr_mgt
import CoreGraphics
import CoreAudio
import Darwin
import notify

public final class AudioOutputController {
    public static let shared = AudioOutputController()

    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(
        label: "io.github.wixe.clamshell.audio-events",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private var cachedSpeakerID: (at: Date, id: AudioDeviceID?)?
    private var cachedDefaultOutputName: (at: Date, name: String)?

    private init() {
        registerPropertyListeners()
    }

    private func registerPropertyListeners() {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(sysObj, &devicesAddr, listenerQueue) { [weak self] _, _ in
            self?.invalidateCache()
        }

        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(sysObj, &defaultAddr, listenerQueue) { [weak self] _, _ in
            self?.invalidateCache()
        }
    }

    public func invalidateCache() {
        lock.lock()
        cachedSpeakerID = nil
        cachedDefaultOutputName = nil
        lock.unlock()
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &dataSize, &devices) == noErr else {
            return []
        }
        return devices
    }

    /// CoreAudio `kAudioObjectPropertyName` returns a +1 retained `CFStringRef`.
    /// Transferring via `Unmanaged<CFString>?.takeRetainedValue()` prevents leaking a `CFString` on every query.
    private func deviceName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        if status == noErr, let retained = cfName?.takeRetainedValue() {
            return retained as String
        }
        return "Audio Output"
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else {
            return 0
        }
        return transport
    }

    public func findBuiltInSpeakerDeviceID() -> AudioDeviceID? {
        let now = Date()
        lock.lock()
        if let cached = cachedSpeakerID, now.timeIntervalSince(cached.at) < 30.0 {
            let id = cached.id
            lock.unlock()
            return id
        }
        lock.unlock()

        let resolved: AudioDeviceID? = autoreleasepool {
            let candidates = allDeviceIDs().filter { id in
                hasOutputStreams(id) && transportType(id) == kAudioDeviceTransportTypeBuiltIn
            }
            for id in candidates {
                if deviceName(id).lowercased().contains("speaker") {
                    return id
                }
            }
            for id in candidates {
                if !deviceName(id).lowercased().contains("headphone") {
                    return id
                }
            }
            return candidates.first
        }

        lock.lock()
        cachedSpeakerID = (now, resolved)
        lock.unlock()
        return resolved
    }

    public func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &devID) == noErr, devID != 0 else {
            return nil
        }
        return devID
    }

    public func defaultOutputDeviceName() -> String {
        let now = Date()
        lock.lock()
        if let cached = cachedDefaultOutputName, now.timeIntervalSince(cached.at) < 30.0 {
            let name = cached.name
            lock.unlock()
            return name
        }
        lock.unlock()

        let name: String = autoreleasepool {
            guard let id = defaultOutputDeviceID() else { return "None" }
            return deviceName(id)
        }

        lock.lock()
        cachedDefaultOutputName = (now, name)
        lock.unlock()
        return name
    }

    public func isBuiltInSpeakersMuted() -> Bool {
        guard let speakerID = findBuiltInSpeakerDeviceID() else { return false }
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(speakerID, &addr) {
                var muted: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(speakerID, &addr, 0, nil, &size, &muted) == noErr {
                    return muted != 0
                }
            }
        }
        return false
    }

    @discardableResult
    public func setBuiltInSpeakersMutedDirect(_ muted: Bool) -> Bool {
        guard let speakerID = findBuiltInSpeakerDeviceID() else { return false }
        var didSet = false
        let val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)

        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(speakerID, &addr) {
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(speakerID, &addr, &settable) == noErr && settable.boolValue {
                    var mutableVal = val
                    if AudioObjectSetPropertyData(speakerID, &addr, 0, nil, size, &mutableVal) == noErr {
                        didSet = true
                    }
                }
            }
        }
        return didSet
    }

    @discardableResult
    public func setBuiltInSpeakersMuted(_ muted: Bool) -> Bool {
        let directOK = setBuiltInSpeakersMutedDirect(muted)
        if getuid() == 0 {
            var st = stat()
            if stat("/dev/console", &st) == 0 && st.st_uid != 0 {
                let uid = st.st_uid
                let bin = FileManager.default.isExecutableFile(atPath: ClamshellLayout.cliBinary)
                    ? ClamshellLayout.cliBinary
                    : ClamshellLayout.daemonBinary
                _ = Shell.run("/bin/launchctl", ["asuser", "\(uid)", bin, "mute-sync", muted ? "1" : "0"])
                return true
            }
        }
        return directOK
    }
}

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

    /// Finds the physical built-in Apple LCD (`CGDisplayIsBuiltin`), ignoring virtual Screen Sharing
    /// or external displays so closed-clamshell backlight control always targets the physical panel.
    public func builtInDisplayID() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success, count > 0 else {
            let main = CGMainDisplayID()
            return (CGDisplayIsOnline(main) != 0 && CGDisplayIsBuiltin(main) != 0) ? main : nil
        }
        return displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
    }

    /// Returns hardware brightness in `0.0...1.0` when the physical built-in display is online and readable,
    /// or `nil` when offline/virtual-only so callers never mistake a virtual Screen Sharing display for 100%.
    public func readBrightness() -> Double? {
        guard let did = builtInDisplayID() else { return nil }
        if let dsGet = dsGet {
            var val: Float = 0.0
            if dsGet(did, &val) == 0, val.isFinite {
                return Double(max(0.0, min(1.0, val)))
            }
        }
        if let cdGet = cdGet {
            let val = cdGet(did)
            if val.isFinite, val >= 0.0, val <= 1.0 {
                return val
            }
        }
        return nil
    }

    public func getBrightness() -> Double {
        if let actual = readBrightness() {
            return actual
        }
        return 0.0
    }

    @discardableResult
    public func setBrightnessDirect(_ value: Double) -> Bool {
        let clamped = Float(max(0.0, min(1.0, value)))
        guard let did = builtInDisplayID() else { return false }
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
    private let lock = NSLock()
    private var pmRootService: io_service_t = IO_OBJECT_NULL
    private var hidService: io_service_t = IO_OBJECT_NULL
    private var batteryService: io_service_t = IO_OBJECT_NULL
    private var cachedBattery: (at: Date, info: (isAC: Bool, isCharging: Bool, percent: Int, wattageW: Double))?

    public init() {
        self.pmRootService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        self.hidService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        self.batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if pmRootService != IO_OBJECT_NULL {
            IOObjectRelease(pmRootService)
            pmRootService = IO_OBJECT_NULL
        }
        if hidService != IO_OBJECT_NULL {
            IOObjectRelease(hidService)
            hidService = IO_OBJECT_NULL
        }
        if batteryService != IO_OBJECT_NULL {
            IOObjectRelease(batteryService)
            batteryService = IO_OBJECT_NULL
        }
    }

    /// Lightweight snapshot for background guard loops. Skips expensive `IOConsoleUsers`,
    /// resolution string allocation, and `HIDIdleTime` when lid is closed or idle dim is off.
    public func readGuardSnapshot(includeIdleTime: Bool) -> (telemetry: HardwareTelemetry, brightnessReadable: Bool) {
        autoreleasepool {
            let rootStatus = readPMRootDomain(includeScreenLocked: false)
            let idleSec = (!rootStatus.clamshellClosed && includeIdleTime) ? readHIDIdleSeconds() : 0.0
            let batt = readBatteryInfo(maxAge: 10.0)
            let rawBright = DisplayBacklightController.shared.readBrightness()
            let brightness = rawBright ?? 0.0
            let speakersMuted = AudioOutputController.shared.isBuiltInSpeakersMuted()

            let tel = HardwareTelemetry(
                isClamshellClosed: rootStatus.clamshellClosed,
                currentBrightness: brightness,
                displayOnline: rawBright != nil || CGDisplayIsOnline(CGMainDisplayID()) != 0,
                displayResolution: "",
                builtInSpeakersMuted: speakersMuted,
                audioOutputDeviceName: "",
                hidIdleSeconds: idleSec,
                isACConnected: batt.isAC,
                isCharging: batt.isCharging,
                batteryPercent: batt.percent,
                wattageW: batt.wattageW,
                sleepDisabledKernel: rootStatus.sleepDisabled,
                screenLocked: false,
                thermalState: "Nominal"
            )
            return (tel, rawBright != nil)
        }
    }

    public func readTelemetry() -> HardwareTelemetry {
        autoreleasepool {
            let rootStatus = readPMRootDomain(includeScreenLocked: true)
            let idleSec = readHIDIdleSeconds()
            let batt = readBatteryInfo(maxAge: 1.0)
            let brightness = DisplayBacklightController.shared.getBrightness()
            let speakersMuted = AudioOutputController.shared.isBuiltInSpeakersMuted()
            let outDevice = AudioOutputController.shared.defaultOutputDeviceName()

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
                builtInSpeakersMuted: speakersMuted,
                audioOutputDeviceName: outDevice,
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
    }

    private func ensurePMRootService() -> io_service_t {
        lock.lock()
        defer { lock.unlock() }
        if pmRootService == IO_OBJECT_NULL {
            pmRootService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        }
        return pmRootService
    }

    private func ensureHIDService() -> io_service_t {
        lock.lock()
        defer { lock.unlock() }
        if hidService == IO_OBJECT_NULL {
            hidService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        }
        return hidService
    }

    private func ensureBatteryService() -> io_service_t {
        lock.lock()
        defer { lock.unlock() }
        if batteryService == IO_OBJECT_NULL {
            batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        return batteryService
    }

    private func readPMRootDomain(includeScreenLocked: Bool) -> (clamshellClosed: Bool, sleepDisabled: Bool, screenLocked: Bool) {
        let service = ensurePMRootService()
        guard service != IO_OBJECT_NULL else {
            return (false, false, false)
        }

        var closed = false
        if let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            closed = prop
        }

        var sleepDis = false
        if let prop = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            sleepDis = prop
        }

        var locked = false
        if includeScreenLocked {
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
        }

        return (closed, sleepDis, locked)
    }

    private func readHIDIdleSeconds() -> Double {
        let service = ensureHIDService()
        guard service != IO_OBJECT_NULL else { return 0.0 }

        if let num = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            return max(0.0, num.doubleValue / 1_000_000_000.0)
        }
        return 0.0
    }

    private func readBatteryInfo(maxAge: TimeInterval) -> (isAC: Bool, isCharging: Bool, percent: Int, wattageW: Double) {
        let now = Date()
        if maxAge > 0 {
            lock.lock()
            if let cached = cachedBattery, now.timeIntervalSince(cached.at) < maxAge {
                let info = cached.info
                lock.unlock()
                return info
            }
            lock.unlock()
        }

        let service = ensureBatteryService()
        guard service != IO_OBJECT_NULL else {
            return (true, false, 100, 0.0)
        }

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
        let result = (isAC, isCharging, pct, watts)

        lock.lock()
        cachedBattery = (now, result)
        lock.unlock()
        return result
    }
}

/// Zero-CPU kernel event observer for `IOPMrootDomain` (`AppleClamshellState` Hall-effect sensor
/// and system sleep/power transitions) plus Darwin power-source notifications.
public final class ClamshellEventObserver {
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var notifyPort: IONotificationPortRef?
    private var interestNotification: io_object_t = IO_OBJECT_NULL
    private var powerSourceToken: Int32 = NOTIFY_TOKEN_INVALID
    private var isStarted = false

    public init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if let port = IONotificationPortCreate(kIOMainPortDefault) {
                IONotificationPortSetDispatchQueue(port, queue)
                self.notifyPort = port

                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                let callback: IOServiceInterestCallback = { refcon, _, _, _ in
                    guard let refcon else { return }
                    let observer = Unmanaged<ClamshellEventObserver>.fromOpaque(refcon).takeUnretainedValue()
                    autoreleasepool {
                        observer.onChange()
                    }
                }
                var notif: io_object_t = IO_OBJECT_NULL
                if IOServiceAddInterestNotification(
                    port,
                    service,
                    kIOGeneralInterest,
                    callback,
                    selfPtr,
                    &notif
                ) == KERN_SUCCESS {
                    self.interestNotification = notif
                }
            }
        }

        var token: Int32 = NOTIFY_TOKEN_INVALID
        if notify_register_dispatch("com.apple.system.powersources.source", &token, queue, { [weak self] _ in
            autoreleasepool {
                self?.onChange()
            }
        }) == NOTIFY_STATUS_OK {
            self.powerSourceToken = token
        }
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false

        if interestNotification != IO_OBJECT_NULL {
            IOObjectRelease(interestNotification)
            interestNotification = IO_OBJECT_NULL
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if powerSourceToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(powerSourceToken)
            powerSourceToken = NOTIFY_TOKEN_INVALID
        }
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
