import Cocoa

/// macOS has no public API to reserve screen edge space (no equivalent of a Windows AppBar),
/// so zoom / "Fill" / tiling size windows to the screen's visibleFrame, underneath the sidebar
/// or the tab shelf. Watch every app's windows via the Accessibility API and pull a window
/// back out. A resize that overlaps is trimmed. A move is trimmed only when the window is
/// pinned to the list's outer edge (a zoom), so a drag does not squash it. The shelf ignores moves.
@MainActor
final class SidebarSpaceReserver: NSObject {
    /// Sidebar rects to keep clear, in top-left (AX) coords.
    private let reservedRects: @MainActor () -> [CGRect]
    private var observers: [pid_t: AXObserver] = [:]
    private var attached = false
    private var loggedUntrusted = false
    private var pending: [Pending] = []
    private var flush: Task<Void, Never>?
    private let minimumWidth: CGFloat = 300

    private struct Pending {
        var element: AXUIElement
        var movedOnly: Bool
    }

    var isAttached: Bool { attached }

    init(reservedRects: @escaping @MainActor () -> [CGRect]) {
        self.reservedRects = reservedRects
    }

    /// Starts observing once Accessibility access has been granted; cheap to call repeatedly.
    func attachIfTrusted() {
        guard !attached else { return }
        guard AXIsProcessTrusted() else {
            if !loggedUntrusted {
                loggedUntrusted = true
                log("SidebarSpaceReserver: Accessibility is not trusted, so windows will not be kept clear")
            }
            return
        }
        attached = true
        log("SidebarSpaceReserver: attaching")
        // A hung app must not stall the main thread for the default 6s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        NSWorkspace.shared.runningApplications.forEach(observe)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        sweep()
    }

    /// Re-check every window, e.g. after a sidebar appears or widens.
    func sweep() {
        guard attached else { return }
        var count = 0
        for pid in observers.keys {
            let windows = childWindows(of: AXUIElementCreateApplication(pid))
            count += windows.count
            windows.forEach { enqueue($0, movedOnly: false) }
        }
        log("SidebarSpaceReserver: sweep windows=\(count)")
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Freshly launched apps aren't ready for AX registration yet, and slow ones take a while.
        Task {
            for seconds: UInt64 in [1, 2, 4, 8] {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard !app.isTerminated else { return }
                observe(app)
                guard observers[app.processIdentifier] != nil else { continue }
                childWindows(of: AXUIElementCreateApplication(app.processIdentifier)).forEach { enqueue($0, movedOnly: false) }
                return
            }
            log("SidebarSpaceReserver: gave up observing \(app.localizedName ?? "pid \(app.processIdentifier)")")
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let observer = observers.removeValue(forKey: app.processIdentifier) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var created: AXObserver?
        // Delivered on the main run loop, where the source is added below.
        // The third argument is the notification name (created, resized, or moved).
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let reserver = Unmanaged<SidebarSpaceReserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { reserver.enqueueFromObserver(element, notification: notification) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let results = [kAXWindowCreatedNotification, kAXWindowResizedNotification, kAXWindowMovedNotification].map {
            AXObserverAddNotification(observer, appElement, $0 as CFString, refcon)
        }
        // Unrecorded, so `appLaunched` can try again.
        guard results.allSatisfy({ $0 == .success }) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func enqueueFromObserver(_ window: AXUIElement, notification: CFString) {
        let movedOnly = CFStringCompare(notification, kAXWindowMovedNotification as CFString, []) == .compareEqualTo
        enqueue(window, movedOnly: movedOnly)
    }

    /// Debounced so live resizes and zoom animations settle before we clamp.
    /// A later resize upgrades a pending move, so a zoom is not treated as a drag.
    private func enqueue(_ window: AXUIElement, movedOnly: Bool) {
        if let index = pending.firstIndex(where: { CFEqual($0.element, window) }) {
            if !movedOnly { pending[index].movedOnly = false }
        } else {
            pending.append(Pending(element: window, movedOnly: movedOnly))
        }
        flush?.cancel()
        flush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            let batch = self.pending
            self.pending.removeAll()
            for item in batch {
                self.clamp(item.element, requireOuterEdge: item.movedOnly, confirm: true)
            }
        }
    }

    /// `confirm` schedules one later pass. Zoom writes the full frame after the first
    /// resize notification, and that second write has to be pulled back too.
    private func clamp(_ window: AXUIElement, requireOuterEdge: Bool, confirm: Bool) {
        guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              attribute(window, "AXFullScreen") as? Bool != true,
              let frame = frame(of: window),
              let next = clampedFrame(
                for: frame,
                reserved: reservedRects(),
                minimumWidth: minimumWidth,
                requireOuterEdge: requireOuterEdge
              ) else { return }
        apply(next, to: window, from: frame)
        guard confirm else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.clamp(window, requireOuterEdge: requireOuterEdge, confirm: false)
        }
    }

    private func apply(_ next: CGRect, to window: AXUIElement, from frame: CGRect) {
        log("SidebarSpaceReserver: clamp \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY)) -> \(Int(next.width))x\(Int(next.height)) at \(Int(next.minX)),\(Int(next.minY))")
        if abs(next.origin.x - frame.origin.x) > 0.5 || abs(next.origin.y - frame.origin.y) > 0.5 {
            var origin = next.origin
            if let value = AXValueCreate(.cgPoint, &origin) {
                let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
                if err != .success {
                    log("SidebarSpaceReserver: set position failed \(err.rawValue)")
                }
            }
        }
        if abs(next.size.width - frame.size.width) > 0.5 || abs(next.size.height - frame.size.height) > 0.5 {
            var size = next.size
            if let value = AXValueCreate(.cgSize, &size) {
                let err = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
                if err != .success {
                    log("SidebarSpaceReserver: set size failed \(err.rawValue)")
                }
            }
        }
    }

    /// `kAXWindowsAttribute` sometimes comes back as a CFArray that will not bridge to `[AXUIElement]`.
    private func childWindows(of app: AXUIElement) -> [AXUIElement] {
        guard let raw = attribute(app, kAXWindowsAttribute) else { return [] }
        if let array = raw as? NSArray {
            return (0..<array.count).compactMap { index in
                let object = array[index] as AnyObject
                guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
                return (object as! AXUIElement)
            }
        }
        return raw as? [AXUIElement] ?? []
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let positionRef = attribute(window, kAXPositionAttribute),
              let sizeRef = attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
