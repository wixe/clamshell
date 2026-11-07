import Foundation
import Darwin

func writeUnixPath(_ path: String, into addr: inout sockaddr_un) -> Bool {
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= maxLen else { return false }
    return withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
        for (i, byte) in pathBytes.enumerated() {
            rawBuf[i] = UInt8(bitPattern: byte)
        }
        return true
    }
}

public final class UnixSocketServer {
    public static let defaultSocketPath = ClamshellLayout.socketPath

    private let socketPath: String
    private var serverFD: Int32 = -1
    private var isRunning = false
    private weak var governor: ClamshellGovernor?
    private let acceptQueue = DispatchQueue(label: "io.github.wixe.clamshell.ipc", qos: .utility)

    public init(socketPath: String = UnixSocketServer.defaultSocketPath, governor: ClamshellGovernor) {
        self.socketPath = socketPath
        self.governor = governor
    }

    deinit {
        stop()
    }

    public func start() {
        guard !isRunning else { return }

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        guard writeUnixPath(socketPath, into: &addr) else {
            close(fd)
            return
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }

        chmod(socketPath, 0o666)

        self.serverFD = fd
        self.isRunning = true

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        isRunning = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while isRunning && serverFD >= 0 {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientLen)
                }
            }
            if clientFD < 0 {
                if !isRunning { break }
                continue
            }
            handleClient(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { close(clientFD) }

        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var euid: uid_t = 65534
        var egid: gid_t = 65534
        let credOK = (getpeereid(clientFD, &euid, &egid) == 0)
        let isAuthorized = credOK && isPeerAuthorized(euid: euid, egid: egid)

        var buffer = [UInt8](repeating: 0, count: 512)
        let bytesRead = read(clientFD, &buffer, buffer.count - 1)
        let request: String
        if bytesRead > 0 {
            request = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            request = "STATUS"
        }

        let response = processCommand(request, isAuthorized: isAuthorized)
        _ = response.withCString { cStr in
            write(clientFD, cStr, strlen(cStr))
        }
    }

    private func isPeerAuthorized(euid: uid_t, egid: gid_t) -> Bool {
        if euid == 0 { return true }
        var statBuf = stat()
        if stat("/dev/console", &statBuf) == 0 && statBuf.st_uid == euid {
            return true
        }
        if egid == 80 { return true }
        if let pwd = getpwuid(euid) {
            var numGroups: Int32 = 64
            var groups = [Int32](repeating: 0, count: 64)
            if getgrouplist(pwd.pointee.pw_name, Int32(pwd.pointee.pw_gid), &groups, &numGroups) == 0 {
                if groups.prefix(Int(numGroups)).contains(80) {
                    return true
                }
            }
        }
        return false
    }

    private func processCommand(_ commandLine: String, isAuthorized: Bool) -> String {
        guard let governor = governor else {
            return "{\"error\":\"Governor unavailable\"}\n"
        }

        let parts = commandLine.split(separator: " ").map(String.init)
        let cmd = (parts.first ?? "STATUS").uppercased()

        switch cmd {
        case "STATUS", "GET":
            let report = governor.getCombinedReport()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return json + "\n"
            }
            return "{\"error\":\"Serialization failed\"}\n"

        case "MODE":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied: console user, admin, or root privileges required\"}\n"
            }
            guard parts.count >= 2 else {
                return "{\"error\":\"Usage: MODE <indefinite|timed|ac_only|off> [minutes]\"}\n"
            }
            let modeArg = parts[1].lowercased()
            var cfg = governor.config
            switch modeArg {
            case "indefinite", "always", "on", "24/7":
                cfg.mode = .indefinite
                cfg.timedExpiresAtEpoch = nil
            case "timed", "timer":
                cfg.mode = .timed
                let mins = (parts.count >= 3 ? Int(parts[2]) : nil) ?? cfg.timedDurationMinutes
                let clampedMins = max(1, min(10080, mins))
                cfg.timedDurationMinutes = clampedMins
                cfg.timedExpiresAtEpoch = Date().timeIntervalSince1970 + Double(clampedMins * 60)
            case "ac_only", "ac", "power":
                cfg.mode = .acOnly
                cfg.timedExpiresAtEpoch = nil
            case "off", "sleep", "normal", "disable":
                cfg.mode = .off
                cfg.timedExpiresAtEpoch = nil
            default:
                return "{\"error\":\"Invalid mode: \(modeArg). Use indefinite, timed, ac_only, or off.\"}\n"
            }
            governor.updateConfig(cfg, reason: "Mode set to \(cfg.mode.displayName)")
            return "{\"success\":true,\"mode\":\"\(cfg.mode.rawValue)\"}\n"

        case "BLACKOUT":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied\"}\n"
            }
            guard parts.count >= 2 else {
                return "{\"error\":\"Usage: BLACKOUT <on|off>\"}\n"
            }
            let enabled = ["on", "true", "1", "yes"].contains(parts[1].lowercased())
            var cfg = governor.config
            cfg.clamshellBlackoutEnabled = enabled
            governor.updateConfig(cfg, reason: "Closed-clamshell blackout \(enabled ? "enabled" : "disabled")")
            return "{\"success\":true,\"clamshell_blackout_enabled\":\(enabled)}\n"

        case "IDLE":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied\"}\n"
            }
            guard parts.count >= 2, let secs = Int(parts[1]), (0...86400).contains(secs) else {
                return "{\"error\":\"Usage: IDLE <seconds (0-86400)>\"}\n"
            }
            var cfg = governor.config
            cfg.idleDimSeconds = secs
            governor.updateConfig(cfg, reason: secs == 0 ? "Open-lid idle dimmer disabled" : "Open-lid idle dimmer set to \(secs)s")
            return "{\"success\":true,\"idle_dim_seconds\":\(secs)}\n"

        case "BRIGHTNESS":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied\"}\n"
            }
            guard parts.count >= 2, let pct = Double(parts[1]), (0.0...100.0).contains(pct) else {
                return "{\"error\":\"Usage: BRIGHTNESS <0-100>\"}\n"
            }
            governor.setManualBrightness(pct / 100.0)
            return "{\"success\":true,\"brightness_percent\":\(Int(pct.rounded()))}\n"

        case "FLOOR":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied\"}\n"
            }
            guard parts.count >= 2, let pct = Int(parts[1]), (5...80).contains(pct) else {
                return "{\"error\":\"Usage: FLOOR <5-80>\"}\n"
            }
            var cfg = governor.config
            cfg.batteryFloorPercent = pct
            governor.updateConfig(cfg, reason: "Battery safety floor set to \(pct)%")
            return "{\"success\":true,\"battery_floor_percent\":\(pct)}\n"

        case "UPGRADE":
            var sourcePath = "\(ClamshellLayout.appBundle)/Contents/Resources/clamshell"
            if parts.count >= 2 {
                sourcePath = parts[1]
            }

            if !isAuthorized && !sourcePath.hasPrefix("/Applications/") {
                return "{\"error\":\"Permission denied\"}\n"
            }
            guard FileManager.default.isExecutableFile(atPath: sourcePath) else {
                return "{\"error\":\"Source binary does not exist: \(sourcePath)\"}\n"
            }

            let daemonBin = ClamshellLayout.daemonBinary
            let cliBin = ClamshellLayout.cliBinary

            try? FileManager.default.createDirectory(atPath: ClamshellLayout.supportDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: ClamshellLayout.cliDirectory, withIntermediateDirectories: true)

            guard SignedBinary.install(from: sourcePath, to: daemonBin),
                  SignedBinary.install(from: sourcePath, to: cliBin) else {
                return "{\"error\":\"Failed to install updated Clamshell binary\"}\n"
            }

            for path in [daemonBin, cliBin] {
                SignedBinary.stripQuarantineAndSign(path)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                exit(0)
            }

            return "{\"success\":true,\"message\":\"clamshelld & CLI updated. Restarting via launchd...\"}\n"

        case "INSTALL_APP":
            guard isAuthorized else {
                return "{\"error\":\"Permission denied\"}\n"
            }
            guard parts.count >= 2 else {
                return "{\"error\":\"Usage: INSTALL_APP <source_app_path>\"}\n"
            }
            let sourceApp = parts.dropFirst().joined(separator: " ")
            guard FileManager.default.fileExists(atPath: sourceApp) && sourceApp.hasSuffix(".app") else {
                return "{\"error\":\"Invalid source app path: \(sourceApp)\"}\n"
            }
            let destApp = ClamshellLayout.appBundle
            let trashOld = "/tmp/Clamshell-old-\(UUID().uuidString).app"

            if FileManager.default.fileExists(atPath: destApp) {
                _ = Shell.run("/bin/mv", [destApp, trashOld])
            }

            let copied = Shell.run("/bin/cp", ["-R", sourceApp, destApp])
            if copied.exitCode != 0 {
                if FileManager.default.fileExists(atPath: trashOld) {
                    _ = Shell.run("/bin/mv", [trashOld, destApp])
                }
                return "{\"error\":\"Failed to copy Clamshell.app\"}\n"
            }

            _ = try? FileManager.default.removeItem(atPath: trashOld)

            let who = Shell.run("/usr/bin/stat", ["-f", "%Su", "/dev/console"])
            let consoleUser = who.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if who.exitCode == 0, !consoleUser.isEmpty, consoleUser != "root" {
                _ = Shell.run("/usr/sbin/chown", ["-R", "\(consoleUser):admin", destApp])
            }

            SignedBinary.stripQuarantineAndSign(destApp, deep: true)

            let bundledCLI = "\(destApp)/Contents/Resources/clamshell"
            if FileManager.default.isExecutableFile(atPath: bundledCLI) {
                try? FileManager.default.createDirectory(atPath: ClamshellLayout.supportDirectory, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(atPath: ClamshellLayout.cliDirectory, withIntermediateDirectories: true)
                _ = SignedBinary.install(from: bundledCLI, to: ClamshellLayout.daemonBinary)
                _ = SignedBinary.install(from: bundledCLI, to: ClamshellLayout.cliBinary)
                SignedBinary.stripQuarantineAndSign(ClamshellLayout.daemonBinary)
                SignedBinary.stripQuarantineAndSign(ClamshellLayout.cliBinary)

                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    exit(0)
                }
            }

            return "{\"success\":true,\"message\":\"Clamshell.app and daemon updated successfully.\"}\n"

        default:
            return "{\"error\":\"Unknown command. Supported: STATUS, MODE, BLACKOUT, IDLE, BRIGHTNESS, FLOOR, UPGRADE, INSTALL_APP\"}\n"
        }
    }
}

public enum UnixSocketClient {
    public static func send(_ command: String, socketPath: String = UnixSocketServer.defaultSocketPath) -> String? {
        return sendDirect(command, socketPath: socketPath)
    }

    public static func isSuccess(_ response: String?) -> Bool {
        guard let response,
              let data = response.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let ok = obj["success"] as? Bool { return ok }
        if let number = obj["success"] as? NSNumber { return number.boolValue }
        return false
    }

    private static func sendDirect(_ command: String, socketPath: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        let timeoutLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLen)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLen)

        var addr = sockaddr_un()
        guard writeUnixPath(socketPath, into: &addr) else { return nil }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let payload = command.hasSuffix("\n") ? command : (command + "\n")
        let written = payload.withCString { cStr in
            write(fd, cStr, strlen(cStr))
        }
        guard written > 0 else { return nil }
        _ = shutdown(fd, SHUT_WR)

        var output = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                output.append(buf, count: n)
                continue
            }
            if n < 0 && errno == EINTR { continue }
            break
        }
        return output.isEmpty ? nil : String(data: output, encoding: .utf8)
    }
}
