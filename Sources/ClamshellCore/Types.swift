import Foundation

public enum AwakeMode: String, Codable, CaseIterable, Equatable {
    case indefinite = "indefinite"
    case timed = "timed"
    case acOnly = "ac_only"
    case off = "off"

    public var displayName: String {
        switch self {
        case .indefinite: return "Awake Indefinitely (24/7)"
        case .timed: return "Timed Awake Session"
        case .acOnly: return "Awake on AC Power Only"
        case .off: return "Normal macOS Sleep (Off)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .indefinite: return "24/7 Awake"
        case .timed: return "Timed"
        case .acOnly: return "AC Only"
        case .off: return "Sleep Allowed"
        }
    }
}

public struct ClamshellConfig: Codable, Equatable {
    public var mode: AwakeMode
    public var timedDurationMinutes: Int
    public var timedExpiresAtEpoch: Double?
    public var clamshellBlackoutEnabled: Bool
    public var idleDimSeconds: Int
    public var savedBrightness: Double
    public var batteryFloorPercent: Int
    public var preventDisplaySleep: Bool
    public var pollIntervalSeconds: Double

    public init(
        mode: AwakeMode = .indefinite,
        timedDurationMinutes: Int = 60,
        timedExpiresAtEpoch: Double? = nil,
        clamshellBlackoutEnabled: Bool = true,
        idleDimSeconds: Int = 300,
        savedBrightness: Double = 0.65,
        batteryFloorPercent: Int = 20,
        preventDisplaySleep: Bool = true,
        pollIntervalSeconds: Double = 2.0
    ) {
        self.mode = mode
        self.timedDurationMinutes = timedDurationMinutes
        self.timedExpiresAtEpoch = timedExpiresAtEpoch
        self.clamshellBlackoutEnabled = clamshellBlackoutEnabled
        self.idleDimSeconds = idleDimSeconds
        self.savedBrightness = max(0.05, min(1.0, savedBrightness))
        self.batteryFloorPercent = max(5, min(80, batteryFloorPercent))
        self.preventDisplaySleep = preventDisplaySleep
        self.pollIntervalSeconds = max(0.5, min(10.0, pollIntervalSeconds))
    }

    public static let `default` = ClamshellConfig()
}

public struct HardwareTelemetry: Codable, Equatable {
    public let isClamshellClosed: Bool
    public let currentBrightness: Double
    public let displayOnline: Bool
    public let displayResolution: String
    public let hidIdleSeconds: Double
    public let isACConnected: Bool
    public let isCharging: Bool
    public let batteryPercent: Int
    public let wattageW: Double
    public let sleepDisabledKernel: Bool
    public let screenLocked: Bool
    public let thermalState: String

    public init(
        isClamshellClosed: Bool,
        currentBrightness: Double,
        displayOnline: Bool,
        displayResolution: String,
        hidIdleSeconds: Double,
        isACConnected: Bool,
        isCharging: Bool,
        batteryPercent: Int,
        wattageW: Double,
        sleepDisabledKernel: Bool,
        screenLocked: Bool,
        thermalState: String
    ) {
        self.isClamshellClosed = isClamshellClosed
        self.currentBrightness = currentBrightness
        self.displayOnline = displayOnline
        self.displayResolution = displayResolution
        self.hidIdleSeconds = hidIdleSeconds
        self.isACConnected = isACConnected
        self.isCharging = isCharging
        self.batteryPercent = batteryPercent
        self.wattageW = wattageW
        self.sleepDisabledKernel = sleepDisabledKernel
        self.screenLocked = screenLocked
        self.thermalState = thermalState
    }
}

public struct GovernorState: Codable, Equatable {
    public var isAwakeAsserted: Bool
    public var isBacklightBlackedOut: Bool
    public var blackoutReason: String
    public var modeDescription: String
    public var remainingTimedSeconds: Int?
    public var lastActionReason: String

    public init(
        isAwakeAsserted: Bool = false,
        isBacklightBlackedOut: Bool = false,
        blackoutReason: String = "Active (Open Lid)",
        modeDescription: String = "Initializing…",
        remainingTimedSeconds: Int? = nil,
        lastActionReason: String = "Startup"
    ) {
        self.isAwakeAsserted = isAwakeAsserted
        self.isBacklightBlackedOut = isBacklightBlackedOut
        self.blackoutReason = blackoutReason
        self.modeDescription = modeDescription
        self.remainingTimedSeconds = remainingTimedSeconds
        self.lastActionReason = lastActionReason
    }

    public static let initial = GovernorState()
}
