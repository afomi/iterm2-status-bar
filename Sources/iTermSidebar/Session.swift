import Foundation

/// How long a window you just left stays blue before it counts as dormant.
/// A window whose job stopped while you were elsewhere stays blue until you focus it,
/// even after this interval.
let recentIdleInterval: TimeInterval = 3 * 60

/// Dot on a sidebar row.
/// Working wins over focus: the row highlight already shows which window is selected.
enum SessionMark: Equatable, Sendable {
    /// iTerm reports the session received output recently.
    case working
    /// This is the focused iTerm window, and it is idle.
    case active
    /// Idle, not focused, and either the job just stopped unseen or you just left it.
    case review
    /// Idle, not focused, nothing new.
    case dormant

    var label: String {
        switch self {
        case .working: "Working"
        case .active: "Active"
        case .review: "Needs review"
        case .dormant: "Dormant"
        }
    }
}

struct SessionSnapshot: Equatable, Sendable {
    var id: Int
    var isProcessing: Bool
}

/// Memory across polls. Value type so the transitions can be tested without the store.
struct SessionAttention: Equatable, Sendable {
    var needsReview: Set<Int> = []
    var wasProcessing: [Int: Bool] = [:]
    var leftFocusAt: [Int: Date] = [:]
    var focusedId: Int? = nil
}

func updateAttention(
    _ attention: SessionAttention,
    windows: [SessionSnapshot],
    focusedId: Int?,
    now: Date
) -> SessionAttention {
    var next = attention
    let live = Set(windows.map(\.id))

    if attention.focusedId != focusedId {
        if let previous = attention.focusedId {
            next.leftFocusAt[previous] = now
        }
        if let focusedId {
            next.needsReview.remove(focusedId)
            next.leftFocusAt[focusedId] = nil
        }
        next.focusedId = focusedId
    }

    for window in windows {
        let was = attention.wasProcessing[window.id] ?? false
        // A job that stops while this window is focused was seen. Only flag the ones that stop off to the side.
        if was && !window.isProcessing && window.id != focusedId {
            next.needsReview.insert(window.id)
        }
        next.wasProcessing[window.id] = window.isProcessing
    }

    next.needsReview.formIntersection(live)
    next.wasProcessing = next.wasProcessing.filter { live.contains($0.key) }
    next.leftFocusAt = next.leftFocusAt.filter { live.contains($0.key) }
    if let focused = next.focusedId, !live.contains(focused) {
        next.focusedId = nil
    }
    return next
}

func attentionRank(_ mark: SessionMark) -> Int {
    switch mark {
    case .working: 0
    case .review: 1
    case .active: 2
    case .dormant: 3
    }
}

func sortedForSidebar(_ windows: [ITerm2Window], marks: [Int: SessionMark], order: SidebarSort) -> [ITerm2Window] {
    switch order {
    case .project:
        return windows.sorted { ($0.dir, $0.process, $0.id) < ($1.dir, $1.process, $1.id) }
    case .attention:
        return windows.sorted {
            let lhs = (attentionRank(marks[$0.id] ?? .dormant), $0.dir, $0.process, $0.id)
            let rhs = (attentionRank(marks[$1.id] ?? .dormant), $1.dir, $1.process, $1.id)
            return lhs < rhs
        }
    }
}

func sessionMark(
    isProcessing: Bool,
    isFocused: Bool,
    needsReview: Bool,
    leftFocusAt: Date?,
    now: Date,
    recentIdle: TimeInterval = recentIdleInterval
) -> SessionMark {
    if isProcessing { return .working }
    if isFocused { return .active }
    if needsReview { return .review }
    if let leftFocusAt, now.timeIntervalSince(leftFocusAt) < recentIdle { return .review }
    return .dormant
}

// MARK: - Which program is in the foreground

private let llmByExecutable: [String: String] = [
    "claude": "Claude",
    "claude-code": "Claude",
    "codex": "Codex",
    "grok": "Grok",
    "gemini": "Gemini",
    "aider": "Aider",
    "copilot": "Copilot",
    "amp": "Amp",
    "opencode": "OpenCode",
    "goose": "Goose",
    "cursor-agent": "Cursor",
    "qwen": "Qwen",
    "chatgpt": "ChatGPT",
    "openhands": "OpenHands",
    "cline": "Cline",
    "windsurf": "Windsurf",
    "droid": "Droid",
    "kilo": "Kilo",
    "aichat": "AIChat",
    "ollama": "Ollama",
    "crush": "Crush",
    "pi": "Pi",
    "continue": "Continue",
]

/// Executables that wrap the real program. Their command line is scanned for an agent basename.
private let genericRuntimes: Set<String> = [
    "node", "nodejs", "python", "python3", "ruby", "bun", "deno",
    "npm", "npx", "pnpm", "yarn", "perl", "env",
]

/// Substrings that identify an agent when the foreground executable is a runtime, not the agent itself.
private let packageHints: [(String, String)] = [
    ("claude-code", "Claude"),
    ("@anthropic-ai/claude", "Claude"),
    ("@openai/codex", "Codex"),
    ("openai-codex", "Codex"),
    ("cursor-agent", "Cursor"),
    ("gemini-cli", "Gemini"),
]

private func basename(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// `claude.exe` and `grok-1` / `grok-1.2` count. `cursor-agent` does not, unless it is an exact name.
private func matchExecutable(_ name: String) -> String? {
    var base = basename(name).lowercased()
    if base.hasSuffix(".exe") { base.removeLast(4) }
    if let label = llmByExecutable[base] { return label }
    guard let dash = base.firstIndex(of: "-") else { return nil }
    let head = String(base[..<dash])
    let tail = base[base.index(after: dash)...]
    guard tail.first?.isNumber == true else { return nil }
    return llmByExecutable[head]
}

private func isGenericRuntime(_ name: String) -> Bool {
    let base = basename(name).lowercased()
    return genericRuntimes.contains(base) || base.hasPrefix("python3.")
}

/// Friendly agent name, or nil when the foreground job is a shell, editor, or anything else.
/// `jobName` is iTerm's foreground job (as of 3.7 it hides helper subprocesses such as an MCP server).
/// `commandLine` is consulted only when that job is a runtime (`node`, `npx`, …).
func identifyLLM(jobName: String, commandLine: String) -> String? {
    if let label = matchExecutable(jobName) { return label }
    let job = basename(jobName).lowercased()
    guard job.isEmpty || isGenericRuntime(jobName) else { return nil }
    for token in commandLine.split(whereSeparator: \.isWhitespace) {
        let raw = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let label = matchExecutable(raw) { return label }
        let lower = raw.lowercased()
        for (needle, label) in packageHints where lower.contains(needle) {
            return label
        }
    }
    return nil
}

/// Process string shown in the row, plus the agent label when we recognized one.
func displayedProcess(parsed: String, jobName: String, commandLine: String) -> (process: String, llm: String?) {
    let llm = identifyLLM(jobName: jobName.isEmpty ? parsed : jobName, commandLine: commandLine)
    if let llm { return (llm, llm) }
    if !jobName.isEmpty { return (basename(jobName), nil) }
    return (parsed, nil)
}
