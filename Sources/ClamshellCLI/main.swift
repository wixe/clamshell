import Foundation
import ClamshellCore

let VERSION = ClamshellVersion

func printHelp() {
    print("""
    🦪 Clamshell — Intelligent Clamshell, Display Backlight & Keep-Awake Governor for macOS
    Version \(VERSION) (Apple Silicon & Intel Macs)
    Website: \(ClamshellLayout.projectURL.absoluteString)

    USAGE:
      clamshell <command> [options]

    COMMANDS:
      status [--json]                     Display lid state, backlight brightness, keep-awake mode & telemetry
      awake <indefinite|timed|ac|off> [m] Set keep-awake mode (replaces Amphetamine & caffeinate)
      brightness <0-100>                  Set display backlight brightness (0 = full blackout, WindowServer stays on)
      blackout <on|off>                   Toggle automatic 0% backlight when clamshell is closed
      idle <seconds|off>                  Turn off backlight after N seconds of open-lid inactivity (e.g. 300 or off)
      floor <5-80>                        Set battery safety floor percentage (default: 20%)
      daemon                              Run the Clamshell governor daemon in the foreground
      install                             Install background system daemon (clamshelld)
      uninstall                           Remove background system daemon and restore normal sleep
      update [--check|--force]            Check GitHub and automatically upgrade CLI and Clamshell.app
      version                             Print version information

    EXAMPLES:
      clamshell status
      clamshell awake indefinite
      clamshell awake timed 120
      clamshell brightness 0
      clamshell brightness 65
      clamshell blackout on
      clamshell idle 300
      sudo clamshell install
    """)
}

var ipcServer: UnixSocketServer? = nil
var activeGovernor: ClamshellGovernor? = nil

func handleStatus(jsonOutput: Bool) {
    if jsonOutput {
        if let liveJson = UnixSocketClient.send("STATUS") {
            print(liveJson.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        let cfg = ConfigManager.shared.load()
        let monitor = HardwareMonitor()
        var state = GovernorState.initial
        state.modeDescription = "Offline (Run 'sudo clamshell install')"
        state.lastActionReason = "Daemon not running"
        let report = ClamshellReport.dictionary(
            telemetry: monitor.readTelemetry(),
            config: cfg,
            state: state
        )
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        return
    }

    let monitor = HardwareMonitor()
    let tel = monitor.readTelemetry()
    let cfg = ConfigManager.shared.load()

    var governorMode = "Offline (Run 'sudo clamshell install')"
    var lastAction = "Daemon not running"
    if let liveJson = UnixSocketClient.send("STATUS"),
       let data = liveJson.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let gov = obj["governor"] as? [String: Any] {
        if let m = gov["mode"] as? String { governorMode = m }
        if let a = gov["last_action_reason"] as? String { lastAction = a }
    }

    let lidStr = tel.isClamshellClosed ? "🦪 Closed (Clamshell Server Mode)" : "💻 Open (Interactive Mode)"
    let brightPct = Int((tel.currentBrightness * 100.0).rounded())
    let brightStr = brightPct == 0
        ? "🌑 0% (Physical Backlight OFF • Zero Burn-In)"
        : "☀️ \(brightPct)% (Saved Open-Lid: \(Int((cfg.savedBrightness * 100.0).rounded()))%)"
    let powerStr = tel.isCharging
        ? "⚡ AC Charging (\(tel.batteryPercent)%)"
        : (tel.isACConnected ? "🔌 AC Connected (\(tel.batteryPercent)%)" : "🔋 On Battery (\(tel.batteryPercent)%)")
    let idleStr = tel.hidIdleSeconds < 60
        ? String(format: "%.0fs", tel.hidIdleSeconds)
        : String(format: "%dm %ds", Int(tel.hidIdleSeconds) / 60, Int(tel.hidIdleSeconds) % 60)
    let idlePolicyStr = cfg.idleDimSeconds > 0 ? "\(cfg.idleDimSeconds)s (\(cfg.idleDimSeconds / 60)m)" : "Disabled"

    print("""
    ========================================================================
    🦪 CLAMSHELL DISPLAY BACKLIGHT & KEEP-AWAKE GOVERNOR
    ========================================================================
      Clamshell State:    \(lidStr)
      Display Backlight:  \(brightStr)
      WindowServer GPU:   \(tel.displayOnline ? "Online" : "Offline") (\(tel.displayResolution))
      Keep-Awake Mode:    \(governorMode)
      Closed Blackout:    \(cfg.clamshellBlackoutEnabled ? "Enabled (0% when closed, auto-restore when opened)" : "Disabled")
      Open-Lid Idle Off:  \(idlePolicyStr) (Current Idle: \(idleStr))
      Power & Battery:    \(powerStr)  •  Safety Floor: \(cfg.batteryFloorPercent)%
      Kernel Sleep Lock:  \(tel.sleepDisabledKernel ? "Active (SleepDisabled=1)" : "Standard (SleepDisabled=0)")
      Last Transition:    \(lastAction)
      Icon Legend:        🦪 Closed Awake (0% LCD)  •  ☕ Open Awake  •  🌙 Sleep Allowed
    ========================================================================
    """)

    if let cached = UpdateChecker.cachedRelease(),
       UpdateChecker.isVersion(cached.version, newerThan: ClamshellVersion) {
        print("💡 Update available: \(cached.tagName) — Run 'sudo clamshell update' to upgrade.\n")
    }
}

func sendOrFallback(_ socketCmd: String, fallback: (inout ClamshellConfig) -> Void, successMessage: String) {
    if let resp = UnixSocketClient.send(socketCmd), UnixSocketClient.isSuccess(resp) {
        print("✅ \(successMessage)")
        return
    }
    var cfg = ConfigManager.shared.load()
    fallback(&cfg)
    if ConfigManager.shared.save(cfg) {
        print("✅ \(successMessage)")
    } else {
        print("⚠️ Could not write configuration. Try running with 'sudo' or install the daemon ('sudo clamshell install').")
    }
}

func handleAwake(args: [String]) {
    let sub = (args.first ?? "indefinite").lowercased()
    switch sub {
    case "indefinite", "always", "on", "24/7":
        sendOrFallback("MODE indefinite", fallback: { cfg in
            cfg.mode = .indefinite
            cfg.timedExpiresAtEpoch = nil
        }, successMessage: "Keep-Awake set to Indefinitely (24/7).")
    case "timed", "timer":
        let mins = (args.count >= 2 ? Int(args[1]) : nil) ?? 60
        let clamped = max(1, min(10080, mins))
        sendOrFallback("MODE timed \(clamped)", fallback: { cfg in
            cfg.mode = .timed
            cfg.timedDurationMinutes = clamped
            cfg.timedExpiresAtEpoch = Date().timeIntervalSince1970 + Double(clamped * 60)
        }, successMessage: "Keep-Awake set to Timed Session (\(clamped) minutes).")
    case "ac", "ac_only", "power":
        sendOrFallback("MODE ac_only", fallback: { cfg in
            cfg.mode = .acOnly
            cfg.timedExpiresAtEpoch = nil
        }, successMessage: "Keep-Awake set to AC Power Only.")
    case "off", "sleep", "normal", "disable":
        sendOrFallback("MODE off", fallback: { cfg in
            cfg.mode = .off
            cfg.timedExpiresAtEpoch = nil
        }, successMessage: "Keep-Awake disabled (Normal macOS sleep restored).")
    default:
        print("❌ Unknown mode '\(sub)'. Choose: indefinite, timed [minutes], ac, or off.")
        exit(1)
    }
}

func handleBrightness(args: [String]) {
    guard let first = args.first, let pct = Double(first), (0.0...100.0).contains(pct) else {
        print("❌ Usage: clamshell brightness <0-100>")
        exit(1)
    }
    _ = DisplayBacklightController.shared.setBrightness(pct / 100.0)
    sendOrFallback("BRIGHTNESS \(Int(pct.rounded()))", fallback: { cfg in
        if pct > 2.0 {
            cfg.savedBrightness = pct / 100.0
        }
    }, successMessage: pct == 0 ? "Display backlight turned completely OFF (0% blackout)." : "Display backlight set to \(Int(pct.rounded()))%.")
}

func handleBlackout(args: [String]) {
    guard let first = args.first?.lowercased() else {
        print("❌ Usage: clamshell blackout <on|off>")
        exit(1)
    }
    let enabled = ["on", "true", "1", "yes"].contains(first)
    sendOrFallback("BLACKOUT \(enabled ? "on" : "off")", fallback: { cfg in
        cfg.clamshellBlackoutEnabled = enabled
    }, successMessage: "Closed-clamshell display blackout \(enabled ? "ENABLED" : "DISABLED").")
}

func handleIdle(args: [String]) {
    guard let first = args.first?.lowercased() else {
        print("❌ Usage: clamshell idle <seconds|off>")
        exit(1)
    }
    let secs: Int
    if ["off", "0", "disable", "none"].contains(first) {
        secs = 0
    } else if let val = Int(first), (10...86400).contains(val) {
        secs = val
    } else {
        print("❌ Please specify idle timeout in seconds (10-86400) or 'off'.")
        exit(1)
    }
    sendOrFallback("IDLE \(secs)", fallback: { cfg in
        cfg.idleDimSeconds = secs
    }, successMessage: secs == 0 ? "Open-lid idle backlight timeout disabled." : "Open-lid idle backlight timeout set to \(secs)s.")
}

func handleFloor(args: [String]) {
    guard let first = args.first, let pct = Int(first), (5...80).contains(pct) else {
        print("❌ Usage: clamshell floor <5-80>")
        exit(1)
    }
    sendOrFallback("FLOOR \(pct)", fallback: { cfg in
        cfg.batteryFloorPercent = pct
    }, successMessage: "Battery safety floor set to \(pct)%.")
}

func handleDaemon() {
    print("🚀 Starting Clamshell Governor Daemon (clamshelld)...")
    let cfg = ConfigManager.shared.load()
    let governor = ClamshellGovernor(config: cfg)
    governor.start()
    activeGovernor = governor

    let server = UnixSocketServer(governor: governor)
    server.start()
    ipcServer = server
    print("🔌 Clamshell Unix Socket listening at \(UnixSocketServer.defaultSocketPath)")

    signal(SIGINT) { _ in
        activeGovernor?.stop()
        ipcServer?.stop()
        exit(0)
    }
    signal(SIGTERM) { _ in
        activeGovernor?.stop()
        ipcServer?.stop()
        exit(0)
    }

    RunLoop.main.run()
}

func handleInstall() {
    guard getuid() == 0 else {
        print("❌ Installation requires root privileges. Please run:\n   sudo clamshell install")
        exit(1)
    }

    let selfPath = CommandLine.arguments[0]
    let binSource: String
    if FileManager.default.isExecutableFile(atPath: selfPath) && !selfPath.hasSuffix("/clamshelld") {
        binSource = selfPath
    } else if FileManager.default.fileExists(atPath: ClamshellLayout.cliBinary) {
        binSource = ClamshellLayout.cliBinary
    } else {
        binSource = selfPath
    }

    let daemonBin = ClamshellLayout.daemonBinary
    try? FileManager.default.createDirectory(atPath: ClamshellLayout.supportDirectory, withIntermediateDirectories: true)

    guard SignedBinary.install(from: binSource, to: daemonBin) else {
        print("❌ Failed to install \(daemonBin)")
        exit(1)
    }
    SignedBinary.stripQuarantineAndSign(daemonBin)

    if !FileManager.default.fileExists(atPath: ClamshellLayout.cliBinary) {
        try? FileManager.default.createDirectory(atPath: ClamshellLayout.cliDirectory, withIntermediateDirectories: true)
        _ = SignedBinary.install(from: daemonBin, to: ClamshellLayout.cliBinary)
        SignedBinary.stripQuarantineAndSign(ClamshellLayout.cliBinary)
    }

    if !FileManager.default.fileExists(atPath: ClamshellLayout.systemConfigPath) {
        _ = ConfigManager.shared.save(ConfigManager.shared.load())
    }

    let plistPath = ClamshellLayout.daemonPlist
    let plistContent = ClamshellLayout.daemonPlistXML(program: daemonBin)

    for label in ClamshellLayout.daemonLabels {
        _ = Shell.run("/bin/launchctl", ["bootout", "system/\(label)"])
    }

    do {
        try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
        _ = Shell.run("/bin/chmod", ["644", plistPath])

        Thread.sleep(forTimeInterval: 0.2)
        _ = Shell.run("/bin/launchctl", ["bootstrap", "system", plistPath])
        _ = Shell.run("/bin/launchctl", ["kickstart", "-k", "system/\(ClamshellLayout.daemonLabel)"])

        print("✅ Clamshell LaunchDaemon installed and bootstrapped successfully!")
        print("   Daemon binary: \(daemonBin)")
        print("   CLI command:   \(ClamshellLayout.cliBinary)")
        print("   Plist:         \(plistPath)")
        print("   Logs:          \(ClamshellLayout.stdoutLog)")
    } catch {
        print("❌ Failed to install LaunchDaemon: \(error.localizedDescription)")
        exit(1)
    }
}

func handleUninstall() {
    guard getuid() == 0 else {
        print("❌ Uninstallation requires root privileges. Please run:\n   sudo clamshell uninstall")
        exit(1)
    }

    let cfg = ConfigManager.shared.load()
    _ = Shell.run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
    _ = DisplayBacklightController.shared.setBrightness(cfg.savedBrightness)

    for label in ClamshellLayout.daemonLabels {
        _ = Shell.run("/bin/launchctl", ["bootout", "system/\(label)"])
    }

    try? FileManager.default.removeItem(atPath: ClamshellLayout.daemonPlist)
    try? FileManager.default.removeItem(atPath: ClamshellLayout.supportDirectory)
    try? FileManager.default.removeItem(atPath: ClamshellLayout.socketPath)
    print("✅ Clamshell LaunchDaemon uninstalled and normal sleep restored.")
}

func handleUpdate(args: [String]) {
    let checkOnly = args.contains("--check")
    let force = args.contains("--force")

    print("🔍 Checking GitHub for updates (current version: v\(VERSION))...")

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        guard let info = await UpdateChecker.checkForUpdate(currentVersion: VERSION, force: true) else {
            print("⚠️ Could not fetch update information from GitHub.")
            return
        }

        if !info.isNewer && !force {
            print("✅ Clamshell is already up to date! (v\(VERSION))")
            return
        }

        print("""
        ========================================================================
        ⬆️  New version available: \(info.tagName) (Current: v\(VERSION))
        ========================================================================
        \(info.releaseNotes.isEmpty ? "Latest release available on GitHub." : info.releaseNotes)
        ========================================================================
        """)

        if checkOnly {
            print("Run 'sudo clamshell update' to install.")
            return
        }

        if getuid() != 0 {
            let appPath = ClamshellLayout.appBundle
            let appWritable = FileManager.default.isWritableFile(atPath: appPath) || FileManager.default.isWritableFile(atPath: "/Applications")
            let socketActive = FileManager.default.fileExists(atPath: ClamshellLayout.socketPath)
            if appWritable && socketActive && !info.dmgUrl.isEmpty, let dmgUrl = URL(string: info.dmgUrl) {
                do {
                    try await UpdateChecker.installAppUpdate(dmgUrl: dmgUrl, relaunch: false) { step in
                        print("   → \(step)")
                    }
                    print("✅ Clamshell successfully updated to \(info.tagName)!")
                    return
                } catch {
                    print("⚠️ Non-root update could not complete: \(error.localizedDescription)")
                }
            }
            print("❌ Root privileges required to install update. Please run:\n   sudo clamshell update")
            exit(1)
        }

        do {
            if let binUrl = URL(string: info.binaryUrl) {
                try await UpdateChecker.installCLIUpdate(binaryUrl: binUrl) { step in
                    print("   → \(step)")
                }
            }
            if FileManager.default.fileExists(atPath: ClamshellLayout.appBundle),
               let dmgUrl = URL(string: info.dmgUrl) {
                try await UpdateChecker.installAppUpdate(dmgUrl: dmgUrl, relaunch: false) { step in
                    print("   → \(step)")
                }
            }
            print("✅ Clamshell successfully updated to \(info.tagName)!")
        } catch {
            print("❌ Update failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    semaphore.wait()
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
let cmd = (rawArgs.first ?? "status").lowercased()
let subArgs = Array(rawArgs.dropFirst())

switch cmd {
case "status", "info":
    handleStatus(jsonOutput: subArgs.contains("--json") || subArgs.contains("-j"))
case "awake", "mode", "keepawake":
    handleAwake(args: subArgs)
case "brightness", "bright", "dim":
    handleBrightness(args: subArgs)
case "brightness-sync":
    if let first = subArgs.first, let val = Double(first) {
        _ = DisplayBacklightController.shared.setBrightnessDirect(val)
    }
case "blackout", "lid":
    handleBlackout(args: subArgs)
case "idle":
    handleIdle(args: subArgs)
case "floor", "battery":
    handleFloor(args: subArgs)
case "daemon":
    handleDaemon()
case "install":
    handleInstall()
case "uninstall":
    handleUninstall()
case "update", "upgrade":
    handleUpdate(args: subArgs)
case "version", "-v", "--version":
    print("Clamshell v\(VERSION)")
case "help", "-h", "--help":
    printHelp()
default:
    print("❌ Unknown command: \(cmd)\n")
    printHelp()
    exit(1)
}
