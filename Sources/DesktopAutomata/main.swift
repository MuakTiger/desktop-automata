import AppKit

// Debug: render offscreen to a PNG and exit (see SnapshotCommand).
if let path = ProcessInfo.processInfo.environment["DA_SNAPSHOT"] {
    exit(SnapshotCommand.run(path: path, environment: ProcessInfo.processInfo.environment))
}

let app = NSApplication.shared
// NSApplication.delegate is weak; this top-level constant keeps it alive.
let appDelegate = AppDelegate()
app.delegate = appDelegate
// Menu-bar only: no Dock icon, no app menu (Info.plist also sets LSUIElement).
app.setActivationPolicy(.accessory)
app.run()
