import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panels: [SidebarPanel] = []
    var statusItem: NSStatusItem!
    let store = WindowStore()
    var timer: Timer?
    var lastRefresh: Date = .distantPast
    private var toggleSidebarItem: NSMenuItem!
    private var tabsItem: NSMenuItem!
    private var sortItem: NSMenuItem!
    private var reserveSpaceItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var reserveBlocked = false
    private lazy var reserver = SidebarSpaceReserver { [weak self] in
        guard Prefs.reserveSpace, let self else { return [] }
        return self.panels.filter { $0.panel.isVisible }.map { flipped($0.frame, primaryHeight: primaryScreenHeight) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching screens=\(NSScreen.screens.count)")

        // Accessibility is only used to keep other windows clear of the sidebar.
        if Prefs.reserveSpace { promptForAccessibility() }

        setupStatusItem()
        setupPanels()

        store.onRefresh = { [weak self] in self?.updatePanelVisibility() }

        store.refresh()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Polls every 1s while iTerm2 is frontmost, every 10s otherwise.
    @objc private func tick() {
        // A grant in System Settings arrives with no callback. Keep trying until it sticks.
        if Prefs.reserveSpace, !reserver.isAttached {
            reserver.attachIfTrusted()
        }
        if accessibilityMissing != reserveBlocked { updateMenu() }
        let interval: TimeInterval = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == iTermBundleID ? 1 : 10
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= interval else { return }
        lastRefresh = now
        store.refresh()
    }

    @objc private func screensChanged() {
        panels.forEach { $0.setVisible(false) }
        setupPanels()
        updatePanelVisibility()
    }

    private func setupPanels() {
        let retired = panels
        panels = NSScreen.screens.map { screen in
            SidebarPanel(screen: screen, store: store, onResize: { [weak self] in self?.reserver.sweep() })
        }
        retired.forEach { $0.setVisible(false) }
    }

    /// The only place panels are shown or hidden.
    private func updatePanelVisibility() {
        var appeared = false
        for p in panels {
            let hasContent = !store.windows(onScreen: p.screen).isEmpty || !store.unopenedPinnedPaths.isEmpty
            let show = Prefs.sidebarEnabled && hasContent
            guard show != p.panel.isVisible else { continue }
            p.setVisible(show)
            appeared = appeared || show
        }
        guard Prefs.reserveSpace else { return }
        let wasAttached = reserver.isAttached
        reserver.attachIfTrusted()
        // Visibility changes, and the moment Accessibility is granted while panels are already up.
        if appeared || (!wasAttached && reserver.isAttached) {
            reserver.sweep()
        }
    }

    /// The menu must not show a plain checkmark while no window is being kept clear.
    private var accessibilityMissing: Bool { Prefs.reserveSpace && !AXIsProcessTrusted() }

    private func promptForAccessibility() {
        // The constant's value; referencing kAXTrustedCheckOptionPrompt itself trips Swift 6 global-state checks.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                return true
            }
            img.isTemplate = true
            img.accessibilityDescription = "iTerm Sidebar"
            btn.image = img
        }

        let menu = NSMenu()
        toggleSidebarItem = menuItem("", #selector(toggleSidebar))
        tabsItem = menuItem("Tabs", #selector(toggleLayout))
        sortItem = menuItem("Sort by Attention", #selector(toggleSort))
        reserveSpaceItem = menuItem("Keep Windows Clear of Sidebar", #selector(toggleReserveSpace))
        menu.addItem(toggleSidebarItem)
        menu.addItem(tabsItem)
        menu.addItem(sortItem)
        menu.addItem(reserveSpaceItem)
        accessibilityItem = menuItem("Open Accessibility Settings…", #selector(openAccessibilitySettings))
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        updateMenu()
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateMenu() {
        toggleSidebarItem.title = Prefs.sidebarEnabled ? "Hide Sidebar" : "Show Sidebar"
        tabsItem.state = Prefs.layout == .tabs ? .on : .off
        sortItem.state = store.sortOrder == .attention ? .on : .off
        reserveBlocked = accessibilityMissing
        reserveSpaceItem.title = "Keep Windows Clear of Sidebar" + (reserveBlocked ? " (Needs Accessibility)" : "")
        reserveSpaceItem.state = reserveBlocked ? .mixed : Prefs.reserveSpace ? .on : .off
        accessibilityItem.isHidden = !reserveBlocked
    }

    @objc private func toggleSort() {
        store.setSort(store.sortOrder == .attention ? .project : .attention)
        updateMenu()
    }

    @objc private func toggleLayout() {
        Prefs.layout = Prefs.layout == .tabs ? .list : .tabs
        updateMenu()
        setupPanels()
        updatePanelVisibility()
        if Prefs.reserveSpace { reserver.sweep() }
    }

    @objc private func toggleSidebar() {
        Prefs.sidebarEnabled.toggle()
        updateMenu()
        updatePanelVisibility()
    }

    @objc private func toggleReserveSpace() {
        Prefs.reserveSpace.toggle()
        updateMenu()
        guard Prefs.reserveSpace else { return }
        promptForAccessibility()
        reserver.attachIfTrusted()
        reserver.sweep()
    }

    /// A stale grant never re-prompts. It has to be removed and added again in Settings.
    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
