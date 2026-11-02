import Foundation

struct ITerm2Window: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let dir: String      // sort group
    let process: String  // sort within group; agent label when recognized
    let path: String     // full expanded path from iTerm2 session
    let frame: CGRect    // iTerm2 bounds, top-left coords
    let isProcessing: Bool
    let llm: String?     // Claude, Codex, Grok, … nil when the job isn't a known agent
}

struct ITermState: Equatable, Sendable {
    var windows: [ITerm2Window]
    var activeId: Int?
}

func makeWindow(
    id: Int,
    sessionName: String,
    path: String,
    frame: CGRect,
    processing: Bool,
    jobName: String = "",
    commandLine: String = ""
) -> ITerm2Window {
    // Prefer the real path from iTerm2; fall back to parsing the session name "proc — ~/path"
    var resolvedPath = (path as NSString).expandingTildeInPath
    var dir = (resolvedPath as NSString).lastPathComponent
    let normalizedSessionName = sessionName
        .replacingOccurrences(of: "\u{00a0}", with: " ")
        .replacingOccurrences(of: "\u{202f}", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var procName = normalizedSessionName
    for sep in [" — ", " - "] {
        if let range = normalizedSessionName.range(of: sep, options: .backwards) {
            let candidate = String(normalizedSessionName[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let pathPart = String(normalizedSessionName[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if pathPart.hasPrefix("/") || pathPart.hasPrefix("~") {
                procName = candidate
                if dir.isEmpty {
                    resolvedPath = (pathPart as NSString).expandingTildeInPath
                    dir = (resolvedPath as NSString).lastPathComponent
                }
                break
            }
        }
    }
    let shown = displayedProcess(parsed: procName, jobName: jobName, commandLine: commandLine)
    // The agent mark carries Claude / Grok / Codex. The row text stays the directory.
    let display = dir.isEmpty ? shown.process : (shown.llm != nil ? dir : "\(dir) — \(shown.process)")
    return ITerm2Window(
        id: id,
        title: display,
        dir: dir.isEmpty ? shown.process : dir,
        process: shown.process,
        path: resolvedPath,
        frame: frame,
        isProcessing: processing,
        llm: shown.llm
    )
}

func normalize(_ path: String) -> String {
    URL(fileURLWithPath: path).standardized.path
}

/// Starts a login shell in `path`. `env -C` needs a newer macOS than the app targets.
/// `;`, not `&&`: a missing folder prints the error and still leaves a working shell.
func loginShellCommand(in path: String, shell: String) -> String {
    "/bin/sh -c \(shellQuote("cd \"$0\"; exec \"$1\" -l")) \(shellQuote(path)) \(shellQuote(shell))"
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
