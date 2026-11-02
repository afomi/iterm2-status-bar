import Cocoa
import SwiftUI

/// One panel per screen. List mode is a full-height bar on the right.
/// Tabs mode is a short shelf across the top of the usable screen, under the menu bar.
@MainActor
final class SidebarPanel {
    let panel: NSPanel
    let screen: NSScreen
    private var extraWidth: CGFloat = 0

    var frame: NSRect {
        if Prefs.layout == .tabs {
            let visible = screen.visibleFrame
            return NSRect(x: visible.minX, y: visible.maxY - tabStripHeight, width: visible.width, height: tabStripHeight)
        }
        let w = sidebarBaseWidth + extraWidth
        return NSRect(x: screen.frame.maxX - w, y: screen.frame.minY, width: w, height: screen.frame.height)
    }

    init(screen: NSScreen, store: WindowStore, onResize: @escaping @MainActor () -> Void) {
        self.screen = screen
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hostingView = NSHostingView(rootView: SidebarRoot(layout: Prefs.layout, store: store, screen: screen))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        if Prefs.layout == .list {
            // 6px drag handle on the left edge, full height. The shelf is a fixed height.
            let handle = DragHandleView(frame: NSRect(x: 0, y: 0, width: 6, height: screen.frame.height))
            handle.autoresizingMask = [.height]
            handle.onDrag = { [weak self] delta in
                guard let self else { return }
                // drag left = negative delta = wider
                self.extraWidth = max(0, min(sidebarMaxExtraWidth, self.extraWidth - delta))
                self.panel.setFrame(self.frame, display: true)
            }
            handle.onDragEnd = onResize
            hostingView.addSubview(handle)
        }

        panel.setFrame(frame, display: false)
        log("Panel on '\(screen.localizedName)' at \(frame)")
    }

    func setVisible(_ visible: Bool) {
        visible ? panel.orderFrontRegardless() : panel.orderOut(nil)
    }
}

final class DragHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var startX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        // Screen coords: the panel's left edge, and so this view, moves during the drag.
        let currentX = NSEvent.mouseLocation.x
        onDrag?(currentX - startX)
        startX = currentX
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}
