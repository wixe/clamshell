import Foundation

public enum ClamshellLayout {
    public static let projectLinkTitle = "github.com/wixe/clamshell"
    public static let projectURL = URL(string: "https://github.com/wixe/clamshell")!

    public static let gitHubOwner = "wixe"
    public static let gitHubRepo = "clamshell"

    public static let socketPath = "/var/run/clamshell.sock"
    public static let systemConfigPath = "/etc/clamshell.json"

    public static let supportDirectory = "/Library/Application Support/clamshell"
    public static let daemonBinary = "\(supportDirectory)/clamshelld"
    public static let cliDirectory = "/usr/local/bin"
    public static let cliBinary = "\(cliDirectory)/clamshell"

    public static let appBundle = "/Applications/Clamshell.app"

    public static let daemonLabel = "io.github.wixe.clamshell.daemon"
    public static let appLabel = "io.github.wixe.clamshell.agent"
    public static let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"
    public static let stdoutLog = "/var/log/clamshell.log"
    public static let stderrLog = "/var/log/clamshell.error.log"

    public static var daemonLabels: [String] {
        [daemonLabel]
    }

    public static func userConfigPath(home: String) -> String {
        "\(home)/.config/clamshell/config.json"
    }

    public static func launchAgentPath(home: String) -> String {
        "\(home)/Library/LaunchAgents/\(appLabel).plist"
    }

    public static func daemonPlistXML(program: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(program)</string>
                <string>daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(stdoutLog)</string>
            <key>StandardErrorPath</key>
            <string>\(stderrLog)</string>
        </dict>
        </plist>
        """
    }

    public static func appLaunchAgentXML(executable: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(appLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
                <string>--background</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """
    }
}
