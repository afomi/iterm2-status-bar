import SwiftUI

extension Color {
    static func panelBackground(_ opacity: Double) -> Color {
        Color(nsColor: .windowBackgroundColor).opacity(opacity)
    }
}

/// Shared chrome for every clickable sidebar row: padding, rounded hover/active background.
struct SidebarRow<Content: View>: View {
    var isActive = false
    var restingOpacity = 0.75
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? Color.accentColor.opacity(0.5)
                              : .panelBackground(hovered ? 0.95 : restingOpacity))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
    }
}

struct RowTitle: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

/// Yellow ring = working. Green = focused and idle. Blue = needs a look. Gray = dormant.
/// The ring keeps "working" distinguishable without color alone; the other three
/// share a dot and are also named in the accessibility label.
struct StatusDot: View {
    let mark: SessionMark

    var body: some View {
        Group {
            switch mark {
            case .working:
                Circle().strokeBorder(Color.yellow, lineWidth: 2)
            case .active:
                Circle().fill(Color.green)
            case .review:
                Circle().fill(Color.blue)
            case .dormant:
                Circle().fill(Color.gray.opacity(0.55))
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityLabel(mark.label)
        .help(mark.label)
    }
}

/// Who is in the terminal, pinned to the right edge of the row.
/// Claude is orange, Grok is black with a light ring so it shows on a dark panel, Codex is purple.
/// Anything else is the same-sized hollow circle, so the directory text stays aligned.
struct AgentMark: View {
    let llm: String?

    var body: some View {
        mark
            .frame(width: 7, height: 7)
            .accessibilityLabel(llm ?? "No agent")
            .help(llm ?? "No agent")
    }

    @ViewBuilder private var mark: some View {
        switch llm {
        case "Claude":
            Circle().fill(.orange)
        case "Grok":
            Circle()
                .fill(.black)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
        case "Codex":
            Circle().fill(.purple)
        default:
            Circle().strokeBorder(Color.secondary.opacity(0.65), lineWidth: 1)
        }
    }
}

struct WindowRow: View {
    let window: ITerm2Window
    let isActive: Bool
    let mark: SessionMark
    let isPinned: Bool
    let ports: [Int]
    let onTap: () -> Void

    var body: some View {
        SidebarRow(isActive: isActive, restingOpacity: isPinned ? 0.4 : 0.75, action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    StatusDot(mark: mark)
                    RowTitle(text: window.title)
                    AgentMark(llm: window.llm)
                }
                ForEach(ports, id: \.self) { port in
                    Button(action: {
                        if let url = URL(string: "http://localhost:\(port)") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 13, alignment: .trailing)
                            Text(":\(port)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .help(window.path)
    }
}

struct PinnedRow: View {
    let path: String
    let screen: NSScreen

    var body: some View {
        SidebarRow(action: { openITermWindow(path: path, on: screen) }) {
            HStack(spacing: 6) {
                Text("+")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 7)
                RowTitle(text: demoDisplayName(forPath: path), color: .secondary)
            }
        }
        .help(path)
    }
}

struct SidebarView: View {
    @ObservedObject var store: WindowStore
    let screen: NSScreen

    var visibleWindows: [ITerm2Window] {
        sortedForSidebar(store.windows(onScreen: screen), marks: store.marks, order: store.sortOrder)
    }

    var body: some View {
        let windows = visibleWindows
        let pinnedUnopened = store.unopenedPinnedPaths
        let pinnedSet = Set(store.pinnedPaths.map(normalize))

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(text: screen.localizedName)
                .padding(.top, 16)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(windows) { win in
                        WindowRow(
                            window: win,
                            isActive: store.activeId == win.id,
                            mark: store.marks[win.id] ?? .dormant,
                            isPinned: pinnedSet.contains(normalize(win.path)),
                            ports: store.portMap[normalize(win.path)] ?? [],
                            onTap: { store.activate(win) }
                        )
                    }

                    if !pinnedUnopened.isEmpty {
                        SectionHeader(text: "Pinned")
                            .padding(.top, windows.isEmpty ? 8 : 12)
                            .padding(.bottom, 2)

                        ForEach(pinnedUnopened, id: \.self) { path in
                            PinnedRow(path: path, screen: screen)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            Button(action: editPinnedProjects) {
                Label("Edit Pinned Projects", systemImage: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.panelBackground(listPanelOpacity))
    }
}

struct SidebarRoot: View {
    let layout: SidebarLayout
    @ObservedObject var store: WindowStore
    let screen: NSScreen

    var body: some View {
        switch layout {
        case .list: SidebarView(store: store, screen: screen)
        case .tabs: TabStripView(store: store, screen: screen)
        }
    }
}

/// Rounded along the top, flat along the bottom, so a row of them sits on the shelf line.
struct TabShelfShape: Shape {
    var radius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.height / 2, rect.width / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private func footColor(_ mark: SessionMark) -> Color {
    switch mark {
    case .working: .yellow
    case .active: .green
    case .review: .blue
    case .dormant: .gray.opacity(0.45)
    }
}

struct SessionTab: View {
    let window: ITerm2Window
    let isActive: Bool
    let mark: SessionMark
    let ports: [Int]
    let drawSeparator: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    StatusDot(mark: mark)
                    Text(window.title)
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .foregroundColor(mark == .dormant && !isActive ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AgentMark(llm: window.llm)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(window.path)

            if let port = ports.first {
                Button(action: { openPort(port) }) {
                    Text(ports.count == 1 ? ":\(port)" : ":\(port)+")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.trailing, 8)
                }
                .buttonStyle(.plain)
                .help(ports.map { ":\($0)" }.joined(separator: " "))
            }
        }
        .background(TabShelfShape().fill(Color.panelBackground(fillOpacity)))
        .overlay(alignment: .bottom) {
            Rectangle().fill(footColor(mark)).frame(height: 2)
        }
        .overlay(alignment: .trailing) {
            if drawSeparator {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1)
                    .padding(.vertical, 8)
                    .padding(.bottom, 2)
            }
        }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.18), value: isActive)
        .animation(.easeOut(duration: 0.18), value: mark)
    }

    private var fillOpacity: Double {
        if isActive { return 0.94 }
        if hovered { return 0.72 }
        if mark == .dormant { return 0.22 }
        return 0.4
    }

    private func openPort(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Horizontal shelf under the menu bar. One tab per iTerm window on this screen.
struct TabStripView: View {
    @ObservedObject var store: WindowStore
    let screen: NSScreen

    private var visibleWindows: [ITerm2Window] {
        sortedForSidebar(store.windows(onScreen: screen), marks: store.marks, order: store.sortOrder)
    }

    var body: some View {
        let windows = visibleWindows
        let pinnedUnopened = store.unopenedPinnedPaths

        HStack(spacing: 0) {
            Text(screen.localizedName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
                .padding(.leading, 12)

            GeometryReader { geo in
                let width = tabWidth(available: geo.size.width, count: windows.count)
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, win in
                            let nextIsActive = index + 1 < windows.count && store.activeId == windows[index + 1].id
                            SessionTab(
                                window: win,
                                isActive: store.activeId == win.id,
                                mark: store.marks[win.id] ?? .dormant,
                                ports: store.portMap[normalize(win.path)] ?? [],
                                drawSeparator: store.activeId != win.id && !nextIsActive && index < windows.count - 1,
                                onTap: { store.activate(win) }
                            )
                            .frame(width: width)
                        }
                    }
                    .frame(minHeight: geo.size.height)
                }
                .scrollIndicators(.hidden)
            }

            ForEach(pinnedUnopened, id: \.self) { path in
                Button(action: { openITermWindow(path: path, on: screen) }) {
                    Text("+ \(demoDisplayName(forPath: path))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .help(path)
            }

            Button(action: editPinnedProjects) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Edit Pinned Projects")
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.panelBackground(tabPanelOpacity))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.2)).frame(height: 1)
        }
    }
}
