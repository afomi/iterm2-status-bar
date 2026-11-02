import Foundation
import Testing
@testable import iTermSidebar

// MARK: - Session title / path

@Test func prefersRealSessionPath() {
    let w = makeWindow(id: 1, sessionName: "claude — ~/elsewhere", path: "~/workspace/commons", frame: .zero, processing: false)
    #expect(w.title == "commons")
    #expect(w.dir == "commons")
    #expect(w.process == "Claude")
    #expect(w.llm == "Claude")
    #expect(w.path == NSString("~/workspace/commons").expandingTildeInPath)
}

@Test(arguments: [" — ", " - "])
func fallsBackToPathInSessionName(separator: String) {
    let w = makeWindow(id: 1, sessionName: "vim\(separator)~/workspace/foo", path: "", frame: .zero, processing: true)
    #expect(w.title == "foo — vim")
    #expect(w.path == NSString("~/workspace/foo").expandingTildeInPath)
}

@Test func keepsDashesThatAreNotAPathSuffix() {
    let w = makeWindow(id: 1, sessionName: "npm run dev - watch", path: "", frame: .zero, processing: false)
    #expect(w.title == "npm run dev - watch")
    #expect(w.dir == "npm run dev - watch")
}

@Test func agentWithNoDirectoryStillHasATitle() {
    let w = makeWindow(id: 1, sessionName: "claude", path: "", frame: .zero, processing: false)
    #expect(w.llm == "Claude")
    #expect(w.title == "Claude")
}

@Test func loginShellCommandQuotesEveryArgument() {
    #expect(loginShellCommand(in: "/tmp/my dir", shell: "/bin/zsh")
        == #"/bin/sh -c 'cd "$0"; exec "$1" -l' '/tmp/my dir' '/bin/zsh'"#)
}

@Test func normalizesNonBreakingSpaces() {
    let w = makeWindow(id: 1, sessionName: "zsh\u{00a0}—\u{202f}/tmp/x", path: "", frame: .zero, processing: false)
    #expect(w.title == "x — zsh")
}

// MARK: - AppleScript result parsing

private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let d = NSAppleEventDescriptor.list()
    for (i, item) in items.enumerated() { d.insert(item, at: i + 1) }
    return d
}
private func int(_ n: Int32) -> NSAppleEventDescriptor { NSAppleEventDescriptor(int32: n) }
private func str(_ s: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: s) }

private func record(
    id: Int32,
    name: String = "zsh",
    bounds: [Int32] = [10, 20, 110, 220],
    processing: Bool = false,
    path: String = "/tmp/p",
    jobName: String? = nil,
    commandLine: String? = nil
) -> NSAppleEventDescriptor {
    var items = [int(id), str(name), list(bounds.map(int)), NSAppleEventDescriptor(boolean: processing), str(path)]
    if let jobName {
        items.append(str(jobName))
        items.append(str(commandLine ?? ""))
    }
    return list(items)
}

@Test func parsesWindowsAndActiveId() throws {
    let output = list([list([record(id: 7, name: "a ||| b", processing: true), record(id: 9)]), int(9)])
    let state = try #require(parseITermState(output))
    #expect(state.activeId == 9)
    #expect(state.windows.map(\.id) == [7, 9])
    #expect(state.windows[0].title == "p — a ||| b")  // delimiter-looking text survives
    #expect(state.windows[0].isProcessing)
    #expect(state.windows[0].frame == CGRect(x: 10, y: 20, width: 100, height: 200))
}

@Test func dropsMalformedRecordsAndZeroActiveId() throws {
    let short = list([int(3), str("zsh")])
    let badBounds = record(id: 4, bounds: [1, 2])
    let output = list([list([short, badBounds, record(id: 5)]), int(0)])
    let state = try #require(parseITermState(output))
    #expect(state.windows.map(\.id) == [5])
    #expect(state.activeId == nil)
}

@Test func emptyWindowList() throws {
    let state = try #require(parseITermState(list([NSAppleEventDescriptor.list(), int(0)])))
    #expect(state.windows.isEmpty)
}

@Test func rejectsUnexpectedShape() {
    #expect(parseITermState(str("nope")) == nil)
}

@Test func readsForegroundJobFromTheRecord() throws {
    let output = list([
        list([record(id: 3, name: "zsh — ~/workspace/app", path: "/Users/me/workspace/app", jobName: "node", commandLine: "node /opt/claude-code/cli.js")]),
        int(3),
    ])
    let state = try #require(parseITermState(output))
    #expect(state.windows[0].llm == "Claude")
    #expect(state.windows[0].title == "app")
}

// MARK: - lsof

@Test func parsesLsofAndJoinsPortsToDirectories() {
    let listeners = parseLsof("p100\nf5\nn*:4001\nn[::1]:4001\np200\nn127.0.0.1:4002\nn127.0.0.1:4000\n")
    let pidPorts = listeningPorts(listeners)
    #expect(pidPorts == [100: [4001], 200: [4000, 4002]])

    let cwds = parseLsof("p100\nn/Users/me/a/\np200\nn/Users/me/b\np300\nn/Users/me/c\n")
    #expect(portsByDirectory(cwds: cwds, pidPorts: pidPorts) == ["/Users/me/a": [4001], "/Users/me/b": [4000, 4002]])
}

// MARK: - Pinned paths

@Test func portRangeFallsBackToTheDefault() {
    #expect(validPortRange("3000-4999") == "3000-4999")
    for bad in [nil, "", "4000", "5000-4000", "0-100", "1-70000", "a-b", "1-2-3", "-iTCP"] {
        #expect(validPortRange(bad) == defaultPortRange)
    }
}

@Test func parsesPinnedPaths() {
    let contents = """
    # comment
    ~/workspace/a
      /tmp/b

    /tmp/b/
    ~/workspace/a
    """
    #expect(parsePinnedPaths(contents) == [NSString("~/workspace/a").expandingTildeInPath, "/tmp/b"])
}

// MARK: - Geometry

@Test func flipIsItsOwnInverse() {
    let r = CGRect(x: 1, y: 2, width: 3, height: 4)
    #expect(flipped(r, primaryHeight: 1000) == CGRect(x: 1, y: 994, width: 3, height: 4))
    #expect(flipped(flipped(r, primaryHeight: 1000), primaryHeight: 1000) == r)
}

@Test func assignsWindowToScreenHoldingMostOfIt() {
    // Primary 1000x800 at origin; second display to its right.
    let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
    let mostlyRight = CGRect(x: 900, y: 100, width: 400, height: 300)  // top-left coords
    #expect(bestScreenIndex(for: mostlyRight, screens: screens, primaryHeight: 800) == 1)
    let atTopEdge = CGRect(x: 10, y: 0, width: 100, height: 100)
    #expect(bestScreenIndex(for: atTopEdge, screens: screens, primaryHeight: 800) == 0)
    let offScreen = CGRect(x: 100, y: -900, width: 100, height: 100)
    #expect(bestScreenIndex(for: offScreen, screens: screens, primaryHeight: 800) == nil)
}

// MARK: - Session mark

@Test func workingOutranksFocus() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    #expect(sessionMark(isProcessing: true, isFocused: true, needsReview: false, leftFocusAt: nil, now: now) == .working)
}

@Test func focusedIdleWindowIsActive() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    #expect(sessionMark(isProcessing: false, isFocused: true, needsReview: true, leftFocusAt: nil, now: now) == .active)
}

@Test func unseenCompletionStaysBlueUntilFocused() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let busy = [SessionSnapshot(id: 7, isProcessing: true)]
    var attention = updateAttention(SessionAttention(), windows: busy, focusedId: nil, now: start)
    attention = updateAttention(
        attention,
        windows: [SessionSnapshot(id: 7, isProcessing: false)],
        focusedId: nil,
        now: start.addingTimeInterval(2)
    )
    #expect(attention.needsReview == Set([7]))
    #expect(sessionMark(
        isProcessing: false, isFocused: false, needsReview: true, leftFocusAt: nil,
        now: start.addingTimeInterval(recentIdleInterval + 10)
    ) == .review)

    attention = updateAttention(attention, windows: [SessionSnapshot(id: 7, isProcessing: false)], focusedId: 7, now: start.addingTimeInterval(5))
    #expect(attention.needsReview.isEmpty)
}

@Test func leavingAWindowIsBlueThenDormant() throws {
    let start = Date(timeIntervalSinceReferenceDate: 5_000)
    var attention = updateAttention(SessionAttention(), windows: [SessionSnapshot(id: 1, isProcessing: false)], focusedId: 1, now: start)
    attention = updateAttention(attention, windows: [SessionSnapshot(id: 1, isProcessing: false)], focusedId: nil, now: start.addingTimeInterval(10))
    let left = try #require(attention.leftFocusAt[1])
    #expect(sessionMark(isProcessing: false, isFocused: false, needsReview: false, leftFocusAt: left, now: left.addingTimeInterval(10)) == .review)
    #expect(sessionMark(isProcessing: false, isFocused: false, needsReview: false, leftFocusAt: left, now: left.addingTimeInterval(recentIdleInterval)) == .dormant)
}

@Test func completionWhileFocusedIsNotAReview() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    var attention = updateAttention(SessionAttention(), windows: [SessionSnapshot(id: 4, isProcessing: true)], focusedId: 4, now: now)
    attention = updateAttention(attention, windows: [SessionSnapshot(id: 4, isProcessing: false)], focusedId: 4, now: now.addingTimeInterval(1))
    #expect(attention.needsReview.isEmpty)
}

@Test func firstPollDoesNotInventAReview() {
    let attention = updateAttention(SessionAttention(), windows: [SessionSnapshot(id: 2, isProcessing: false)], focusedId: nil, now: Date())
    #expect(attention.needsReview.isEmpty)
    #expect(sessionMark(isProcessing: false, isFocused: false, needsReview: false, leftFocusAt: nil, now: Date()) == .dormant)
}

// MARK: - LLM job name

@Test func namesKnownAgents() {
    #expect(identifyLLM(jobName: "claude", commandLine: "") == "Claude")
    #expect(identifyLLM(jobName: "/opt/homebrew/bin/codex", commandLine: "codex") == "Codex")
    #expect(identifyLLM(jobName: "grok", commandLine: "grok") == "Grok")
    #expect(identifyLLM(jobName: "claude.exe", commandLine: "") == "Claude")
    #expect(identifyLLM(jobName: "grok-1", commandLine: "") == "Grok")
    #expect(identifyLLM(jobName: "grok-1.2.3", commandLine: "") == "Grok")
    #expect(identifyLLM(jobName: "zsh", commandLine: "-zsh") == nil)
    #expect(identifyLLM(jobName: "vim", commandLine: "vim /Users/me/claude/notes.txt") == nil)
}

@Test func namesAnAgentBehindARuntime() {
    #expect(identifyLLM(jobName: "node", commandLine: "node /opt/claude-code/cli.js") == "Claude")
    #expect(identifyLLM(jobName: "npx", commandLine: "npx @openai/codex") == "Codex")
    #expect(identifyLLM(jobName: "node", commandLine: "node /Users/me/claude/server.js") == nil)
}

@Test func liveJobReplacesTheSessionTitle() {
    let w = makeWindow(
        id: 1, sessionName: "zsh — ~/workspace/app", path: "/tmp/app", frame: .zero, processing: false,
        jobName: "codex", commandLine: "codex --full-auto"
    )
    #expect(w.llm == "Codex")
    #expect(w.title == "app")
}

@Test func tabWidthsShareTheShelfUntilTheyWouldGetTooNarrow() {
    #expect(tabWidth(available: 1000, count: 2) == tabMaxWidth)
    #expect(tabWidth(available: 800, count: 4) == 200)
    #expect(tabWidth(available: 1000, count: 10) == tabMinWidth)
    #expect(tabWidth(available: 500, count: 0) == tabMaxWidth)
}

@Test func clampsWindowsZoomedUnderSidebar() {
    let sidebar = CGRect(x: 780, y: 0, width: 220, height: 800)  // right edge of a 1000-wide screen
    let zoomed = CGRect(x: 0, y: 25, width: 1000, height: 775)
    #expect(clampedWidth(for: zoomed, sidebars: [sidebar], minimumWidth: 300) == 780)
    // Clear of the sidebar, parked behind it, too narrow, or spanning onto the next display: untouched.
    #expect(clampedWidth(for: CGRect(x: 0, y: 0, width: 700, height: 500), sidebars: [sidebar], minimumWidth: 300) == nil)
    #expect(clampedWidth(for: CGRect(x: 800, y: 0, width: 150, height: 500), sidebars: [sidebar], minimumWidth: 300) == nil)
    #expect(clampedWidth(for: CGRect(x: 600, y: 0, width: 300, height: 500), sidebars: [sidebar], minimumWidth: 300) == nil)
    #expect(clampedWidth(for: CGRect(x: 500, y: 0, width: 900, height: 500), sidebars: [sidebar], minimumWidth: 300) == nil)
}

@Test func sortsByFolderUnlessAttentionIsAskedFor() {
    let windows = [
        makeWindow(id: 1, sessionName: "zsh — ~/zeta", path: "/tmp/zeta", frame: .zero, processing: false),
        makeWindow(id: 2, sessionName: "zsh — ~/alpha", path: "/tmp/alpha", frame: .zero, processing: false),
        makeWindow(id: 3, sessionName: "zsh — ~/mid", path: "/tmp/mid", frame: .zero, processing: true),
        makeWindow(id: 4, sessionName: "zsh — ~/beta", path: "/tmp/beta", frame: .zero, processing: false),
    ]
    let marks: [Int: SessionMark] = [1: .dormant, 2: .review, 3: .working, 4: .active]
    #expect(sortedForSidebar(windows, marks: marks, order: .project).map(\.id) == [2, 4, 3, 1])
    #expect(sortedForSidebar(windows, marks: marks, order: .attention).map(\.id) == [3, 2, 4, 1])
    // A missing mark counts as dormant, then directory order.
    let tied = [
        makeWindow(id: 8, sessionName: "zsh — ~/b", path: "/tmp/b", frame: .zero, processing: false),
        makeWindow(id: 9, sessionName: "zsh — ~/a", path: "/tmp/a", frame: .zero, processing: false),
    ]
    #expect(sortedForSidebar(tied, marks: [:], order: .attention).map(\.id) == [9, 8])
}

@Test func clampedFramePullsWindowsOutFromUnderTheBarAndTheShelf() {
    let sidebar = CGRect(x: 780, y: 0, width: 220, height: 800)
    let zoomed = CGRect(x: 0, y: 25, width: 1000, height: 775)
    let trimmed = clampedFrame(for: zoomed, reserved: [sidebar], minimumWidth: 300)
    #expect(trimmed?.width == 780)
    #expect(trimmed?.origin == zoomed.origin)
    #expect(trimmed?.height == zoomed.height)

    let shelf = CGRect(x: 0, y: 25, width: 1440, height: 42)
    let underShelf = CGRect(x: 0, y: 25, width: 1440, height: 775)
    let dropped = clampedFrame(for: underShelf, reserved: [shelf], minimumWidth: 300)
    #expect(dropped?.origin.y == 67)
    #expect(dropped?.height == 733)
    #expect(dropped?.width == 1440)
    #expect(dropped?.origin.x == 0)

    // A drag that overlaps the bar, but is not pinned to the screen edge, stays put.
    let drag = CGRect(x: 100, y: 25, width: 750, height: 600) // maxX 850, sidebar maxX 1000
    #expect(clampedFrame(for: drag, reserved: [sidebar], minimumWidth: 300, requireOuterEdge: true) == nil)
    #expect(clampedFrame(for: drag, reserved: [sidebar], minimumWidth: 300)?.width == 680)

    // The same window, zoomed so its right edge meets the bar's right edge, is trimmed.
    let atEdge = CGRect(x: 200, y: 25, width: 800, height: 775) // maxX 1000
    let edge = clampedFrame(for: atEdge, reserved: [sidebar], minimumWidth: 300, requireOuterEdge: true)
    #expect(edge?.width == 580)
    #expect(edge?.origin == atEdge.origin)

    // A window whose top sits down inside the shelf is a drag, not a zoom.
    let intoShelf = CGRect(x: 0, y: 50, width: 1440, height: 600)
    #expect(clampedFrame(for: intoShelf, reserved: [shelf], minimumWidth: 300, requireOuterEdge: true) == nil)
    #expect(clampedFrame(for: intoShelf, reserved: [shelf], minimumWidth: 300)?.origin.y == 67)

    // Dragged flush to the top, under the shelf: a move alone never shortens it.
    let dragToTop = CGRect(x: 0, y: 25, width: 1440, height: 600)
    #expect(clampedFrame(for: dragToTop, reserved: [shelf], minimumWidth: 300, requireOuterEdge: true) == nil)

    // Continues onto the next display, or starts on a display above the shelf: untouched.
    #expect(clampedFrame(for: CGRect(x: 500, y: 0, width: 900, height: 500), reserved: [sidebar], minimumWidth: 300) == nil)
    #expect(clampedFrame(for: CGRect(x: 0, y: -700, width: 1440, height: 1500), reserved: [shelf], minimumWidth: 300) == nil)
}
