import Foundation
import Darwin

public enum ClamshellReport {
    public static func formatISO8601(_ date: Date) -> String {
        var secs = time_t(date.timeIntervalSince1970)
        var tmVal = tm()
        gmtime_r(&secs, &tmVal)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            Int(tmVal.tm_year) + 1900,
            Int(tmVal.tm_mon) + 1,
            Int(tmVal.tm_mday),
            Int(tmVal.tm_hour),
            Int(tmVal.tm_min),
            Int(tmVal.tm_sec)
        )
    }

    public static func dictionary(
        telemetry: HardwareTelemetry,
        config: ClamshellConfig,
        state: GovernorState
    ) -> [String: Any] {
        return [
            "version": ClamshellVersion,
            "timestamp": formatISO8601(Date()),
            "telemetry": [
                "clamshell_closed": telemetry.isClamshellClosed,
                "brightness_percent": Int((telemetry.currentBrightness * 100.0).rounded()),
                "brightness_raw": (telemetry.currentBrightness * 1000.0).rounded() / 1000.0,
                "display_online": telemetry.displayOnline,
                "display_resolution": telemetry.displayResolution,
                "built_in_speakers_muted": telemetry.builtInSpeakersMuted,
                "audio_output_device": telemetry.audioOutputDeviceName,
                "hid_idle_seconds": Int(telemetry.hidIdleSeconds.rounded()),
                "ac_connected": telemetry.isACConnected,
                "is_charging": telemetry.isCharging,
                "battery_percent": telemetry.batteryPercent,
                "wattage_w": (telemetry.wattageW * 100.0).rounded() / 100.0,
                "sleep_disabled_kernel": telemetry.sleepDisabledKernel,
                "screen_locked": telemetry.screenLocked,
                "thermal_state": telemetry.thermalState
            ],
            "config": [
                "mode": config.mode.rawValue,
                "timed_duration_minutes": config.timedDurationMinutes,
                "clamshell_blackout_enabled": config.clamshellBlackoutEnabled,
                "mute_speakers_when_closed": config.muteSpeakersWhenClosed,
                "idle_dim_seconds": config.idleDimSeconds,
                "saved_brightness_percent": Int((config.savedBrightness * 100.0).rounded()),
                "battery_floor_percent": config.batteryFloorPercent,
                "prevent_display_sleep": config.preventDisplaySleep
            ],
            "governor": [
                "version": ClamshellVersion,
                "awake_asserted": state.isAwakeAsserted,
                "backlight_blacked_out": state.isBacklightBlackedOut,
                "speaker_muted_by_clamshell": state.isSpeakerMutedByClamshell,
                "blackout_reason": state.blackoutReason,
                "mode": state.modeDescription,
                "remaining_timed_seconds": state.remainingTimedSeconds as Any,
                "last_action_reason": state.lastActionReason
            ]
        ]
    }
}
