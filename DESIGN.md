# iterm2-status-bar design notes

## Port scanning

**Range:** 4000–4999 by default, because most projects here are web apps that bind near 4000. The `portRange` default overrides it (`defaults write studio.civic.iterm-sidebar portRange 3000-4999`); an invalid value falls back to the default.

**Mechanism:** `lsof -iTCP:<range> -sTCP:LISTEN -nP -Fp` to find listening pids and their ports, then a second `lsof -a -d cwd -Fpn` call to resolve each pid to its working directory. Ports are matched to sidebar rows by comparing the process cwd against the iTerm2 session path (both normalized via `URL.standardized.path`).

**Display:** Ports appear as sub-bullets under the process row — `· :4001` — in secondary monospaced text. Multiple ports per folder are each on their own line.

**Refresh:** Port scan runs on every store refresh cycle (same background queue as the iTerm2 AppleScript fetch), so latency is bounded by the existing 1s / 10s polling interval.

## Session title parsing

iTerm2 session names arrive as `"proc — ~/path"`. The path suffix is stripped to get the process name. The path from `session.path` (or parsed from the title as fallback) is used for port matching and sort grouping.

## Display format

`dir` for a recognized agent, `dir — process` otherwise (e.g. `commons_ex — vim`). The default order is directory, then process. Menu bar → **Sort by Attention** orders working, needs review, the focused window, then dormant, with the same directory order inside each group. The choice is stored in `sort`. The agent name is not repeated in the row. Versioned binaries count: `claude.exe`, `grok-1`, `grok-1.2`.

The list panel is drawn at 82% opacity and the tab shelf at 90%.

A second dot sits on the right edge of the row. Claude is orange, Grok is black with a light ring, Codex is purple. Every other row uses the same-sized hollow circle so the directory text lines up.

When iTerm reports a foreground `jobName`, that is what the dot is chosen from. `commandLine` is only consulted when the job is a runtime (`node`, `npx`, `python`, …), and only an executable basename or a package name counts — a path like `~/claude/server.js` does not.

The sidebar reads the current session of the current tab of each window. Other panes in that window are not listed.

## Session dot

iTerm's `is processing` means the session received output recently, which is the signal used for "working."

| Mark | Drawn | When |
|---|---|---|
| Working | Yellow ring | Output recently. Wins over focus; the row highlight still shows the selected window. |
| Active | Green dot | This window is focused, and it is idle. |
| Needs review | Blue dot | Idle and not focused, and either the job stopped while you were in another window (stays until you focus it) or you left this window in the last 3 minutes. |
| Dormant | Gray dot | Idle, not focused, nothing new. |

The sidebar only notices transitions after it is running. A job that finished before launch starts out dormant.

## Tabs

Menu bar → **Tabs** replaces the right-hand list with a shelf across the top of each screen's usable area, under the menu bar. One tab per iTerm window on that screen. The tab's foot uses the same colors as the activity dot (yellow working, green focused and idle, blue needs a look, gray dormant). The focused tab is the lighter one. A handful of tabs stay at 220pt and leave the rest of the shelf empty. Past that they shrink together down to 112pt, then the shelf scrolls. Unopened pins sit at the trailing end. The choice is stored in `layout` and the panels are rebuilt when it changes. Keeping windows clear pulls other windows down to just below the shelf.

## Keeping windows clear of the sidebar

macOS has no public API to shrink a screen's `visibleFrame`, so zoom / Fill / tiling place windows under the sidebar and under the tab shelf. `SidebarSpaceReserver` registers an `AXObserver` per regular app for `AXWindowCreated`, `AXWindowResized`, and `AXWindowMoved`. A resize that overlaps a tall bar is narrowed to the bar's left edge. A resize that overlaps the wide shelf is moved down so its top sits at the shelf's bottom. A move is trimmed only when the window is pinned to that outer edge (a zoom); a drag that merely crosses the chrome is left alone. Full-screen windows, windows narrower than 300pt after the trim, windows that start inside the chrome, and windows that continue onto the next display are skipped. Notifications wait 0.6s after the last event, then one confirm pass 0.5s later catches a zoom animation that writes the full frame back. `kAXWindowsAttribute` is read as an `NSArray` when it will not bridge to `[AXUIElement]`. Attach is retried every second until Accessibility is trusted. While it is not, the menu item reads *(Needs Accessibility)* with a mixed state, and *Open Accessibility Settings…* appears under it. The item itself still turns the feature off. Dev builds sign with an Apple Development identity because an ad-hoc signature pins the TCC grant to the cdhash: a rebuild then loses Accessibility while System Settings still shows it on, and that stale entry never re-prompts, so it has to be removed and added again. Every window is swept again when a panel appears, when the grant first lands, or when a sidebar is widened. Toggle: menu bar → *Keep Windows Clear of Sidebar* (persisted in `UserDefaults`).
