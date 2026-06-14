import Cocoa

// MARK: - Demo mode
//
// Replaces real session paths/titles with plausible civic/cybernetic fakes for screenshots.
//
// To enable:
//   1. Uncomment the `import` line in WindowStore.refresh() (search "applyDemoMode")
//   2. Change demoMode to true below
//   3. Rebuild

let demoMode = false

private let demoDirs = [
    "beacon-network", "civic-pulse", "common-ground", "consensus-engine", "cooperative-mesh",
    "digital-commons", "federated-voice", "open-ledger", "participatory-grid", "peer-signal",
    "public-fabric", "resilient-node", "shared-horizon", "signal-collective", "solar-registry",
    "solidarity-hub", "symbiotic-core", "synapse-commons", "trust-layer", "ubuntu-protocol",
    "unified-forum", "verdant-loop", "vital-exchange", "wellbeing-index", "woven-city"
]

private let demoProcs = ["zsh", "nvim", "git", "make", "rails", "node", "python3", "cargo", "go"]

private var demoAssignments: [Int: (dir: String, proc: String)] = [:]

private func demoLabel(for id: Int) -> (dir: String, proc: String) {
    if let existing = demoAssignments[id] { return existing }
    let dir = demoDirs[id % demoDirs.count]
    let proc = demoProcs[id % demoProcs.count]
    demoAssignments[id] = (dir, proc)
    return (dir, proc)
}

func applyDemoMode(_ w: ITerm2Window) -> ITerm2Window {
    guard demoMode else { return w }
    let label = demoLabel(for: w.id)
    let fakeTitle = "\(label.dir) — \(label.proc)"
    let fakePath = ("~/workspace/\(label.dir)" as NSString).expandingTildeInPath
    return ITerm2Window(
        id: w.id,
        title: fakeTitle,
        sortKey: (label.dir, label.proc),
        path: fakePath,
        origin: w.origin,
        isProcessing: w.isProcessing
    )
}
