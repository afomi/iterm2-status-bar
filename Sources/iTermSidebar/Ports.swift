import Foundation

struct LsofRecord: Equatable {
    let pid: Int
    let name: String
}

/// Parses `lsof -F pn` output: `p` lines set the pid, `n` lines carry the name.
func parseLsof(_ output: String) -> [LsofRecord] {
    var records: [LsofRecord] = []
    var currentPid: Int?
    for line in output.split(separator: "\n") {
        if line.hasPrefix("p") {
            currentPid = Int(line.dropFirst())
        } else if line.hasPrefix("n"), let pid = currentPid {
            records.append(LsofRecord(pid: pid, name: String(line.dropFirst())))
        }
    }
    return records
}

func runLsof(_ arguments: [String]) -> [LsofRecord] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return [] }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    task.waitUntilExit()
    return parseLsof(output)
}

/// [pid: ports] from listener records named like `*:4001`, `127.0.0.1:4001`, `[::1]:4001`.
func listeningPorts(_ listeners: [LsofRecord]) -> [Int: Set<Int>] {
    var pidPorts: [Int: Set<Int>] = [:]
    for r in listeners {
        if let port = r.name.split(separator: ":").last.flatMap({ Int($0) }) {
            pidPorts[r.pid, default: []].insert(port)
        }
    }
    return pidPorts
}

/// [normalizedPath: sorted ports] by joining each listener's pid to its cwd record.
func portsByDirectory(cwds: [LsofRecord], pidPorts: [Int: Set<Int>]) -> [String: [Int]] {
    var result: [String: Set<Int>] = [:]
    for r in cwds {
        result[normalize(r.name), default: []].formUnion(pidPorts[r.pid] ?? [])
    }
    return result.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }
}

/// `raw` when it is a `low-high` TCP port range, otherwise the default.
func validPortRange(_ raw: String?) -> String {
    let bounds = (raw ?? "").split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
    guard bounds.count == 2, let low = bounds[0], let high = bounds[1], 1 <= low, low <= high, high <= 65535 else {
        return defaultPortRange
    }
    return "\(low)-\(high)"
}

/// Returns [normalizedPath: [port]] for TCP listeners in the configured range, resolved via pid -> cwd.
func fetchPortMap() -> [String: [Int]] {
    let pidPorts = listeningPorts(runLsof(["-iTCP:\(Prefs.portRange)", "-sTCP:LISTEN", "-nP", "-Fpn"]))
    guard !pidPorts.isEmpty else { return [:] }
    let pids = pidPorts.keys.map(String.init).joined(separator: ",")
    return portsByDirectory(cwds: runLsof(["-a", "-d", "cwd", "-Fpn", "-p", pids]), pidPorts: pidPorts)
}
