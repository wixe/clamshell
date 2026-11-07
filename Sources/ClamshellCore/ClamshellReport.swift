import Foundation

public enum ClamshellReport {
    public static func dictionary(
        telemetry: HardwareTelemetry,
        config: ClamshellConfig,
        state: GovernorState
    ) -> [String: Any] {
        return [
            "version": ClamshellVersion,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "telemetry": [
                "clamshell_closed": telemetry.isClamshellClosed,
                "brightness_percent": Int((telemetry.currentBrightness * 100.0).rounded()),
                "brightness_raw": Double(String(format: "%.3f", telemetry.currentBrightness)) ?? telemetry.currentBrightness,
                "display_online": telemetry.displayOnline,
                "display_resolution": telemetry.displayResolution,
                "built_in_speakers_muted": telemetry.builtInSpeakersMuted,
                "audio_output_device": telemetry.audioOutputDeviceName,
                "hid_idle_seconds": Int(telemetry.hidIdleSeconds.rounded()),
                "ac_connected": telemetry.isACConnected,
                "is_charging": telemetry.isCharging,
                "battery_percent": telemetry.batteryPercent,
                "wattage_w": Double(String(format: "%.2f", telemetry.wattageW)) ?? telemetry.wattageW,
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
