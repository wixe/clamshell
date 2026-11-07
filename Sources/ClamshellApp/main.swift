import AppKit
import Foundation
import ClamshellCore

final class LinkButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
final class ClamshellAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var lidObserverTimer: Timer?
    private var settingsWindow: NSWindow?

    // Settings window controls
    private var lidStateLabel: NSTextField?
    private var governorLabel: NSTextField?
    private var telemetryLabel: NSTextField?
    private var powerDetailLabel: NSTextField?
    private var daemonBadgeLabel: NSTextField?
    private var headerSubLabel: NSTextField?
    private let graphView = TelemetryGraphView(frame: NSRect(x: 12, y: 12, width: 168, height: 180))
    private var modeSegment: NSSegmentedControl?
    private var brightnessSlider: NSSlider?
    private var brightnessValueLabel: NSTextField?
    private var blackoutCheckbox: NSButton?
    private var muteSpeakersCheckbox: NSButton?
    private var idlePopup: NSPopUpButton?
    private var loginCheckbox: NSButton?
    private var installDaemonButton: NSButton?
    private var uninstallDaemonButton: NSButton?

    // Update controls
    private var latestRelease: ReleaseInfo?
    private var isUpdatingApp: Bool = false
    private var isAutoSyncingDaemon: Bool = false
    private var menuIsOpen = false
    private var replacingMenu = false
    private var lastAutoSyncAttempt = Date.distantPast
    private var updateStatusText: String = ""
    private var updateLabel: NSTextField?
    private var updateSubLabel: NSTextField?
    private var updateActionButton: NSButton?

    private let monitor = HardwareMonitor()
    private let inAppPower = PowerAssertionController()
    private var lastObservedClosed: Bool? = nil
    private var lastObservedIdleBlackout: Bool = false
    private var wasSpeakerMutedByApp: Bool = false

    private let launchAgentPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClamshellLayout.launchAgentPath(home: home)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🦪 Clamshell"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }

        if Bundle.main.bundlePath.hasPrefix("/Applications") && !FileManager.default.fileExists(atPath: launchAgentPath) {
            setLaunchAtLogin(true)
        }

        evaluateLocalSessionGuard()
        rebuildMenu()
        autoSyncDaemonIfNeeded()

        Task {
            await checkUpdateSilently()
        }

        if !CommandLine.arguments.contains("--background") {
            showSettingsWindow()
        }

        // Fast 1s observer for instant lid open/close backlight response in GUI session
        lidObserverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateLocalSessionGuard()
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.autoSyncDaemonIfNeeded()
                self?.rebuildMenu()
                self?.refreshSettingsWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    /// Ensures responsive in-session display backlight switching on lid open/close
    /// and maintains user-space IOPMAssertions even before the root daemon is installed.
    private func evaluateLocalSessionGuard() {
        let tel = monitor.readTelemetry()
        var cfg = ConfigManager.shared.load()
        let daemonInfo = fetchDaemonStatus()

        if !daemonInfo.running {
            let batterySafe = tel.isACConnected || tel.batteryPercent > cfg.batteryFloorPercent
            let wantAwake: Bool
            switch cfg.mode {
            case .indefinite, .timed: wantAwake = batterySafe
            case .acOnly: wantAwake = batterySafe && tel.isACConnected
            case .off: wantAwake = false
            }
            inAppPower.setAwakeAssertions(
                systemAwake: wantAwake,
                displayWindowServerAwake: wantAwake && cfg.preventDisplaySleep
            )
        }

        let prevClosed = lastObservedClosed
        lastObservedClosed = tel.isClamshellClosed

        if tel.isClamshellClosed {
            if cfg.muteSpeakersWhenClosed {
                if !tel.builtInSpeakersMuted {
                    _ = AudioOutputController.shared.setBuiltInSpeakersMutedDirect(true)
                }
                wasSpeakerMutedByApp = true
            }
            if cfg.clamshellBlackoutEnabled {
                if prevClosed == false && tel.currentBrightness > 0.03 {
                    cfg.savedBrightness = tel.currentBrightness
                    _ = ConfigManager.shared.save(cfg)
                }
                if tel.currentBrightness > 0.005 {
                    _ = DisplayBacklightController.shared.setBrightnessDirect(0.0)
                }
            }
        } else if prevClosed == true {
            // Clamshell just opened — restore saved brightness and unmute built-in speakers immediately!
            lastObservedIdleBlackout = false
            let restore = max(0.10, min(1.0, cfg.savedBrightness))
            _ = DisplayBacklightController.shared.setBrightnessDirect(restore)
            if cfg.muteSpeakersWhenClosed && wasSpeakerMutedByApp {
                _ = AudioOutputController.shared.setBuiltInSpeakersMutedDirect(false)
                wasSpeakerMutedByApp = false
            }
            rebuildMenu()
            refreshSettingsWindow()
        } else if cfg.idleDimSeconds > 0 && tel.hidIdleSeconds >= Double(cfg.idleDimSeconds) {
            if !lastObservedIdleBlackout {
                if tel.currentBrightness > 0.03 {
                    cfg.savedBrightness = tel.currentBrightness
                    _ = ConfigManager.shared.save(cfg)
                }
                _ = DisplayBacklightController.shared.setBrightnessDirect(0.0)
                lastObservedIdleBlackout = true
            }
        } else if lastObservedIdleBlackout && tel.hidIdleSeconds < 3.0 {
            lastObservedIdleBlackout = false
            let restore = max(0.10, min(1.0, cfg.savedBrightness))
            _ = DisplayBacklightController.shared.setBrightnessDirect(restore)
            rebuildMenu()
            refreshSettingsWindow()
        }

        updateMenuBarTitleOnly(telemetry: tel, config: cfg)
    }

    private func fetchDaemonStatus() -> (running: Bool, mode: String, version: String?, remainingSec: Int?) {
        if let liveJson = UnixSocketClient.send("STATUS"),
           let data = liveJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let gov = obj["governor"] as? [String: Any],
           let mode = gov["mode"] as? String {
            let version = gov["version"] as? String
            let rem = gov["remaining_timed_seconds"] as? Int
            return (true, mode, version, rem)
        }
        return (false, "In-App Session Mode (Daemon Not Installed)", nil, nil)
    }

    private func rebuildMenu() {
        guard !menuIsOpen else { return }
        replacingMenu = true
        defer { replacingMenu = false }

        let tel = monitor.readTelemetry()
        let cfg = ConfigManager.shared.load()
        let daemonInfo = fetchDaemonStatus()
        let daemonActive = daemonInfo.running
        let brightPct = Int((tel.currentBrightness * 100.0).rounded())
        let savedPct = Int((cfg.savedBrightness * 100.0).rounded())

        updateMenuBarTitleOnly(telemetry: tel, config: cfg)
        graphView.addSample(
            brightnessPercent: Double(brightPct),
            isClamshellClosed: tel.isClamshellClosed,
            isAwake: cfg.mode != .off
        )

        let menu = NSMenu()
        menu.delegate = self

        if let rel = latestRelease, UpdateChecker.isVersion(rel.version, newerThan: ClamshellVersion) {
            let updateItem = NSMenuItem(title: "⬆️ Update Available (\(rel.tagName))…", action: #selector(triggerAppUpdate), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        } else {
            let latestItem = NSMenuItem(title: "Clamshell \(ClamshellVersion)", action: nil, keyEquivalent: "")
            latestItem.isEnabled = false
            menu.addItem(latestItem)
        }

        let lidStateStr = tel.isClamshellClosed ? "Closed (Server Mode)" : "Open (Interactive Mode)"
        let powerStr = tel.isCharging ? "AC Charging" : (tel.isACConnected ? "AC Connected" : "On Battery")
        let idleStr = tel.hidIdleSeconds < 60
            ? String(format: "%.0fs", tel.hidIdleSeconds)
            : String(format: "%dm %ds", Int(tel.hidIdleSeconds) / 60, Int(tel.hidIdleSeconds) % 60)

        let speakerInfoStr = tel.builtInSpeakersMuted
            ? "Muted 🔇 (Remote/Virtual Audio Active)"
            : "Unmuted 🔊 (Output: \(tel.audioOutputDeviceName))"

        let infoLines = [
            "Clamshell Lid: \(lidStateStr)",
            "Display Backlight: \(brightPct)% (Saved Open-Lid: \(savedPct)%)",
            "Built-in Speakers: \(speakerInfoStr)",
            "WindowServer GPU: \(tel.displayOnline ? "Online" : "Offline") (\(tel.displayResolution))",
            "Keep-Awake Mode: \(daemonInfo.mode)",
            "Power & Battery: \(tel.batteryPercent)% (\(powerStr)) • Floor: \(cfg.batteryFloorPercent)%",
            "Input Idle Time: \(idleStr) • Thermal: \(tel.thermalState)",
            "Kernel Sleep Lock: \(tel.sleepDisabledKernel ? "Active (SleepDisabled=1)" : "Standard")"
        ]

        let readingsMenu = NSMenu()
        for line in infoLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            readingsMenu.addItem(item)
        }
        let iconPrefix = menuBarSymbol(telemetry: tel, config: cfg)
        let readingsRoot = NSMenuItem(
            title: "\(iconPrefix) Lid \(tel.isClamshellClosed ? "Closed" : "Open") · \(brightPct)% LCD · \(cfg.mode.shortLabel)",
            action: nil,
            keyEquivalent: ""
        )
        readingsRoot.submenu = readingsMenu
        menu.addItem(readingsRoot)

        // Keep-Awake Mode Submenu (Amphetamine Replacement)
        let awakeMenu = NSMenu()
        let modeItems: [(String, Selector, Int, Bool)] = [
            ("☕ Awake Indefinitely (24/7)", #selector(selectIndefiniteMode), 0, cfg.mode == .indefinite),
            ("🔌 Awake on AC Power Only", #selector(selectACOnlyMode), 0, cfg.mode == .acOnly),
            ("⏱️ Timed: 30 Minutes", #selector(selectTimedPreset(_:)), 30, cfg.mode == .timed && cfg.timedDurationMinutes == 30),
            ("⏱️ Timed: 1 Hour", #selector(selectTimedPreset(_:)), 60, cfg.mode == .timed && cfg.timedDurationMinutes == 60),
            ("⏱️ Timed: 2 Hours", #selector(selectTimedPreset(_:)), 120, cfg.mode == .timed && cfg.timedDurationMinutes == 120),
            ("⏱️ Timed: 4 Hours", #selector(selectTimedPreset(_:)), 240, cfg.mode == .timed && cfg.timedDurationMinutes == 240),
            ("⏱️ Timed: 8 Hours", #selector(selectTimedPreset(_:)), 480, cfg.mode == .timed && cfg.timedDurationMinutes == 480),
            ("⏱️ Timed: 12 Hours", #selector(selectTimedPreset(_:)), 720, cfg.mode == .timed && cfg.timedDurationMinutes == 720),
            ("🌙 Off (Allow Normal macOS Sleep)", #selector(selectOffMode), 0, cfg.mode == .off)
        ]
        for (title, sel, tag, isOn) in modeItems {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = isOn ? .on : .off
            awakeMenu.addItem(item)
        }
        let awakeRoot = NSMenuItem(title: "Keep-Awake: \(cfg.mode.shortLabel)", action: nil, keyEquivalent: "")
        awakeRoot.submenu = awakeMenu
        menu.addItem(awakeRoot)

        // Display Backlight Submenu
        let brightMenu = NSMenu()
        let brightPresets: [(Int, String)] = [
            (0, "🌑 0% — Turn Backlight Off (Blackout)"),
            (25, "🔅 25% — Low Brightness"),
            (50, "🔆 50% — Medium Brightness"),
            (65, "🔆 65% — Studio Default"),
            (80, "☀️ 80% — High Brightness"),
            (100, "☀️ 100% — Maximum Brightness")
        ]
        for (pct, label) in brightPresets {
            let item = NSMenuItem(title: label, action: #selector(selectBrightnessPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            item.state = (abs(brightPct - pct) <= 4) ? .on : .off
            brightMenu.addItem(item)
        }
        let brightRoot = NSMenuItem(title: "Display Backlight: \(brightPct)%", action: nil, keyEquivalent: "")
        brightRoot.submenu = brightMenu
        menu.addItem(brightRoot)

        menu.addItem(.separator())

        // Clamshell & Idle Blackout Policy Submenu
        let policyMenu = NSMenu()
        let lidBlackoutItem = NSMenuItem(
            title: "Turn Display Off When Clamshell Closed (0% Backlight)",
            action: #selector(toggleClamshellBlackoutMenu),
            keyEquivalent: ""
        )
        lidBlackoutItem.target = self
        lidBlackoutItem.state = cfg.clamshellBlackoutEnabled ? .on : .off
        policyMenu.addItem(lidBlackoutItem)

        let lidMuteItem = NSMenuItem(
            title: "Mute Built-in Speakers When Clamshell Closed (Keep Remote Audio)",
            action: #selector(toggleMuteSpeakersMenu),
            keyEquivalent: ""
        )
        lidMuteItem.target = self
        lidMuteItem.state = cfg.muteSpeakersWhenClosed ? .on : .off
        policyMenu.addItem(lidMuteItem)
        policyMenu.addItem(.separator())

        let idleOptions: [(Int, String)] = [
            (0, "Open-Lid Idle Blackout: Disabled"),
            (120, "Open-Lid Idle Blackout: After 2 Minutes"),
            (300, "Open-Lid Idle Blackout: After 5 Minutes"),
            (600, "Open-Lid Idle Blackout: After 10 Minutes"),
            (900, "Open-Lid Idle Blackout: After 15 Minutes"),
            (1800, "Open-Lid Idle Blackout: After 30 Minutes")
        ]
        for (secs, title) in idleOptions {
            let item = NSMenuItem(title: title, action: #selector(selectIdleTimeoutMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = secs
            item.state = (cfg.idleDimSeconds == secs) ? .on : .off
            policyMenu.addItem(item)
        }
        let policyTitle = cfg.clamshellBlackoutEnabled ? "Clamshell Blackout: Enabled" : "Clamshell Blackout: Off"
        let policyRoot = NSMenuItem(title: policyTitle, action: nil, keyEquivalent: "")
        policyRoot.submenu = policyMenu
        menu.addItem(policyRoot)

        // Status Icon Legend Submenu
        let legendMenu = NSMenu()
        let legendItems = [
            ("🦪", "Closed Awake", "Clamshell closed, system awake, 0% display backlight"),
            ("☕", "Open Awake", "Clamshell open, sleep prevented, interactive brightness"),
            ("⏱️", "Timed Awake", "Keep-awake countdown timer active"),
            ("🌙", "Sleep Allowed", "Normal macOS sleep behavior active")
        ]
        for (icon, title, desc) in legendItems {
            let item = NSMenuItem(title: "\(icon)  \(title) — \(desc)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            legendMenu.addItem(item)
        }
        let legendRoot = NSMenuItem(title: "Status Icon Legend", action: nil, keyEquivalent: "")
        legendRoot.submenu = legendMenu
        menu.addItem(legendRoot)

        menu.addItem(.separator())

        let openSettingsItem = NSMenuItem(title: "Open Clamshell Settings & Installer…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)

        let checkUpdateItem = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

        let loginItem = NSMenuItem(title: "Start Menu Bar Icon at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        if !daemonActive {
            let installItem = NSMenuItem(title: "⚠️ Enable Background Daemon (clamshelld)…", action: #selector(installDaemonAction), keyEquivalent: "")
            installItem.target = self
            menu.addItem(installItem)
        } else if !isDaemonBinaryUpToDate(runningDaemonVersion: daemonInfo.version) {
            let updateItem = NSMenuItem(title: "⚠️ Update Background Daemon…", action: #selector(installDaemonAction), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
            let uninstallItem = NSMenuItem(title: "Uninstall Background Daemon…", action: #selector(uninstallDaemonAction), keyEquivalent: "")
            uninstallItem.target = self
            menu.addItem(uninstallItem)
        } else {
            let restartItem = NSMenuItem(title: "Restart Background Daemon", action: #selector(installDaemonAction), keyEquivalent: "")
            restartItem.target = self
            menu.addItem(restartItem)
            let uninstallItem = NSMenuItem(title: "Uninstall Background Daemon…", action: #selector(uninstallDaemonAction), keyEquivalent: "")
            uninstallItem.target = self
            menu.addItem(uninstallItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Clamshell Menu Bar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if !replacingMenu {
            rebuildMenu()
        }
    }

    @objc private func openProjectPage(_ sender: Any?) {
        NSWorkspace.shared.open(ClamshellLayout.projectURL)
    }

    private func placeSettingsWindowOnScreen() {
        guard let win = settingsWindow else { return }
        guard let screen = win.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = win.frame
        frame.size.width = min(frame.width, visible.width - 12)
        frame.size.height = min(frame.height, visible.height - 12)
        frame.origin.x = floor(visible.midX - frame.width / 2)
        frame.origin.y = floor(visible.midY - frame.height / 2)
        win.setFrame(frame, display: true)
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil {
            let unit: CGFloat = 6
            let margin = unit * 3
            let gutter = unit * 2
            let graphColW = unit * 32
            let controlW = graphColW * 2
            let innerW = graphColW + gutter + controlW
            let width = innerW + margin * 2
            let titleH = unit * 4
            let subH = unit * 4
            let badgeH = unit * 6
            let telBoxH = unit * 20
            let graphBoxH = unit * 44
            let legendBoxH = unit * 21
            let columnH = graphBoxH + gutter + legendBoxH
            let controlX = margin
            let graphX = margin + controlW + gutter

            var cursor = margin
            let columnsY = cursor
            cursor += columnH + gutter
            let telY = cursor
            cursor += telBoxH + gutter
            let badgeY = cursor
            cursor += badgeH + unit
            let subY = cursor
            cursor += subH + unit
            let titleY = cursor
            cursor += titleH + margin
            let height = cursor
            let columnTop = columnsY + columnH

            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Clamshell Settings"
            win.isReleasedWhenClosed = false
            win.delegate = self

            let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            win.contentView = content

            let linkW = unit * 36
            let title = NSTextField(labelWithString: "🦪 Clamshell Display & Keep-Awake Governor")
            title.font = NSFont.boldSystemFont(ofSize: 16)
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: margin, y: titleY, width: innerW - linkW - gutter, height: titleH)
            content.addSubview(title)

            let projectLink = LinkButton(title: ClamshellLayout.projectLinkTitle, target: self, action: #selector(openProjectPage(_:)))
            projectLink.isBordered = false
            projectLink.attributedTitle = NSAttributedString(
                string: ClamshellLayout.projectLinkTitle,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
            projectLink.alignment = .right
            projectLink.frame = NSRect(x: margin + innerW - linkW, y: titleY, width: linkW, height: titleH)
            content.addSubview(projectLink)

            let sub = NSTextField(labelWithString: "")
            sub.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            sub.textColor = .secondaryLabelColor
            sub.frame = NSRect(x: margin, y: subY, width: innerW, height: subH)
            content.addSubview(sub)
            self.headerSubLabel = sub

            let daemonBadge = NSTextField(labelWithString: "")
            daemonBadge.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            daemonBadge.frame = NSRect(x: margin, y: badgeY, width: innerW, height: badgeH)
            content.addSubview(daemonBadge)
            self.daemonBadgeLabel = daemonBadge

            let telBox = NSBox(frame: NSRect(x: margin, y: telY, width: innerW, height: telBoxH))
            telBox.title = "Live Clamshell, Backlight & Keep-Awake Telemetry"
            telBox.contentViewMargins = NSSize(width: unit, height: unit)
            content.addSubview(telBox)
            let telBounds = telBox.contentView?.bounds ?? .zero
            let rowH = unit * 4
            let rowW = telBounds.width - unit * 2
            let rowY = (0..<4).map { telBounds.height - rowH * CGFloat($0 + 1) }

            let lLabel = NSTextField(labelWithString: "")
            lLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            lLabel.frame = NSRect(x: unit, y: rowY[0], width: rowW, height: rowH)
            telBox.contentView?.addSubview(lLabel)
            self.lidStateLabel = lLabel

            let gLabel = NSTextField(labelWithString: "")
            gLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            gLabel.frame = NSRect(x: unit, y: rowY[1], width: rowW, height: rowH)
            telBox.contentView?.addSubview(gLabel)
            self.governorLabel = gLabel

            let tLabel = NSTextField(labelWithString: "")
            tLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            tLabel.textColor = .secondaryLabelColor
            tLabel.frame = NSRect(x: unit, y: rowY[2], width: rowW, height: rowH)
            telBox.contentView?.addSubview(tLabel)
            self.telemetryLabel = tLabel

            let pLabel = NSTextField(labelWithString: "")
            pLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            pLabel.textColor = .secondaryLabelColor
            pLabel.frame = NSRect(x: unit, y: rowY[3], width: rowW, height: rowH)
            telBox.contentView?.addSubview(pLabel)
            self.powerDetailLabel = pLabel

            let graphBox = NSBox(frame: NSRect(x: graphX, y: columnsY + legendBoxH + gutter, width: graphColW, height: graphBoxH))
            graphBox.title = "Backlight History"
            graphBox.contentViewMargins = NSSize(width: unit, height: unit)
            content.addSubview(graphBox)
            let graphW = unit * 28
            let graphH = unit * 38
            graphView.frame = NSRect(x: unit, y: unit, width: graphW, height: graphH)
            if graphView.superview == nil {
                graphBox.contentView?.addSubview(graphView)
            }

            let legendBox = NSBox(frame: NSRect(x: graphX, y: columnsY, width: graphColW, height: legendBoxH))
            legendBox.title = "Operating Modes"
            legendBox.contentViewMargins = NSSize(width: unit, height: unit)
            content.addSubview(legendBox)
            let legendBounds = legendBox.contentView?.bounds ?? .zero
            let legendRowH = unit * 5
            let legendRowW = legendBounds.width - unit * 2
            let legendRowY = (0..<3).map { legendBounds.height - legendRowH * CGFloat($0 + 1) - unit * CGFloat($0) }

            let leg1 = NSTextField(labelWithString: "🦪 Closed Awake\nServer awake, 0% backlight")
            leg1.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            leg1.cell?.wraps = true
            leg1.frame = NSRect(x: unit, y: legendRowY[0], width: legendRowW, height: legendRowH)
            legendBox.contentView?.addSubview(leg1)

            let leg2 = NSTextField(labelWithString: "☕ Open Awake\nLid open, adjustable LCD")
            leg2.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            leg2.cell?.wraps = true
            leg2.frame = NSRect(x: unit, y: legendRowY[1], width: legendRowW, height: legendRowH)
            legendBox.contentView?.addSubview(leg2)

            let leg3 = NSTextField(labelWithString: "🌙 Normal Sleep\nStandard macOS sleep")
            leg3.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            leg3.cell?.wraps = true
            leg3.frame = NSRect(x: unit, y: legendRowY[2], width: legendRowW, height: legendRowH)
            legendBox.contentView?.addSubview(leg3)

            let cfg = ConfigManager.shared.load()
            let tel = monitor.readTelemetry()
            let curBrightPct = Int((tel.currentBrightness * 100.0).rounded())

            var down = columnTop
            down -= unit * 4
            let modeTitleY = down
            down -= unit * 5
            let modeSegY = down
            down -= unit * 5
            let brightTitleY = down
            down -= unit * 5
            let sliderY = down
            down -= unit * 5
            let blackoutY = down
            down -= unit * 4
            let muteY = down
            down -= unit * 5
            let idleY = down
            down -= unit * 5
            let loginY = down
            down -= unit * 17
            let updateY = down
            down -= unit * 6
            let buttonY = down

            let modeTitle = NSTextField(labelWithString: "Keep-Awake Mode (Replaces Amphetamine)")
            modeTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            modeTitle.frame = NSRect(x: controlX, y: modeTitleY, width: controlW, height: unit * 4)
            content.addSubview(modeTitle)

            let seg = NSSegmentedControl(
                labels: ["24/7 Awake", "AC Power Only", "Timed (1h)", "Off (Sleep)"],
                trackingMode: .selectOne,
                target: self,
                action: #selector(modeSegmentChanged(_:))
            )
            seg.frame = NSRect(x: controlX, y: modeSegY, width: controlW, height: unit * 5)
            content.addSubview(seg)
            self.modeSegment = seg

            let sliderTitle = NSTextField(labelWithString: "Display Backlight Brightness")
            sliderTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            sliderTitle.frame = NSRect(x: controlX, y: brightTitleY, width: controlW - unit * 12, height: unit * 4)
            content.addSubview(sliderTitle)

            let valLabel = NSTextField(labelWithString: "\(curBrightPct)%")
            valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            valLabel.alignment = .right
            valLabel.frame = NSRect(x: controlX + controlW - unit * 12, y: brightTitleY, width: unit * 12, height: unit * 4)
            content.addSubview(valLabel)
            self.brightnessValueLabel = valLabel

            let blackoutBtnW = unit * 18
            let slider = NSSlider(
                value: Double(curBrightPct),
                minValue: 0,
                maxValue: 100,
                target: self,
                action: #selector(brightnessSliderChanged(_:))
            )
            slider.isContinuous = true
            slider.frame = NSRect(x: controlX, y: sliderY, width: controlW - blackoutBtnW - gutter, height: unit * 5)
            content.addSubview(slider)
            self.brightnessSlider = slider

            let zeroBtn = NSButton(title: "0% Blackout", target: self, action: #selector(blackoutNowButtonClicked))
            zeroBtn.bezelStyle = .rounded
            zeroBtn.controlSize = .small
            zeroBtn.frame = NSRect(x: controlX + controlW - blackoutBtnW, y: sliderY, width: blackoutBtnW, height: unit * 5)
            content.addSubview(zeroBtn)

            let bCheck = NSButton(
                checkboxWithTitle: "Turn display completely off (0%) when clamshell is closed, restore when opened",
                target: self,
                action: #selector(toggleBlackoutCheckbox(_:))
            )
            bCheck.state = cfg.clamshellBlackoutEnabled ? .on : .off
            bCheck.controlSize = .small
            bCheck.frame = NSRect(x: controlX, y: blackoutY, width: controlW, height: unit * 4)
            content.addSubview(bCheck)
            self.blackoutCheckbox = bCheck

            let mCheck = NSButton(
                checkboxWithTitle: "Mute built-in MacBook speakers when clamshell is closed (keeps Screen Sharing / AirPlay audio)",
                target: self,
                action: #selector(toggleMuteSpeakersCheckbox(_:))
            )
            mCheck.state = cfg.muteSpeakersWhenClosed ? .on : .off
            mCheck.controlSize = .small
            mCheck.frame = NSRect(x: controlX, y: muteY, width: controlW, height: unit * 4)
            content.addSubview(mCheck)
            self.muteSpeakersCheckbox = mCheck

            let idleLabel = NSTextField(labelWithString: "Open-lid idle backlight off:")
            idleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            idleLabel.frame = NSRect(x: controlX, y: idleY, width: unit * 30, height: unit * 4)
            content.addSubview(idleLabel)

            let popup = NSPopUpButton(frame: NSRect(x: controlX + unit * 30, y: idleY - 2, width: unit * 28, height: unit * 4 + 4), pullsDown: false)
            popup.controlSize = .small
            popup.font = NSFont.systemFont(ofSize: 11)
            let popupOptions: [(Int, String)] = [
                (0, "Never (Disabled)"),
                (120, "After 2 Minutes"),
                (300, "After 5 Minutes"),
                (600, "After 10 Minutes"),
                (900, "After 15 Minutes"),
                (1800, "After 30 Minutes")
            ]
            for (secs, label) in popupOptions {
                popup.addItem(withTitle: label)
                popup.lastItem?.tag = secs
            }
            popup.target = self
            popup.action = #selector(idlePopupChanged(_:))
            content.addSubview(popup)
            self.idlePopup = popup

            let loginCheck = NSButton(checkboxWithTitle: "Show the Clamshell menu bar icon at login", target: self, action: #selector(toggleLaunchAtLogin))
            loginCheck.state = isLaunchAtLoginEnabled() ? .on : .off
            loginCheck.controlSize = .small
            loginCheck.frame = NSRect(x: controlX, y: loginY, width: controlW, height: unit * 4)
            content.addSubview(loginCheck)
            self.loginCheckbox = loginCheck

            let uBox = NSBox(frame: NSRect(x: controlX, y: updateY, width: controlW, height: unit * 16))
            uBox.title = "Software Updates"
            uBox.contentViewMargins = NSSize(width: unit, height: unit)
            content.addSubview(uBox)
            let updateBounds = uBox.contentView?.bounds ?? .zero
            let updateBtnW = unit * 20

            let uLabel = NSTextField(labelWithString: "Clamshell v\(ClamshellVersion)")
            uLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            uLabel.frame = NSRect(x: unit, y: updateBounds.height - unit * 5, width: updateBounds.width - updateBtnW - unit * 3, height: unit * 4)
            uBox.contentView?.addSubview(uLabel)
            self.updateLabel = uLabel

            let uSub = NSTextField(labelWithString: "You are on the latest version.")
            uSub.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            uSub.textColor = .secondaryLabelColor
            uSub.frame = NSRect(x: unit, y: unit * 2, width: updateBounds.width - updateBtnW - unit * 3, height: unit * 4)
            uBox.contentView?.addSubview(uSub)
            self.updateSubLabel = uSub

            let uBtn = NSButton(title: "Check Updates", target: self, action: #selector(updateActionButtonClicked))
            uBtn.bezelStyle = .rounded
            uBtn.controlSize = .small
            uBtn.frame = NSRect(x: updateBounds.width - updateBtnW - unit, y: unit * 3, width: updateBtnW, height: unit * 6)
            uBox.contentView?.addSubview(uBtn)
            self.updateActionButton = uBtn

            let buttonW = (controlW - gutter) / 2
            let installBtn = NSButton(title: "Install Daemon", target: self, action: #selector(installDaemonAction))
            installBtn.bezelStyle = .rounded
            installBtn.controlSize = .small
            installBtn.frame = NSRect(x: controlX, y: buttonY, width: buttonW, height: unit * 5)
            content.addSubview(installBtn)
            self.installDaemonButton = installBtn

            let uninstallBtn = NSButton(title: "Uninstall Daemon", target: self, action: #selector(uninstallDaemonAction))
            uninstallBtn.bezelStyle = .rounded
            uninstallBtn.controlSize = .small
            uninstallBtn.frame = NSRect(x: controlX + buttonW + gutter, y: buttonY, width: buttonW, height: unit * 5)
            content.addSubview(uninstallBtn)
            self.uninstallDaemonButton = uninstallBtn

            self.settingsWindow = win
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        refreshSettingsWindow()
        placeSettingsWindowOnScreen()
    }

    private func refreshSettingsWindow() {
        guard let win = settingsWindow, win.isVisible, !win.isMiniaturized else { return }
        let tel = monitor.readTelemetry()
        let cfg = ConfigManager.shared.load()
        let daemonInfo = fetchDaemonStatus()
        let daemonActive = daemonInfo.running
        let upToDate = isDaemonBinaryUpToDate(runningDaemonVersion: daemonInfo.version)
        let brightPct = Int((tel.currentBrightness * 100.0).rounded())
        let savedPct = Int((cfg.savedBrightness * 100.0).rounded())

        let speakerStatus = tel.builtInSpeakersMuted ? "Muted 🔇" : "Unmuted 🔊"
        headerSubLabel?.stringValue = "Lid: \(tel.isClamshellClosed ? "Closed 🦪" : "Open 💻")  •  Backlight: \(brightPct)%  •  Speakers: \(speakerStatus)  •  WindowServer: \(tel.displayOnline ? "Online" : "Offline") (\(tel.displayResolution))"

        if daemonActive && upToDate {
            daemonBadgeLabel?.stringValue = "✅ Background Daemon (clamshelld) Active — Closed-Clamshell Awake & Backlight Guard Enforced"
            daemonBadgeLabel?.textColor = .systemGreen
            installDaemonButton?.title = "Restart Daemon"
        } else if daemonActive && !upToDate {
            daemonBadgeLabel?.stringValue = "⚠️ Daemon Update Available — Click 'Update Daemon' below"
            daemonBadgeLabel?.textColor = .systemOrange
            installDaemonButton?.title = "Update Daemon"
        } else {
            daemonBadgeLabel?.stringValue = "ℹ️ Running in Menu Bar Mode — Install Background Daemon for closed-lid kernel sleep prevention"
            daemonBadgeLabel?.textColor = .systemOrange
            installDaemonButton?.title = "Install Daemon"
        }

        lidStateLabel?.stringValue = "Clamshell: \(tel.isClamshellClosed ? "🦪 CLOSED (0% Backlight Server Mode)" : "💻 OPEN (Interactive Mode)")  •  LCD Brightness: \(brightPct)%"
        governorLabel?.stringValue = "Keep-Awake Mode: \(daemonInfo.mode)  •  Kernel SleepDisabled: \(tel.sleepDisabledKernel ? "Yes (Awake)" : "No")"
        let idleStr = String(format: "%.0fs", tel.hidIdleSeconds)
        telemetryLabel?.stringValue = "Display: \(tel.displayResolution) (\(tel.displayOnline ? "GPU Online" : "Offline"))  •  Input Idle: \(idleStr)  •  Open-Lid Auto-Off: \(cfg.idleDimSeconds > 0 ? "\(cfg.idleDimSeconds / 60)m" : "Off")"
        let pwrStr = tel.isCharging ? "⚡ Charging" : (tel.isACConnected ? "🔌 AC Connected" : "🔋 On Battery")
        powerDetailLabel?.stringValue = String(format: "Power: %@ (%d%%, %.1fW)  •  Battery Safety Floor: %d%%  •  Thermal: %@", pwrStr, tel.batteryPercent, abs(tel.wattageW), cfg.batteryFloorPercent, tel.thermalState)

        graphView.addSample(
            brightnessPercent: Double(brightPct),
            isClamshellClosed: tel.isClamshellClosed,
            isAwake: cfg.mode != .off
        )

        switch cfg.mode {
        case .indefinite: modeSegment?.selectedSegment = 0
        case .acOnly: modeSegment?.selectedSegment = 1
        case .timed: modeSegment?.selectedSegment = 2
        case .off: modeSegment?.selectedSegment = 3
        }

        brightnessSlider?.integerValue = brightPct
        brightnessValueLabel?.stringValue = "\(brightPct)%"
        blackoutCheckbox?.state = cfg.clamshellBlackoutEnabled ? .on : .off
        muteSpeakersCheckbox?.state = cfg.muteSpeakersWhenClosed ? .on : .off
        idlePopup?.selectItem(withTag: cfg.idleDimSeconds)
        loginCheckbox?.state = isLaunchAtLoginEnabled() ? .on : .off
        uninstallDaemonButton?.isEnabled = daemonActive

        if isUpdatingApp {
            updateLabel?.stringValue = "⚡ Updating Clamshell…"
            updateLabel?.textColor = .systemBlue
            updateSubLabel?.stringValue = updateStatusText
            updateActionButton?.title = "Updating…"
            updateActionButton?.isEnabled = false
        } else if let rel = latestRelease, UpdateChecker.isVersion(rel.version, newerThan: ClamshellVersion) {
            updateLabel?.stringValue = "🎉 Update Available: \(rel.tagName)"
            updateLabel?.textColor = .systemOrange
            updateSubLabel?.stringValue = updateStatusText.isEmpty ? "New version ready to install." : updateStatusText
            updateActionButton?.title = "Update Now"
            updateActionButton?.isEnabled = true
        } else {
            updateLabel?.stringValue = "✓ Clamshell v\(ClamshellVersion) (Latest)"
            updateLabel?.textColor = .systemGreen
            updateSubLabel?.stringValue = updateStatusText.isEmpty ? "Up to date (Checked automatically)." : updateStatusText
            updateActionButton?.title = "Check Updates"
            updateActionButton?.isEnabled = true
        }
    }

    // MARK: - Actions

    @objc private func modeSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: applyMode(.indefinite)
        case 1: applyMode(.acOnly)
        case 2: applyMode(.timed, minutes: 60)
        default: applyMode(.off)
        }
    }

    @objc private func selectIndefiniteMode() { applyMode(.indefinite) }
    @objc private func selectACOnlyMode() { applyMode(.acOnly) }
    @objc private func selectOffMode() { applyMode(.off) }
    @objc private func selectTimedPreset(_ sender: NSMenuItem) {
        applyMode(.timed, minutes: max(1, sender.tag))
    }

    private func applyMode(_ mode: AwakeMode, minutes: Int = 60) {
        var cfg = ConfigManager.shared.load()
        cfg.mode = mode
        if mode == .timed {
            cfg.timedDurationMinutes = minutes
            cfg.timedExpiresAtEpoch = Date().timeIntervalSince1970 + Double(minutes * 60)
            sendControl("MODE timed \(minutes)")
        } else {
            cfg.timedExpiresAtEpoch = nil
            sendControl("MODE \(mode.rawValue)")
        }
        _ = ConfigManager.shared.save(cfg)
        evaluateLocalSessionGuard()
        rebuildMenu()
        refreshSettingsWindow()
    }

    @objc private func brightnessSliderChanged(_ sender: NSSlider) {
        let pct = max(0, min(100, sender.integerValue))
        brightnessValueLabel?.stringValue = "\(pct)%"
        applyBrightnessPercent(pct)
    }

    @objc private func blackoutNowButtonClicked() {
        brightnessSlider?.integerValue = 0
        brightnessValueLabel?.stringValue = "0%"
        applyBrightnessPercent(0)
    }

    @objc private func selectBrightnessPreset(_ sender: NSMenuItem) {
        applyBrightnessPercent(sender.tag)
    }

    private func applyBrightnessPercent(_ pct: Int) {
        let clamped = max(0, min(100, pct))
        _ = DisplayBacklightController.shared.setBrightnessDirect(Double(clamped) / 100.0)
        if clamped > 2 {
            var cfg = ConfigManager.shared.load()
            cfg.savedBrightness = Double(clamped) / 100.0
            _ = ConfigManager.shared.save(cfg)
        }
        sendControl("BRIGHTNESS \(clamped)")
        rebuildMenu()
        refreshSettingsWindow()
    }

    @objc private func toggleClamshellBlackoutMenu() {
        let cfg = ConfigManager.shared.load()
        setClamshellBlackout(!cfg.clamshellBlackoutEnabled)
    }

    @objc private func toggleBlackoutCheckbox(_ sender: NSButton) {
        setClamshellBlackout(sender.state == .on)
    }

    private func setClamshellBlackout(_ enabled: Bool) {
        var cfg = ConfigManager.shared.load()
        cfg.clamshellBlackoutEnabled = enabled
        _ = ConfigManager.shared.save(cfg)
        sendControl("BLACKOUT \(enabled ? "on" : "off")")
        evaluateLocalSessionGuard()
        rebuildMenu()
        refreshSettingsWindow()
    }

    @objc private func toggleMuteSpeakersMenu() {
        let cfg = ConfigManager.shared.load()
        setMuteSpeakersWhenClosed(!cfg.muteSpeakersWhenClosed)
    }

    @objc private func toggleMuteSpeakersCheckbox(_ sender: NSButton) {
        setMuteSpeakersWhenClosed(sender.state == .on)
    }

    private func setMuteSpeakersWhenClosed(_ enabled: Bool) {
        var cfg = ConfigManager.shared.load()
        cfg.muteSpeakersWhenClosed = enabled
        _ = ConfigManager.shared.save(cfg)
        if !enabled {
            _ = AudioOutputController.shared.setBuiltInSpeakersMutedDirect(false)
            wasSpeakerMutedByApp = false
        }
        sendControl("MUTE \(enabled ? "on" : "off")")
        evaluateLocalSessionGuard()
        rebuildMenu()
        refreshSettingsWindow()
    }

    @objc private func selectIdleTimeoutMenu(_ sender: NSMenuItem) {
        setIdleTimeoutSeconds(sender.tag)
    }

    @objc private func idlePopupChanged(_ sender: NSPopUpButton) {
        if let tag = sender.selectedItem?.tag {
            setIdleTimeoutSeconds(tag)
        }
    }

    private func setIdleTimeoutSeconds(_ secs: Int) {
        var cfg = ConfigManager.shared.load()
        cfg.idleDimSeconds = secs
        _ = ConfigManager.shared.save(cfg)
        sendControl("IDLE \(secs)")
        evaluateLocalSessionGuard()
        rebuildMenu()
        refreshSettingsWindow()
    }

    private func sendControl(_ command: String) {
        Task.detached {
            _ = UnixSocketClient.send(command)
        }
    }

    private func isDaemonBinaryUpToDate(runningDaemonVersion: String? = nil) -> Bool {
        if let runningVer = runningDaemonVersion {
            return UpdateChecker.compareVersion(runningVer, ClamshellVersion) != .orderedAscending
        }
        let installed = FileManager.default.isExecutableFile(atPath: ClamshellLayout.daemonBinary)
            ? ClamshellLayout.daemonBinary
            : ClamshellLayout.cliBinary
        guard FileManager.default.isExecutableFile(atPath: installed) else { return false }
        let result = Shell.run(installed, ["version"])
        guard result.exitCode == 0 else { return false }
        let parts = result.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        guard let ver = parts.last, !ver.isEmpty else { return false }
        return UpdateChecker.compareVersion(ver, ClamshellVersion) != .orderedAscending
    }

    private func autoSyncDaemonIfNeeded() {
        guard !isAutoSyncingDaemon else { return }
        if lastAutoSyncAttempt != .distantPast, Date().timeIntervalSince(lastAutoSyncAttempt) < 60 {
            return
        }
        let daemonInfo = fetchDaemonStatus()
        guard daemonInfo.running else { return }
        guard !isDaemonBinaryUpToDate(runningDaemonVersion: daemonInfo.version) else { return }

        isAutoSyncingDaemon = true
        lastAutoSyncAttempt = Date()
        let bundled = bundledCLIBinaryPath()

        Task.detached { [weak self] in
            let response = UnixSocketClient.send("UPGRADE \(bundled)")
            let ok = UnixSocketClient.isSuccess(response)
            if ok {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isAutoSyncingDaemon = false
                if ok {
                    self.rebuildMenu()
                    self.refreshSettingsWindow()
                }
            }
        }
    }

    private func bundledCLIBinaryPath() -> String {
        if let resPath = Bundle.main.resourcePath {
            let candidate = "\(resPath)/clamshell"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return ClamshellLayout.cliBinary
    }

    @objc private func installDaemonAction() {
        let bundled = bundledCLIBinaryPath()
        let daemonBin = ClamshellLayout.daemonBinary
        let cliBin = ClamshellLayout.cliBinary
        let cmd = "mkdir -p \(ClamshellLayout.cliDirectory) '\(ClamshellLayout.supportDirectory)' && install -m 755 '\(bundled)' '\(daemonBin)' && install -m 755 '\(bundled)' \(cliBin) && xattr -cr '\(daemonBin)' \(cliBin) 2>/dev/null || true && codesign --force --sign - '\(daemonBin)' \(cliBin) 2>/dev/null || true && \(cliBin) install"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        _ = Shell.run("/usr/bin/osascript", ["-e", script])

        Thread.sleep(forTimeInterval: 0.5)
        rebuildMenu()
        refreshSettingsWindow()
    }

    @objc private func uninstallDaemonAction() {
        let cmd = "\(ClamshellLayout.cliBinary) uninstall && rm -rf '\(ClamshellLayout.supportDirectory)' \(ClamshellLayout.cliBinary) \(ClamshellLayout.socketPath)"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        _ = Shell.run("/usr/bin/osascript", ["-e", script])

        rebuildMenu()
        refreshSettingsWindow()
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        return FileManager.default.fileExists(atPath: launchAgentPath)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let parent = (launchAgentPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            let execPath = Bundle.main.executablePath ?? "\(ClamshellLayout.appBundle)/Contents/MacOS/ClamshellApp"
            let plist = ClamshellLayout.appLaunchAgentXML(executable: execPath)
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(atPath: launchAgentPath)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!isLaunchAtLoginEnabled())
        rebuildMenu()
        refreshSettingsWindow()
    }

    private func checkUpdateSilently(force: Bool = false) async {
        if let info = await UpdateChecker.checkForUpdate(currentVersion: ClamshellVersion, force: force) {
            await MainActor.run {
                self.latestRelease = info
                self.rebuildMenu()
                self.refreshSettingsWindow()
            }
        }
    }

    @objc private func updateActionButtonClicked() {
        if let release = latestRelease, UpdateChecker.isVersion(release.version, newerThan: ClamshellVersion) {
            triggerAppUpdate()
        } else {
            manualCheckUpdate(showAlertIfUpToDate: true)
        }
    }

    @objc private func triggerAppUpdate() {
        showSettingsWindow()
        guard let release = latestRelease, UpdateChecker.isVersion(release.version, newerThan: ClamshellVersion) else { return }
        guard let dmgUrl = URL(string: release.dmgUrl) else { return }

        isUpdatingApp = true
        updateStatusText = "Downloading update disk image…"
        refreshSettingsWindow()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await UpdateChecker.installAppUpdate(dmgUrl: dmgUrl, relaunch: true) { [weak self] step in
                    Task { @MainActor in
                        self?.updateStatusText = step
                        self?.refreshSettingsWindow()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isUpdatingApp = false
                    self.updateStatusText = "Update failed: \(error.localizedDescription)"
                    self.refreshSettingsWindow()
                }
            }
        }
    }

    @objc private func menuCheckForUpdates() {
        manualCheckUpdate(showAlertIfUpToDate: true)
    }

    private func manualCheckUpdate(showAlertIfUpToDate: Bool = false) {
        updateStatusText = "Checking GitHub…"
        updateActionButton?.isEnabled = false
        refreshSettingsWindow()
        Task {
            let info = await UpdateChecker.checkForUpdate(currentVersion: ClamshellVersion, force: true)
            await MainActor.run {
                self.latestRelease = info
                self.updateActionButton?.isEnabled = true
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                let timeStr = formatter.string(from: Date())

                if let inf = info, UpdateChecker.isVersion(inf.version, newerThan: ClamshellVersion) {
                    self.updateStatusText = "New release found: \(inf.tagName)"
                    self.rebuildMenu()
                    self.refreshSettingsWindow()
                    self.showSettingsWindow()
                } else {
                    self.updateStatusText = "✓ Up to date (checked at \(timeStr))"
                    self.rebuildMenu()
                    self.refreshSettingsWindow()
                    if showAlertIfUpToDate {
                        let alert = NSAlert()
                        alert.messageText = "Clamshell is Up to Date"
                        alert.informativeText = "Version \(ClamshellVersion) is currently the newest version available."
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    private func menuBarSymbol(telemetry: HardwareTelemetry, config: ClamshellConfig) -> String {
        if config.mode == .off {
            return "🌙"
        }
        if telemetry.isClamshellClosed {
            return "🦪"
        }
        if config.mode == .timed {
            return "⏱️"
        }
        return "☕"
    }

    private func updateMenuBarTitleOnly(telemetry: HardwareTelemetry, config: ClamshellConfig) {
        guard let button = statusItem.button else { return }
        let symbol = menuBarSymbol(telemetry: telemetry, config: config)
        let brightPct = Int((telemetry.currentBrightness * 100.0).rounded())
        let title: String
        if config.mode == .off {
            title = "\(symbol) Off"
        } else if telemetry.isClamshellClosed {
            title = "\(symbol) \(brightPct)%"
        } else if config.mode == .timed, let exp = config.timedExpiresAtEpoch {
            let remMins = max(1, Int(((exp - Date().timeIntervalSince1970) / 60.0).rounded()))
            title = "\(symbol) \(remMins)m · \(brightPct)%"
        } else {
            title = "\(symbol) \(brightPct)%"
        }
        button.title = title
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { ClamshellAppDelegate() }
app.delegate = delegate
app.run()
