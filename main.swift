import Cocoa
import SwiftUI

// MARK: - Data

struct ITerm2Window: Identifiable {
    let id: Int
    let title: String
    let sortKey: (dir: String, process: String)
    let path: String  // full expanded path from iTerm2 session
    let origin: CGPoint  // top-left in iTerm2/screen coords
    let isProcessing: Bool
}

func makeWindow(id: Int, sessionName: String, path: String, x: Double, y: Double, processing: Bool) -> ITerm2Window {
    // Prefer the real path from iTerm2; fall back to parsing the session name "proc — ~/path"
    var dir = (path as NSString).lastPathComponent
    var procName = sessionName
    if dir.isEmpty {
        for sep in [" — ", " - "] {
            if let range = sessionName.range(of: sep) {
                procName = String(sessionName[..<range.lowerBound])
                let pathPart = String(sessionName[range.upperBound...])
                dir = (pathPart as NSString).lastPathComponent
                break
            }
        }
    }
    let display = dir.isEmpty ? procName : "\(dir) — \(procName)"
    let sortDir = dir.isEmpty ? procName : dir
    return ITerm2Window(id: id, title: display, sortKey: (sortDir, procName), path: path, origin: CGPoint(x: x, y: y), isProcessing: processing)
}

func fetchITermState() -> (windows: [ITerm2Window], activeId: Int?)? {
    let script = """
    tell application "iTerm2"
        set info to {}
        set activeIdx to 0
        set wList to windows
        set cw to current window
        repeat with i from 1 to count of wList
            set w to item i of wList
            if w is cw then set activeIdx to i
            set b to bounds of w
            set x1 to item 1 of b
            set y1 to item 2 of b
            set s to current session of current tab of w
            set proc to is processing of s
            set sessionName to name of s
            set sessionPath to ""
            try
                set sessionPath to path of s
            end try
            set end of info to (i as string) & "|||" & sessionName & "|||" & (x1 as string) & "|||" & (y1 as string) & "|||" & (proc as string) & "|||" & sessionPath
        end repeat
        set end of info to "active|||" & (activeIdx as string)
        return info
    end tell
    """
    var error: NSDictionary?
    guard let src = NSAppleScript(source: script) else { return nil }
    let output = src.executeAndReturnError(&error)
    if error != nil { return nil }
    var result: [ITerm2Window] = []
    var activeId: Int? = nil
    let count = output.numberOfItems
    let items: [String] = count > 0
        ? (1...count).compactMap { output.atIndex($0)?.stringValue }
        : output.stringValue.map { [$0] } ?? []
    for raw in items {
        let parts = raw.components(separatedBy: "|||")
        if parts[0] == "active" {
            activeId = Int(parts[1].trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        } else if parts.count == 6,
                  let id = Int(parts[0]),
                  let x = Double(parts[2]),
                  let y = Double(parts[3]) {
            let processing = parts[4].trimmingCharacters(in: .whitespaces) == "true"
            result.append(makeWindow(id: id, sessionName: parts[1], path: parts[5], x: x, y: y, processing: processing))
        }
    }
    return (result, activeId)
}

// iTerm2 uses flipped (top-left origin) coords. Convert to NSScreen Quartz coords for hit-testing.
// NSScreen.screens[0].frame.height gives the primary screen height for the flip.
func quartzPoint(fromITermOrigin p: CGPoint) -> CGPoint {
    let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? 0
    return CGPoint(x: p.x, y: primaryH - p.y)
}

func screen(for window: ITerm2Window) -> NSScreen? {
    let qp = quartzPoint(fromITermOrigin: window.origin)
    return NSScreen.screens.first { $0.frame.contains(qp) }
}

func raiseITermWindow(_ index: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
        let script = """
        tell application "iTerm2"
            activate
            select window \(index)
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}

func openITermWindow(path: String) {
    log("openITermWindow: \(path)")
    // Launch a login shell directly in the target directory via /usr/bin/open
    let url = URL(fileURLWithPath: path, isDirectory: true)
    NSWorkspace.shared.open(
        [url],
        withApplicationAt: URL(fileURLWithPath: "/Applications/iTerm.app"),
        configuration: NSWorkspace.OpenConfiguration()
    )
}

func normalize(_ path: String) -> String {
    URL(fileURLWithPath: path).standardized.path
}

func loadPinnedPaths() -> [String] {
    let raw = ("~/.config/iterm-sidebar/pinned.txt" as NSString).expandingTildeInPath
    guard let contents = try? String(contentsOfFile: raw, encoding: .utf8) else { return [] }
    return contents.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .map { ($0 as NSString).expandingTildeInPath }
}


// MARK: - Store

class WindowStore: ObservableObject {
    @Published var windows: [ITerm2Window] = []
    @Published var activeId: Int? = nil
    @Published var pinnedPaths: [String] = []
    var onRefresh: (() -> Void)?
    private var refreshInFlight = false

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .background).async {
            let state = fetchITermState()
            let pinned = loadPinnedPaths()
            DispatchQueue.main.async {
                self.refreshInFlight = false
                guard let state = state else { return }
                self.windows = state.windows // .map(applyDemoMode)  // enable in demo.swift
                self.pinnedPaths = pinned
                if let active = state.activeId { self.activeId = active }
                self.onRefresh?()
            }
        }
    }

    func unpinnedPaths(from pinned: [String]) -> [String] {
        let openPaths = Set(windows.map { $0.path }.filter { !$0.isEmpty }.map { normalize($0) })
        return pinned.filter { !openPaths.contains(normalize($0)) }
    }

    func windows(onScreen s: NSScreen) -> [ITerm2Window] {
        windows.filter { screen(for: $0) == s }
    }

    func activate(_ w: ITerm2Window) {
        activeId = w.id  // optimistic highlight
        raiseITermWindow(w.id)
    }
}

// MARK: - SwiftUI sidebar view

struct WindowRow: View {
    let window: ITerm2Window
    let isActive: Bool
    let isPinned: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(window.isProcessing ? Color.yellow : Color.green)
                    .frame(width: 7, height: 7)
                Text(window.title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive
                          ? Color.accentColor.opacity(0.25)
                          : hovered ? Color.primary.opacity(0.08)
                          : isPinned ? Color.clear : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
    }
}

struct PinnedRow: View {
    let path: String
    @State private var hovered = false

    var body: some View {
        Button(action: { openITermWindow(path: path) }) {
            HStack(spacing: 6) {
                Text("+")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 7)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
    }
}

struct SidebarView: View {
    @ObservedObject var store: WindowStore
    let screen: NSScreen

    var visibleWindows: [ITerm2Window] {
        store.windows(onScreen: screen).sorted {
            if $0.sortKey.dir != $1.sortKey.dir { return $0.sortKey.dir < $1.sortKey.dir }
            return $0.sortKey.process < $1.sortKey.process
        }
    }

    var pinnedUnopened: [String] {
        store.unpinnedPaths(from: store.pinnedPaths)
    }

    var pinnedSet: Set<String> {
        Set(store.pinnedPaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(screen.localizedName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(visibleWindows) { win in
                        WindowRow(
                            window: win,
                            isActive: store.activeId == win.id,
                            isPinned: pinnedSet.contains(win.path),
                            onTap: { store.activate(win) }
                        )
                    }

                    if !pinnedUnopened.isEmpty {
                        Text("Pinned")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, visibleWindows.isEmpty ? 8 : 12)
                            .padding(.bottom, 2)

                        ForEach(pinnedUnopened, id: \.self) { path in
                            PinnedRow(path: path)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panels: [(panel: NSPanel, screen: NSScreen)] = []
    var statusItem: NSStatusItem!
    let store = WindowStore()
    var timer: Timer?

    private var launched = false
    var lastRefresh: Date = .distantPast
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !launched else { return }
        launched = true
        log("applicationDidFinishLaunching screens=\(NSScreen.screens.count)")

        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )

        setupStatusItem()
        setupPanels()

        store.onRefresh = { [weak self] in self?.updatePanelVisibility() }

        // Start polling after panels are up
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let interval: TimeInterval = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.googlecode.iterm2" ? 1 : 10
            let now = Date()
            guard let last = self?.lastRefresh, now.timeIntervalSince(last) >= interval else { return }
            self?.lastRefresh = now
            self?.store.refresh()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        panels.forEach { $0.panel.orderOut(nil) }
        panels.removeAll()
        setupPanels()
    }

    private func updatePanelVisibility() {
        let hasPinned = !store.unpinnedPaths(from: store.pinnedPaths).isEmpty
        for entry in panels {
            let hasWindows = !store.windows(onScreen: entry.screen).isEmpty
            if hasWindows || hasPinned {
                entry.panel.orderFrontRegardless()
            } else {
                entry.panel.orderOut(nil)
            }
        }
    }

    private func setupPanels() {
        for screen in NSScreen.screens {
            let w: CGFloat = 220
            let f = NSRect(x: screen.frame.maxX - w, y: screen.frame.minY, width: w, height: screen.frame.height)
            log("Panel on '\(screen.localizedName)' at \(f)")

            let panel = NSPanel(
                contentRect: f,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
            panel.isOpaque = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isMovableByWindowBackground = true

            let hostingView = NSHostingView(rootView: SidebarView(store: store, screen: screen))
            hostingView.frame = NSRect(origin: .zero, size: f.size)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            panel.setFrame(f, display: true)
            panel.orderFrontRegardless()

            NSLog("Panel visible=%d screen='%@'", panel.isVisible ? 1 : 0, panel.screen?.localizedName ?? "nil")
            panels.append((panel: panel, screen: screen))
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                return true
            }
            btn.image = img
            btn.action = #selector(iconClicked)
            btn.target = self
        }
    }

    @objc private func iconClicked() {
        let allVisible = panels.allSatisfy { $0.panel.isVisible }
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: allVisible ? "Hide Sidebar" : "Show Sidebar",
            action: #selector(togglePanels),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePanels() {
        let allVisible = panels.allSatisfy { $0.panel.isVisible }
        panels.forEach { allVisible ? $0.panel.orderOut(nil) : $0.panel.orderFrontRegardless() }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.regular)  // must be .regular for runloop + timers to work
let delegate = AppDelegate()
app.delegate = delegate

func log(_ msg: String) {
    NSLog("%@", msg)
    let line = "\(msg)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/iterm-sidebar-debug.log"
        if FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

log("app starting, screens=\(NSScreen.screens.count)")

Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
    log("timer fired — screens=\(NSScreen.screens.count)")
    app.setActivationPolicy(.accessory)
    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )
}

app.run()
