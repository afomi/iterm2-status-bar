import Cocoa

/// One folder per line; `#` comments and blanks skipped, `~` expanded,
/// duplicates (after normalizing) dropped while keeping file order.
func parsePinnedPaths(_ contents: String) -> [String] {
    var seen = Set<String>()
    return contents.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .map { ($0 as NSString).expandingTildeInPath }
        .filter { seen.insert(normalize($0)).inserted }
}

func loadPinnedPaths() -> [String] {
    guard let contents = try? String(contentsOf: pinnedPathsURL, encoding: .utf8) else { return [] }
    return parsePinnedPaths(contents)
}

@MainActor
func editPinnedProjects() {
    guard let textEditURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
        NSWorkspace.shared.open(pinnedPathsURL)
        return
    }
    NSWorkspace.shared.open(
        [pinnedPathsURL],
        withApplicationAt: textEditURL,
        configuration: NSWorkspace.OpenConfiguration()
    )
}
