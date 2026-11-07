import Foundation

public enum Shell {
    @discardableResult
    public static func run(_ path: String, _ args: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

public enum SignedBinary {
    public static func byteCount(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        if let size = attrs[.size] as? Int64 { return size }
        if let size = attrs[.size] as? Int { return Int64(size) }
        if let size = attrs[.size] as? NSNumber { return size.int64Value }
        return nil
    }

    public static func install(from source: String, to dest: String) -> Bool {
        guard let sourceSize = byteCount(source), sourceSize > 40_000 else { return false }
        let installed = Shell.run("/usr/bin/install", ["-m", "755", source, dest])
        if installed.exitCode == 0, byteCount(dest) == sourceSize {
            return true
        }
        let tmp = dest + ".new"
        do {
            if FileManager.default.fileExists(atPath: tmp) {
                try FileManager.default.removeItem(atPath: tmp)
            }
            try FileManager.default.copyItem(atPath: source, toPath: tmp)
            if FileManager.default.fileExists(atPath: dest) {
                try FileManager.default.removeItem(atPath: dest)
            }
            try FileManager.default.moveItem(atPath: tmp, toPath: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            return byteCount(dest) == sourceSize
        } catch {
            return false
        }
    }

    public static func stripQuarantineAndSign(_ path: String, deep: Bool = false) {
        _ = Shell.run("/usr/bin/xattr", ["-cr", path])
        let args = deep
            ? ["--force", "--deep", "--sign", "-", path]
            : ["--force", "--sign", "-", path]
        _ = Shell.run("/usr/bin/codesign", args)
    }
}
