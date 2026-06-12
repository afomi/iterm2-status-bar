import Cocoa
import SwiftUI

// MARK: - Data

struct ITerm2Window: Identifiable {
    let id: Int
    let title: String
    let origin: CGPoint  // top-left in iTerm2/screen coords
    let isProcessing: Bool
}

func fetchITermWindows() -> [ITerm2Window] {
    let script = """
    tell application "iTerm2"
        set info to {}
        repeat with i from 1 to count of windows
            set w to window i
            set b to bounds of w
            set x1 to item 1 of b
            set y1 to item 2 of b
            set proc to is processing of current session of current tab of w
            set end of info to (i as string) & "|||" & (name of w) & "|||" & (x1 as string) & "|||" & (y1 as string) & "|||" & (proc as string)
        end repeat
        return info
    end tell
    """
    var error: NSDictionary?
    guard let src = NSAppleScript(source: script) else { return [] }
    let output = src.executeAndReturnError(&error)
    if error != nil { return [] }
    var result: [ITerm2Window] = []
    let count = output.numberOfItems
    if count > 0 {
        for i in 1...count {
            if let item = output.atIndex(i), let raw = item.stringValue {
                let parts = raw.components(separatedBy: "|||")
                guard parts.count == 5,
                      let id = Int(parts[0]),
                      let x = Double(parts[2]),
                      let y = Double(parts[3]) else { continue }
                let processing = parts[4].trimmingCharacters(in: .whitespaces) == "true"
                result.append(ITerm2Window(id: id, title: parts[1], origin: CGPoint(x: CGFloat(x), y: CGFloat(y)), isProcessing: processing))
            }
        }
    } else if let raw = output.stringValue {
        let parts = raw.components(separatedBy: "|||")
        if parts.count == 5, let id = Int(parts[0]), let x = Double(parts[2]), let y = Double(parts[3]) {
            let processing = parts[4].trimmingCharacters(in: .whitespaces) == "true"
            result.append(ITerm2Window(id: id, title: parts[1], origin: CGPoint(x: x, y: y), isProcessing: processing))
        }
    }
    return result
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

func fetchActiveITermWindowIndex() -> Int? {
    let script = """
    tell application "iTerm2"
        set w to current window
        set wList to windows
        repeat with i from 1 to count of wList
            if item i of wList is w then return i
        end repeat
        return 0
    end tell
    """
    var error: NSDictionary?
    guard let src = NSAppleScript(source: script) else { return nil }
    let result = src.executeAndReturnError(&error)
    if error != nil { return nil }
    let idx = result.int32Value
    return idx > 0 ? Int(idx) : nil
}

// MARK: - Store

class WindowStore: ObservableObject {
    @Published var windows: [ITerm2Window] = []
    @Published var activeId: Int? = nil
    var onRefresh: (() -> Void)?

    func refresh() {
        DispatchQueue.global(qos: .background).async {
            let fetched = fetchITermWindows()
            let active = fetchActiveITermWindowIndex()
            DispatchQueue.main.async {
                self.windows = fetched
                if let active = active {
                    self.activeId = active
                }
                self.onRefresh?()
            }
        }
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
                          : hovered ? Color.primary.opacity(0.08) : Color.clear)
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
        store.windows(onScreen: screen).sorted { $0.title < $1.title }
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

            if visibleWindows.isEmpty {
                Text("No windows on this screen")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visibleWindows) { win in
                            WindowRow(
                                window: win,
                                isActive: store.activeId == win.id,
                                onTap: { store.activate(win) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
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
        for entry in panels {
            let hasWindows = !store.windows(onScreen: entry.screen).isEmpty
            if hasWindows {
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
