import Cocoa

@MainActor
final class WindowStore: ObservableObject {
    @Published var windows: [ITerm2Window] = []
    @Published var activeId: Int? = nil
    @Published var pinnedPaths: [String] = []
    @Published var portMap: [String: [Int]] = [:]  // normalizedPath -> [port]
    @Published private(set) var marks: [Int: SessionMark] = [:]
    /// Folder order, or working / review / focused / dormant. The menu toggles this.
    @Published var sortOrder: SidebarSort = Prefs.sort
    var onRefresh: (() -> Void)?
    private var refreshInFlight = false
    private var attention = SessionAttention()

    private struct Snapshot: Sendable {
        let state: ITermState?
        let pinned: [String]
        let ports: [String: [Int]]
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task {
            let snapshot = await Task.detached(priority: .background) {
                Snapshot(state: fetchITermState(), pinned: loadPinnedPaths(), ports: fetchPortMap())
            }.value
            apply(snapshot)
            refreshInFlight = false
            onRefresh?()
        }
    }

    /// Only assigns what changed, to avoid spurious SwiftUI redraws.
    /// On a failed iTerm query, keeps the last known windows rather than flashing empty.
    /// Marks are recomputed on every attempt so a window you left can fade from blue to gray.
    private func apply(_ snapshot: Snapshot) {
        let now = Date()
        if let state = snapshot.state {
            let windows = state.windows.map(applyDemoMode)  // no-op unless demoMode in Demo.swift
            attention = updateAttention(
                attention,
                windows: windows.map { SessionSnapshot(id: $0.id, isProcessing: $0.isProcessing) },
                focusedId: state.activeId,
                now: now
            )
            if windows != self.windows { self.windows = windows }
            if state.activeId != activeId { activeId = state.activeId }
        }
        if snapshot.pinned != pinnedPaths { pinnedPaths = snapshot.pinned }
        if snapshot.ports != portMap { portMap = snapshot.ports }
        publishMarks(now: now)
    }

    private func publishMarks(now: Date) {
        let focused = activeId
        let next = Dictionary(uniqueKeysWithValues: windows.map { window in
            (window.id, sessionMark(
                isProcessing: window.isProcessing,
                isFocused: window.id == focused,
                needsReview: attention.needsReview.contains(window.id),
                leftFocusAt: attention.leftFocusAt[window.id],
                now: now
            ))
        })
        if next != marks { marks = next }
    }

    var unopenedPinnedPaths: [String] {
        let openPaths = Set(windows.map(\.path).filter { !$0.isEmpty }.map(normalize))
        return pinnedPaths.filter { !openPaths.contains(normalize($0)) }
    }

    func windows(onScreen s: NSScreen) -> [ITerm2Window] {
        windows.filter { screen(for: $0) == s }
    }

    func setSort(_ order: SidebarSort) {
        Prefs.sort = order
        sortOrder = order
    }

    func activate(_ w: ITerm2Window) {
        let now = Date()
        attention = updateAttention(
            attention,
            windows: windows.map { SessionSnapshot(id: $0.id, isProcessing: $0.isProcessing) },
            focusedId: w.id,
            now: now
        )
        activeId = w.id  // optimistic highlight; clears "needs review" for this window
        publishMarks(now: now)
        raiseITermWindow(w.id)
    }
}
