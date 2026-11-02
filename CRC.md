# CRC — iterm2-status-bar

Class-Responsibility-Collaborator cards for the main objects.

```mermaid
classDiagram

    class ITerm2Window {
        +Int id
        +String title
        +String dir
        +String process
        +String path
        +CGRect frame
        +Bool isProcessing
        +String? llm
    }

    class WindowStore {
        +[ITerm2Window] windows
        +Int? activeId
        +[String] pinnedPaths
        +[String:[Int]] portMap
        +[Int:SessionMark] marks
        +SidebarSort sortOrder
        +setSort(SidebarSort)
        +refresh()
        +unopenedPinnedPaths
        +windows(onScreen:)
        +activate(ITerm2Window)
    }

    class AppDelegate {
        +[SidebarPanel] panels
        +NSStatusItem statusItem
        +WindowStore store
        +SidebarSpaceReserver reserver
        +Timer timer
        +setupPanels()
        +setupStatusItem()
        +updatePanelVisibility()
    }

    class SidebarPanel {
        +NSPanel panel
        +NSScreen screen
        +NSRect frame
        +setVisible(Bool)
    }

    class SidebarSpaceReserver {
        +Bool isAttached
        +attachIfTrusted()
        +sweep()
        -clamp(AXUIElement, requireOuterEdge, confirm)
    }

    class SidebarView {
        +WindowStore store
        +NSScreen screen
        +visibleWindows [ITerm2Window]
        +pinnedUnopened [String]
        +body View
    }

    class SidebarRow {
        +Bool isActive
        +Double restingOpacity
        +action()
    }

    class WindowRow {
        +ITerm2Window window
        +Bool isActive
        +Bool isPinned
        +[Int] ports
        +onTap()
    }

    class PinnedRow {
        +String path
        +openITermWindow(path:)
    }

    class DragHandleView {
        +onDrag (CGFloat) -> Void
    }

    AppDelegate --> WindowStore : owns
    AppDelegate --> SidebarPanel : one per screen
    AppDelegate --> SidebarSpaceReserver : owns, feeds visible panel rects
    SidebarPanel --> SidebarView : hosts
    SidebarPanel --> DragHandleView : attaches to left edge
    SidebarView --> WindowStore : observes (@ObservedObject)
    SidebarView --> WindowRow : renders per open window
    SidebarView --> PinnedRow : renders per unopened pinned path
    WindowStore --> ITerm2Window : publishes list of
    WindowRow --> ITerm2Window : displays
    WindowRow --> SidebarRow : wraps
    PinnedRow --> SidebarRow : wraps
```

## Data flow

```mermaid
sequenceDiagram
    participant Timer
    participant WindowStore
    participant fetchITermState
    participant fetchPortMap
    participant SidebarView

    Timer->>WindowStore: refresh() (1s if iTerm2 active, else 10s)
    WindowStore->>fetchITermState: AppleScript → window id, title, path, origin, processing, jobName, commandLine
    WindowStore->>fetchPortMap: lsof portRange → pid→port, pid→cwd
    fetchITermState-->>WindowStore: [ITerm2Window], activeId
    fetchPortMap-->>WindowStore: [path: [port]]
    WindowStore->>WindowStore: diff — only assign if changed
    WindowStore-->>SidebarView: @Published triggers redraw
```

## Key design decisions

| Decision | Reason |
|---|---|
| Window selection by `id of w` (AppleScript) | Positional index shifts as windows open/close — stable id avoids off-by-one |
| Port range defaults to 4000–4999 | Most projects bind near 4000; `portRange` overrides it |
| Two lsof calls (ports→pid, pid→cwd) | Single call can't give both port and cwd; -d cwd filters to just the working dir fd |
| Equality-guard before `@Published` assign | Prevents SwiftUI from repainting on every poll tick when data hasn't changed |
| `~/Library/Application Support/iTermSidebar/instance.lock` (fixed path) | `FileManager.temporaryDirectory` is session-scoped — different launches got different paths, defeating the singleton lock |
| AppleScript returns nested lists | Field boundaries survive any characters in titles/paths (replaced `\|\|\|`-joined strings) |
| Skip AppleScript when iTerm2 isn't running | `tell application` would relaunch iTerm2 after the user quits it |
| Sidebar visibility = `Prefs.sidebarEnabled && screen has windows` | One method shows/hides panels, so Hide survives refreshes |
| Trim windows via Accessibility, not reserve space | macOS has no public API to shrink `visibleFrame` |
