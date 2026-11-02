import Foundation
import OSLog

let iTermBundleID = "com.googlecode.iterm2"
let sidebarBaseWidth: CGFloat = 220
let sidebarMaxExtraWidth: CGFloat = 100
let defaultPortRange = "4000-4999"
let tabStripHeight: CGFloat = 42
let tabMinWidth: CGFloat = 112
let tabMaxWidth: CGFloat = 220
let listPanelOpacity = 0.82
let tabPanelOpacity = 0.9

enum SidebarLayout: String {
    case list, tabs
}

enum SidebarSort: String {
    case project, attention
}
let pinnedPathsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/iterm-sidebar/pinned.txt")

/// Persisted user choices, toggled from the menu bar.
enum Prefs {
    static var sidebarEnabled: Bool {
        get { bool("sidebarEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarEnabled") }
    }
    static var reserveSpace: Bool {
        get { bool("reserveSpace") }
        set { UserDefaults.standard.set(newValue, forKey: "reserveSpace") }
    }
    static var layout: SidebarLayout {
        get { SidebarLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .list }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "layout") }
    }
    static var sort: SidebarSort {
        get { SidebarSort(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .project }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sort") }
    }
    /// No menu item: `defaults write studio.civic.iterm-sidebar portRange 3000-4999`, then relaunch.
    static var portRange: String { validPortRange(UserDefaults.standard.string(forKey: "portRange")) }
    private static func bool(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

private let logger = Logger(subsystem: "studio.civic.iterm-sidebar", category: "app")

/// Unified logging: `log stream --predicate 'subsystem == "studio.civic.iterm-sidebar"'`
func log(_ msg: String) {
    logger.notice("\(msg, privacy: .public)")
}
