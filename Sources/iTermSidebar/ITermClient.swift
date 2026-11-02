import Cocoa

/// Serializes every AppleScript call (NSAppleScript must not run concurrently)
/// and logs each distinct error once, since polling repeats them every second.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()
    private let queue = DispatchQueue(label: "studio.civic.iterm-sidebar.applescript")
    private var lastError: String?  // only touched on `queue`

    /// Blocks the caller until the script finishes; keep off the main thread.
    @discardableResult
    func run(_ source: String, label: String) -> NSAppleEventDescriptor? {
        queue.sync {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return result }
            let message = "\(label) AppleScript error: \(error)"
            if message != lastError { log(message) }
            lastError = message
            return nil
        }
    }
}

var isITermRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: iTermBundleID).isEmpty
}

/// Nested lists keep field boundaries intact, whatever characters titles or paths contain.
/// Each window record: {id, session name, {x1, y1, x2, y2}, is processing, session path, jobName, commandLine}.
/// `jobName` is the foreground job and does not require shell integration. As of iTerm 3.7 it hides
/// helper subprocesses (an MCP server spawned by claude, caffeinate) so the name is the agent itself.
private let fetchStateScript = """
tell application "iTerm2"
    set info to {}
    set activeWinId to 0
    set cw to missing value
    try
        set cw to current window
    end try
    set wList to windows
    repeat with i from 1 to count of wList
        set w to item i of wList
        set wid to id of w
        if w is cw then set activeWinId to wid
        set s to current session of current tab of w
        set sessionPath to ""
        try
            set sessionPath to variable s named "session.path"
        end try
        if sessionPath is "" then
            try
                set sessionPath to path of s
            end try
        end if
        set jobName to ""
        set commandLine to ""
        try
            set jobName to variable s named "jobName"
        end try
        try
            set commandLine to variable s named "commandLine"
        end try
        set end of info to {wid, name of s, bounds of w, is processing of s, sessionPath, jobName, commandLine}
    end repeat
    return {info, activeWinId}
end tell
"""

/// Returns nil when iTerm2 could not be queried (e.g. Automation permission denied).
func fetchITermState() -> ITermState? {
    // `tell application` would relaunch iTerm2 if it has been quit.
    guard isITermRunning else { return ITermState(windows: [], activeId: nil) }
    return AppleScriptRunner.shared.run(fetchStateScript, label: "fetchITermState").flatMap(parseITermState)
}

/// Parses the `{info, activeWinId}` result of `fetchStateScript`; malformed window records are dropped.
func parseITermState(_ output: NSAppleEventDescriptor) -> ITermState? {
    guard output.numberOfItems == 2, let records = output.atIndex(1) else { return nil }
    let windows: [ITerm2Window] = (0..<records.numberOfItems).compactMap { i in
        guard let r = records.atIndex(i + 1), r.numberOfItems >= 5,
              let id = r.atIndex(1)?.int32Value, id > 0,
              let b = r.atIndex(3), b.numberOfItems == 4 else { return nil }
        let edges = (1...4).map { CGFloat(b.atIndex($0)?.int32Value ?? 0) }
        return makeWindow(
            id: Int(id),
            sessionName: r.atIndex(2)?.stringValue ?? "",
            path: r.atIndex(5)?.stringValue ?? "",
            frame: CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1]),
            processing: r.atIndex(4)?.booleanValue ?? false,
            jobName: r.atIndex(6)?.stringValue ?? "",
            commandLine: r.atIndex(7)?.stringValue ?? ""
        )
    }
    let activeId = Int(output.atIndex(2)?.int32Value ?? 0)
    return ITermState(windows: windows, activeId: activeId > 0 ? activeId : nil)
}

func raiseITermWindow(_ windowId: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
        AppleScriptRunner.shared.run("""
        tell application "iTerm2"
            activate
            select (first window whose id is \(windowId))
        end tell
        """, label: "raiseITermWindow")
    }
}

/// Opens a login shell in `path`, in a new iTerm2 window centered on `screen`.
@MainActor
func openITermWindow(path: String, on screen: NSScreen) {
    let targetPath = normalize(path)
    log("openITermWindow: \(targetPath)")

    let sf = screen.frame
    let size = CGSize(width: min(800, sf.width * 0.7), height: min(600, sf.height * 0.7))
    let b = flipped(
        CGRect(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2, width: size.width, height: size.height),
        primaryHeight: primaryScreenHeight
    )
    let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let command = loginShellCommand(in: targetPath, shell: shellPath)
    let escapedCommand = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "iTerm2"
        activate
        set w to (create window with default profile command "\(escapedCommand)")
        set bounds of w to {\(Int(b.minX)), \(Int(b.minY)), \(Int(b.maxX)), \(Int(b.maxY))}
        select w
    end tell
    """

    DispatchQueue.global(qos: .userInitiated).async {
        guard AppleScriptRunner.shared.run(script, label: "openITermWindow") == nil else { return }
        // Fallback: let iTerm2 open the folder itself.
        DispatchQueue.main.async {
            guard let iTermURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: iTermBundleID) else {
                log("openITermWindow: iTerm2 is not installed")
                return
            }
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: targetPath, isDirectory: true)],
                withApplicationAt: iTermURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }
}

// MARK: - Screens

/// NSScreen.screens.first is always the primary (menu bar) display.
@MainActor
var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

@MainActor
func screen(for window: ITerm2Window) -> NSScreen? {
    let screens = NSScreen.screens
    return bestScreenIndex(for: window.frame, screens: screens.map(\.frame), primaryHeight: primaryScreenHeight)
        .map { screens[$0] }
}
