import Foundation
#if canImport(AppKit)
import AppKit
#endif

public let ClamshellVersion = "0.1.0"

public struct ReleaseInfo: Codable, Equatable {
    public let version: String
    public let tagName: String
    public let title: String
    public let releaseNotes: String
    public let htmlUrl: String
    public let dmgUrl: String
    public let binaryUrl: String
    public let isNewer: Bool

    public init(
        version: String,
        tagName: String,
        title: String,
        releaseNotes: String,
        htmlUrl: String,
        dmgUrl: String,
        binaryUrl: String,
        isNewer: Bool
    ) {
        self.version = version
        self.tagName = tagName
        self.title = title
        self.releaseNotes = releaseNotes
        self.htmlUrl = htmlUrl
        self.dmgUrl = dmgUrl
        self.binaryUrl = binaryUrl
        self.isNewer = isNewer
    }
}

public enum UpdateError: LocalizedError {
    case networkError(String)
    case parsingError(String)
    case mountFailed(String)
    case missingAppBundle
    case copyFailed(String)
    case rootRequired
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .parsingError(let msg): return "Failed to parse release information: \(msg)"
        case .mountFailed(let msg): return "Failed to mount update disk image: \(msg)"
        case .missingAppBundle: return "Downloaded disk image does not contain Clamshell.app"
        case .copyFailed(let msg): return "Failed to install Clamshell.app: \(msg)"
        case .rootRequired: return "Root privileges are required to update the daemon binary (run with sudo)"
        case .commandFailed(let msg): return "System command failed: \(msg)"
        }
    }
}

public final class UpdateChecker {
    private static let repoOwner = ClamshellLayout.gitHubOwner
    private static let repoName = ClamshellLayout.gitHubRepo

    private static let lastCheckKey = "io.github.wixe.clamshell.lastUpdateCheck"
    private static let cachedReleaseKey = "io.github.wixe.clamshell.cachedReleaseInfo"
    private static let checkIntervalSeconds: TimeInterval = 86400

    public static func cachedRelease() -> ReleaseInfo? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: cachedReleaseKey),
           let info = try? JSONDecoder().decode(ReleaseInfo.self, from: data) {
            return info
        }
        return nil
    }

    public static func compareVersion(_ v1: String, _ v2: String) -> ComparisonResult {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))

        let parts1 = clean1.split(separator: ".").compactMap { Int($0) }
        let parts2 = clean2.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(parts1.count, parts2.count)
        for i in 0..<maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return .orderedAscending }
            if p1 > p2 { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        return compareVersion(v1, v2) == .orderedDescending
    }

    public static func clearCache() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastCheckKey)
        defaults.removeObject(forKey: cachedReleaseKey)
    }

    public static func checkForUpdate(currentVersion: String = ClamshellVersion, force: Bool = false) async -> ReleaseInfo? {
        let defaults = UserDefaults.standard

        if !force, let lastCheck = defaults.object(forKey: lastCheckKey) as? Date {
            if Date().timeIntervalSince(lastCheck) < checkIntervalSeconds {
                if let cachedData = defaults.data(forKey: cachedReleaseKey),
                   let cached = try? JSONDecoder().decode(ReleaseInfo.self, from: cachedData) {
                    let currentlyNewer = isVersion(cached.version, newerThan: currentVersion)
                    if cached.isNewer != currentlyNewer {
                        let updated = ReleaseInfo(
                            version: cached.version,
                            tagName: cached.tagName,
                            title: cached.title,
                            releaseNotes: cached.releaseNotes,
                            htmlUrl: cached.htmlUrl,
                            dmgUrl: cached.dmgUrl,
                            binaryUrl: cached.binaryUrl,
                            isNewer: currentlyNewer
                        )
                        persistCache(updated)
                        return updated
                    }
                    return cached
                }
                return nil
            }
        }

        if let info = await fetchLatestRelease(currentVersion: currentVersion) {
            persistCache(info)
            return info
        }

        if let info = await fetchLatestTag(currentVersion: currentVersion) {
            persistCache(info)
            return info
        }

        defaults.set(Date(), forKey: lastCheckKey)
        return nil
    }

    private static func persistCache(_ info: ReleaseInfo) {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: lastCheckKey)
        if let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: cachedReleaseKey)
        }
    }

    private static func fetchLatestRelease(currentVersion: String) async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        request.setValue("Clamshell-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }

            let cleanVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
            let isNewer = isVersion(cleanVer, newerThan: currentVersion)
            let title = json["name"] as? String ?? "Clamshell \(tagName)"
            let body = json["body"] as? String ?? ""
            let htmlUrl = json["html_url"] as? String ?? "https://github.com/\(repoOwner)/\(repoName)/releases"

            var dmgUrl = "https://github.com/\(repoOwner)/\(repoName)/raw/main/dist/Clamshell.dmg"
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                       let downloadUrl = asset["browser_download_url"] as? String {
                        dmgUrl = downloadUrl
                        break
                    }
                }
            }
            let binaryUrl = "https://raw.githubusercontent.com/\(repoOwner)/\(repoName)/main/bin/clamshell"

            return ReleaseInfo(
                version: cleanVer,
                tagName: tagName,
                title: title,
                releaseNotes: body,
                htmlUrl: htmlUrl,
                dmgUrl: dmgUrl,
                binaryUrl: binaryUrl,
                isNewer: isNewer
            )
        } catch {
            return nil
        }
    }

    private static func fetchLatestTag(currentVersion: String) async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/tags") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        request.setValue("Clamshell-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            guard let tags = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = tags.first,
                  let tagName = first["name"] as? String else {
                return nil
            }

            let cleanVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
            let isNewer = isVersion(cleanVer, newerThan: currentVersion)
            let title = "Clamshell \(tagName)"
            let htmlUrl = "https://github.com/\(repoOwner)/\(repoName)/releases/tag/\(tagName)"
            let dmgUrl = "https://github.com/\(repoOwner)/\(repoName)/raw/main/dist/Clamshell.dmg"
            let binaryUrl = "https://raw.githubusercontent.com/\(repoOwner)/\(repoName)/main/bin/clamshell"

            return ReleaseInfo(
                version: cleanVer,
                tagName: tagName,
                title: title,
                releaseNotes: "Latest release available on GitHub.",
                htmlUrl: htmlUrl,
                dmgUrl: dmgUrl,
                binaryUrl: binaryUrl,
                isNewer: isNewer
            )
        } catch {
            return nil
        }
    }

    public static func installAppUpdate(dmgUrl: URL, relaunch: Bool = true, progressHandler: @escaping (String) -> Void) async throws {
        progressHandler("Downloading update disk image…")

        let tempDmg = URL(fileURLWithPath: "/tmp/Clamshell-update-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: tempDmg) }

        var request = URLRequest(url: dmgUrl)
        request.timeoutInterval = 30.0
        request.setValue("Clamshell-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        try data.write(to: tempDmg)

        progressHandler("Mounting update disk image…")
        let mountDir = URL(fileURLWithPath: "/tmp/clamshell-mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)
        defer {
            _ = Shell.run("/usr/bin/hdiutil", ["detach", mountDir.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountDir)
        }

        let attachResult = Shell.run("/usr/bin/hdiutil", ["attach", tempDmg.path, "-mountpoint", mountDir.path, "-nobrowse", "-quiet"])
        guard attachResult.exitCode == 0 else {
            throw UpdateError.mountFailed(attachResult.output)
        }

        let sourceApp = mountDir.appendingPathComponent("Clamshell.app")
        guard FileManager.default.fileExists(atPath: sourceApp.path) else {
            throw UpdateError.missingAppBundle
        }

        progressHandler("Installing \(ClamshellLayout.appBundle)…")
        let destApp = URL(fileURLWithPath: ClamshellLayout.appBundle)

        var installedViaDaemon = false
        var installSuccess = false
        var installErrorMsg = ""

        let trashOld = URL(fileURLWithPath: "/tmp/Clamshell-old-\(UUID().uuidString).app")
        var movedAside = false
        if FileManager.default.fileExists(atPath: destApp.path) {
            do {
                try FileManager.default.moveItem(at: destApp, to: trashOld)
                movedAside = true
            } catch {
                movedAside = false
            }
        } else {
            movedAside = true
        }

        if movedAside {
            let copyResult = Shell.run("/bin/cp", ["-R", sourceApp.path, destApp.path])
            if copyResult.exitCode == 0 {
                installSuccess = true
                _ = try? FileManager.default.removeItem(at: trashOld)
            } else {
                installErrorMsg = copyResult.output
                if FileManager.default.fileExists(atPath: trashOld.path) {
                    _ = try? FileManager.default.moveItem(at: trashOld, to: destApp)
                }
            }
        }

        if !installSuccess {
            progressHandler("Requesting root daemon to install \(ClamshellLayout.appBundle)…")
            if let resp = UnixSocketClient.send("INSTALL_APP \(sourceApp.path)"), UnixSocketClient.isSuccess(resp) {
                installSuccess = true
                installedViaDaemon = true
            } else if installErrorMsg.isEmpty {
                installErrorMsg = "Daemon IPC installation unsuccessful."
            }
        }

        if !installSuccess {
            progressHandler("Requesting administrator approval to install \(ClamshellLayout.appBundle)…")
            let app = ClamshellLayout.appBundle
            let adminScript = """
            do shell script "rm -rf '\(app)' && cp -R '\(sourceApp.path)' '\(app)' && chown -R $USER:admin '\(app)' && xattr -cr '\(app)' && codesign --force --deep --sign - '\(app)'" with administrator privileges
            """
            var scriptError: NSDictionary?
            #if canImport(AppKit)
            if let appleScript = NSAppleScript(source: adminScript) {
                _ = appleScript.executeAndReturnError(&scriptError)
                if scriptError == nil {
                    installSuccess = true
                } else if let msg = scriptError?["NSAppleScriptErrorMessage"] as? String {
                    installErrorMsg = msg
                }
            }
            #endif
        }

        guard installSuccess else {
            throw UpdateError.copyFailed(installErrorMsg)
        }

        SignedBinary.stripQuarantineAndSign(destApp.path, deep: true)
        _ = Shell.run("/usr/bin/hdiutil", ["detach", mountDir.path, "-quiet"])

        if !installedViaDaemon {
            let bundledCLI = destApp.appendingPathComponent("Contents/Resources/clamshell").path
            if FileManager.default.isExecutableFile(atPath: bundledCLI) {
                progressHandler("Updating background daemon & CLI…")
                if let resp = UnixSocketClient.send("UPGRADE \(bundledCLI)"), UnixSocketClient.isSuccess(resp) {
                    progressHandler("Background daemon updated and restarted.")
                } else if getuid() == 0 {
                    try? FileManager.default.createDirectory(atPath: ClamshellLayout.supportDirectory, withIntermediateDirectories: true)
                    try? FileManager.default.createDirectory(atPath: ClamshellLayout.cliDirectory, withIntermediateDirectories: true)
                    _ = SignedBinary.install(from: bundledCLI, to: ClamshellLayout.daemonBinary)
                    _ = SignedBinary.install(from: bundledCLI, to: ClamshellLayout.cliBinary)
                    SignedBinary.stripQuarantineAndSign(ClamshellLayout.daemonBinary)
                    SignedBinary.stripQuarantineAndSign(ClamshellLayout.cliBinary)
                    _ = Shell.run("/bin/launchctl", ["kickstart", "-k", "system/\(ClamshellLayout.daemonLabel)"])
                }
            }
        }

        clearCache()

        if relaunch {
            progressHandler("Relaunching Clamshell…")
            let executablePath = destApp.appendingPathComponent("Contents/MacOS/ClamshellApp").path
            let relaunchCmd = "(sleep 0.6; open '\(destApp.path)' || '\(executablePath)' --background) >/dev/null 2>&1 &"
            _ = Shell.run("/bin/sh", ["-c", relaunchCmd])
            #if canImport(AppKit)
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
            #endif
        }
    }

    public static func installCLIUpdate(binaryUrl: URL, progressHandler: @escaping (String) -> Void) async throws {
        guard getuid() == 0 else {
            throw UpdateError.rootRequired
        }

        progressHandler("Downloading latest Clamshell binary…")
        let tempBin = URL(fileURLWithPath: "/tmp/clamshell-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBin) }

        var request = URLRequest(url: binaryUrl)
        request.timeoutInterval = 30.0
        request.setValue("Clamshell-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        try data.write(to: tempBin)
        _ = Shell.run("/bin/chmod", ["755", tempBin.path])

        progressHandler("Installing to \(ClamshellLayout.cliBinary) and \(ClamshellLayout.daemonBinary)…")
        try? FileManager.default.createDirectory(atPath: ClamshellLayout.supportDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: ClamshellLayout.cliDirectory, withIntermediateDirectories: true)

        guard SignedBinary.install(from: tempBin.path, to: ClamshellLayout.cliBinary),
              SignedBinary.install(from: tempBin.path, to: ClamshellLayout.daemonBinary) else {
            throw UpdateError.copyFailed("Failed to copy updated binary.")
        }

        SignedBinary.stripQuarantineAndSign(ClamshellLayout.cliBinary)
        SignedBinary.stripQuarantineAndSign(ClamshellLayout.daemonBinary)

        if FileManager.default.fileExists(atPath: ClamshellLayout.daemonPlist) {
            progressHandler("Restarting background daemon…")
            _ = Shell.run("/bin/launchctl", ["kickstart", "-k", "system/\(ClamshellLayout.daemonLabel)"])
        }

        clearCache()
    }
}
