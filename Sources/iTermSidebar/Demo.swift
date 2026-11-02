import Foundation

// MARK: - Demo mode
//
// Replaces real session paths/titles with plausible civic/cybernetic fakes for screenshots.
//
// To enable: set demoMode to true below and rebuild.
// WindowStore always routes windows through applyDemoMode.

let demoMode = false

private let demoDirs = [
    "beacon-network", "civic-pulse", "common-ground", "consensus-engine", "cooperative-mesh",
    "digital-commons", "federated-voice", "open-ledger", "participatory-grid", "peer-signal",
    "public-fabric", "resilient-node", "shared-horizon", "signal-collective", "solar-registry",
    "solidarity-hub", "symbiotic-core", "synapse-commons", "trust-layer", "ubuntu-protocol",
    "unified-forum", "verdant-loop", "vital-exchange", "wellbeing-index", "woven-city"
]

// Keyed by real dir name so the same project always gets the same fake name
@MainActor private var demoDirMap: [String: String] = [:]

@MainActor
private func fakeDir(for realDir: String) -> String {
    if let existing = demoDirMap[realDir] { return existing }
    let fake = demoDirs[demoDirMap.count % demoDirs.count]
    demoDirMap[realDir] = fake
    return fake
}

@MainActor
func demoDisplayName(forPath path: String) -> String {
    let realDir = (path as NSString).lastPathComponent
    return demoMode ? fakeDir(for: realDir) : realDir
}

@MainActor
func applyDemoMode(_ w: ITerm2Window) -> ITerm2Window {
    guard demoMode else { return w }
    let fake = fakeDir(for: w.dir)
    // Replace only the dir portion of the title; keep real process name
    return ITerm2Window(
        id: w.id,
        title: w.title.replacingOccurrences(of: w.dir, with: fake),
        dir: fake,
        process: w.process,
        path: w.path,  // keep real path so port matching works
        frame: w.frame,
        isProcessing: w.isProcessing,
        llm: w.llm
    )
}
