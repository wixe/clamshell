# Clamshell 🦪💻

> **Intelligent clamshell backlight governor & keep-awake utility for macOS.** Replace Amphetamine and `caffeinate` with hardware lid detection that keeps your MacBook awake with the lid closed while turning the physical display backlight completely off (`0.00` nits) — and automatically restores your brightness the instant you open the lid.

[![Build](https://github.com/wixe/clamshell/actions/workflows/build.yml/badge.svg)](https://github.com/wixe/clamshell/actions)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20%7C%20Apple%20Silicon-blue.svg)](https://apple.com/macos)
[![Swift](https://img.shields.io/badge/Swift-5.9%20%7C%206.0-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Author](https://img.shields.io/badge/developer-wixe-purple.svg)](https://github.com/wixe)

---

## 🦪 What is Clamshell?

**Clamshell** is a native, featherweight macOS menu bar app (`Clamshell.app`), CLI utility (`clamshell`), and background system daemon (`clamshelld`) that unifies **keep-awake session management** (replacing Amphetamine) with **hardware clamshell & Retina LCD backlight control**:

* **Closed-Clamshell Zero-Backlight Server Mode:** Detects the hardware Hall-effect lid sensor (`AppleClamshellState` in `IOPMrootDomain`). When the lid is closed, Clamshell keeps the system awake while driving the physical display backlight to **`0.00` (`0%` — completely dark, zero wasted energy, zero heat inside the closed clamshell, zero panel burn-in)**.
* **Closed-Clamshell Built-In Speaker Auto-Mute (`CoreAudio`):** Automatically mutes the MacBook's physical built-in speakers (`kAudioDeviceTransportTypeBuiltIn`) when the lid is closed so sound never plays out of a closed laptop in another room — while leaving remote and virtual audio outputs (High Performance Screen Sharing, AirPlay, BlackHole, SonoBus) 100% active. Unmutes automatically when you open the lid.
* **Instant Open-Lid Brightness & Audio Restoration:** The moment you open the clamshell (`AppleClamshellState: Closed → Open`), Clamshell automatically restores your display backlight to your last active open-lid brightness and unmutes your built-in speakers so you can work interactively right away.
* **WindowServer & GPU Stay 100% Online (No HDMI Dummy Plug Needed):** Unlike `pmset displaysleepnow` (which puts `WindowServer` to sleep and locks the macOS GUI session), Clamshell turns off the physical LED backlight via `DisplayServices.framework` while keeping `WindowServer` and the GPU framebuffer online. Remote desktop (`Screen Sharing`), headless GUI apps, and audio/video rendering continue running at full hardware acceleration.
* **Full Amphetamine Replacement:** Supports **24/7 Indefinite Awake**, **AC Power Only**, and **Timed Countdown Sessions** (`30m` to `12h+`) with a configurable **Battery Safety Floor** (default `20%`) that automatically suspends keep-awake if discharging on battery below your safety threshold.
* **Open-Lid Idle Blackout:** Optionally turns off the physical backlight (`0%`) after a configurable period of keyboard/trackpad inactivity (`HIDIdleTime` via `IOHIDSystem`, e.g., `5 minutes`) when the lid is left open, and wakes the backlight the instant you touch the keyboard or trackpad.
* **Ultra-Lightweight:** Compiled native Swift binary is **< 300 KB** with **< 10 MB RAM** footprint, zero network ports, and 0% CPU overhead.

---

## 📊 Architecture & Specifications

| Capability | Clamshell Implementation |
| :--- | :--- |
| **Clamshell Detection** | Direct IOKit `IOPMrootDomain` (`AppleClamshellState`) hardware sensor polling |
| **Backlight Control** | Hardware `DisplayServices.framework` (`DisplayServicesSetBrightness`) + `CoreDisplay` fallback |
| **Keep-Awake Engine** | Native `IOPMAssertion` (`PreventUserIdleSystemSleep` + `PreventUserIdleDisplaySleep`) & kernel `SleepDisabled` |
| **Idle Detection** | Native IOKit `IOHIDSystem` (`HIDIdleTime`) nanosecond input inactivity counter |
| **Battery Safety Guard** | Automatic sleep-prevention cutoff below configurable battery floor (`5%–80%`, default `20%`) |
| **IPC Transport** | Local POSIX Unix domain socket (`/var/run/clamshell.sock`) with peer credential verification |
| **Operating Modes** | Native AppKit Menu Bar app (`/Applications/Clamshell.app`), CLI (`/usr/local/bin/clamshell`), and daemon (`/Library/Application Support/clamshell/clamshelld`) |
| **Footprint & License** | **< 300 KB** Native arm64 binary, **< 10 MB RAM**, **0% CPU**, **100% Open Source (MIT)** |

---

## 🚀 Quick Start

### Option 1: macOS Menu Bar App (`Clamshell.dmg` — Drag & Drop)
1. Download **[`Clamshell.dmg`](https://github.com/wixe/clamshell/releases/latest/download/Clamshell.dmg)** and open it.
2. Drag **`Clamshell.app`** into the **`Applications`** folder.
3. Open **`Clamshell`** from `/Applications` — it adds the **`🦪`** icon to your macOS Menu Bar, opens the Settings Dashboard, and lets you configure keep-awake modes, brightness, and the background daemon with 1 click.

### Option 2: One-Line Terminal Install
```bash
curl -fsSL https://raw.githubusercontent.com/wixe/clamshell/main/install.sh | sudo bash
```

### Option 3: Clone & Install
```bash
git clone https://github.com/wixe/clamshell.git
cd clamshell
sudo ./install.sh
```

### Option 4: Build from Source
```bash
./scripts/build-dmg.sh
sudo ./install.sh --build
```

---

## 💻 CLI & Local Socket Usage

`clamshell` includes a scriptable terminal interface and local Unix socket (`/var/run/clamshell.sock`):

```bash
# Display live clamshell state, backlight brightness, keep-awake mode & telemetry
clamshell status

# Output machine-readable JSON for scripts and monitoring
clamshell status --json

# Keep Mac awake indefinitely 24/7 (replaces Amphetamine / caffeinate)
clamshell awake indefinite

# Keep Mac awake for a timed countdown session (e.g. 120 minutes)
clamshell awake timed 120

# Keep Mac awake only while connected to AC wall power
clamshell awake ac

# Disable keep-awake and allow normal macOS sleep
clamshell awake off

# Turn physical display backlight completely off (0% blackout, WindowServer stays online)
clamshell brightness 0

# Set physical display backlight brightness (1% to 100%)
clamshell brightness 65

# Toggle automatic 0% display blackout when clamshell lid is closed
clamshell blackout on

# Toggle automatic built-in speaker mute when clamshell lid is closed
clamshell mute on

# Turn off display backlight after 5 minutes (300s) of open-lid keyboard/trackpad inactivity
clamshell idle 300

# Set battery safety floor (automatically allows sleep if battery drops below 20%)
clamshell floor 20

# Install or uninstall the background daemon (clamshelld)
sudo clamshell install
sudo clamshell uninstall
```

---

## 🖥️ Live Telemetry Output

Running `clamshell status` displays hardware diagnostics:

```text
========================================================================
🦪 CLAMSHELL DISPLAY BACKLIGHT & KEEP-AWAKE GOVERNOR
========================================================================
  Clamshell State:    🦪 Closed (Clamshell Server Mode)
  Display Backlight:  🌑 0% (Physical Backlight OFF • Zero Burn-In)
  WindowServer GPU:   Online (2560×1600)
  Keep-Awake Mode:    Clamshell Closed • Server Awake (Backlight Off)
  Closed Blackout:    Enabled (0% when closed, auto-restore when opened)
  Open-Lid Idle Off:  300s (5m) (Current Idle: 4m 12s)
  Power & Battery:    🔌 AC Connected (100%)  •  Safety Floor: 20%
  Kernel Sleep Lock:  Active (SleepDisabled=1)
  Last Transition:    Clamshell closed → Display backlight off (0%)
  Icon Legend:        🦪 Closed Awake (0% LCD)  •  ☕ Open Awake  •  🌙 Sleep Allowed
========================================================================
```

---

## 🛠️ Configuration

Configuration is stored at `/etc/clamshell.json` (or `~/.config/clamshell/config.json`):

```json
{
  "batteryFloorPercent": 20,
  "clamshellBlackoutEnabled": true,
  "idleDimSeconds": 300,
  "mode": "indefinite",
  "pollIntervalSeconds": 2.0,
  "preventDisplaySleep": true,
  "savedBrightness": 0.65,
  "timedDurationMinutes": 60
}
```

---

## 📄 License

Clamshell is open-source software licensed under the [MIT License](LICENSE).
Copyright © 2026 [Wixe](https://github.com/wixe).
