import Cocoa
import Darwin

// Single-instance guard: a second launch exits while the first holds the lock.
let instanceLockURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/iTermSidebar/instance.lock")
try? FileManager.default.createDirectory(at: instanceLockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let instanceLockFD = Darwin.open(instanceLockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
if instanceLockFD < 0 || Darwin.lockf(instanceLockFD, F_TLOCK, 0) != 0 {
    log("iTermSidebar already running; exiting duplicate process")
    exit(0)
}

log("app starting, screens=\(NSScreen.screens.count)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon; LSUIElement does the same when run as a bundle
let delegate = AppDelegate()
app.delegate = delegate
app.run()
