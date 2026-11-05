import Foundation

/// The only commands Unearth will ever run to clean something. Exact templates, nothing else.
public enum ToolAllowlist {
    private static let brewPaths: Set<String> = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static func validate(_ command: ToolCommand) -> Bool {
        let arguments = command.arguments
        switch (command.executable, command.needsAdmin) {
        case ("/usr/bin/xcrun", false):
            if arguments == ["simctl", "delete", "unavailable"] { return true }
            return arguments.count == 4 && Array(arguments.prefix(3)) == ["simctl", "runtime", "delete"]
                && arguments[3].wholeMatch(of: #/[A-Za-z0-9.\-]+/#) != nil
        case ("/usr/bin/tmutil", true):
            return arguments == ["deletelocalsnapshots", "/"]
        case (let executable, false) where brewPaths.contains(executable):
            return arguments == ["cleanup", "--prune=all"]
        default:
            return false
        }
    }

    /// How an admin command is run: macOS shows its standard administrator prompt.
    /// Only ever called with a validated command, whose parts contain no quotes or shell characters.
    static func adminInvocation(_ command: ToolCommand) -> (executable: String, arguments: [String]) {
        ("/usr/bin/osascript", ["-e", "do shell script \"\(command.commandLine)\" with administrator privileges"])
    }
}
