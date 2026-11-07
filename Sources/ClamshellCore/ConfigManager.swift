import Foundation

public final class ConfigManager {
    public static let shared = ConfigManager()

    private let systemConfigPath = ClamshellLayout.systemConfigPath
    private let userConfigPath: String

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.userConfigPath = ClamshellLayout.userConfigPath(home: home)
    }

    private var activePath: String {
        if FileManager.default.fileExists(atPath: systemConfigPath) {
            return systemConfigPath
        }
        if FileManager.default.isWritableFile(atPath: "/etc") {
            return systemConfigPath
        }
        return userConfigPath
    }

    public func load() -> ClamshellConfig {
        for path in [systemConfigPath, userConfigPath] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let cfg = try? JSONDecoder().decode(ClamshellConfig.self, from: data) {
                return cfg
            }
        }
        return .default
    }

    @discardableResult
    public func save(_ config: ClamshellConfig) -> Bool {
        let path = activePath
        let url = URL(fileURLWithPath: path)

        do {
            let parentDir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
            if path == systemConfigPath {
                chmod(systemConfigPath, 0o644)
            }
            return true
        } catch {
            return false
        }
    }
}
