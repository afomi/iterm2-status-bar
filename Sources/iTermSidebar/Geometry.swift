import CoreGraphics

/// Converts between Cocoa's bottom-left global coords and the top-left global coords
/// used by iTerm2 bounds and the Accessibility API. The conversion is its own inverse.
/// `primaryHeight` is the height of the primary (menu bar) display.
func flipped(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    return i.isNull ? 0 : i.width * i.height
}

/// Index of the screen (Cocoa frames) holding most of `window` (top-left coords);
/// nil when the window is on none of them, e.g. on a disconnected display.
func bestScreenIndex(for window: CGRect, screens: [CGRect], primaryHeight: CGFloat) -> Int? {
    let cocoaFrame = flipped(window, primaryHeight: primaryHeight)
    let areas = screens.map { intersectionArea($0, cocoaFrame) }
    guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
    return best
}

/// The width that pulls `window`'s right edge back to the left edge of the sidebar it overlaps
/// (all rects top-left coords), or nil to leave it alone: no overlap, the window starts behind the
/// sidebar or continues onto the next display, or the result would be narrower than `minimumWidth`.
func clampedWidth(for window: CGRect, sidebars: [CGRect], minimumWidth: CGFloat) -> CGFloat? {
    for sidebar in sidebars where window.intersects(sidebar) {
        guard window.minX < sidebar.minX, window.maxX <= sidebar.maxX + 1 else { continue }
        let width = sidebar.minX - window.minX
        return width >= minimumWidth ? width : nil
    }
    return nil
}

/// Pulls `window` out from under a reserved rect, or nil to leave it alone.
/// A tall rect is the right-hand list: the window's right edge stops at its left edge.
/// A wide rect is the top shelf: the window's top edge moves to just below it.
/// `requireOuterEdge` is for move events (a drag). Only a window that was just placed
/// against the list's outer edge — a zoom — is trimmed. The shelf never trims on a move:
/// a window dragged to the top looks like a zoom, and each drag would cost it height.
/// A resize uses the looser overlap rule.
func clampedFrame(
    for window: CGRect,
    reserved: [CGRect],
    minimumWidth: CGFloat,
    minimumHeight: CGFloat = 180,
    requireOuterEdge: Bool = false
) -> CGRect? {
    var frame = window
    var changed = false
    for obstacle in reserved where frame.intersects(obstacle) {
        if obstacle.height >= obstacle.width {
            if requireOuterEdge, abs(frame.maxX - obstacle.maxX) > 8 { continue }
            guard let width = clampedWidth(for: frame, sidebars: [obstacle], minimumWidth: minimumWidth),
                  abs(width - frame.width) > 0.5 else { continue }
            frame.size.width = width
            changed = true
        } else {
            if requireOuterEdge { continue }
            let above = obstacle.minY - frame.minY
            guard above <= 80, frame.minY < obstacle.maxY, frame.maxY > obstacle.maxY else { continue }
            let height = frame.maxY - obstacle.maxY
            guard height >= minimumHeight else { continue }
            guard abs(frame.minY - obstacle.maxY) > 0.5 || abs(frame.height - height) > 0.5 else { continue }
            frame.origin.y = obstacle.maxY
            frame.size.height = height
            changed = true
        }
    }
    return changed ? frame : nil
}

/// Width of one tab on the shelf. A few sessions stay at `maxWidth` and leave the rest of the
/// shelf empty, the way a browser does. Enough sessions shrink together, then stop at `minWidth`
/// and the strip scrolls.
func tabWidth(
    available: CGFloat,
    count: Int,
    minWidth: CGFloat = tabMinWidth,
    maxWidth: CGFloat = tabMaxWidth
) -> CGFloat {
    guard count > 0, available > 0 else { return maxWidth }
    return min(maxWidth, max(minWidth, available / CGFloat(count)))
}
