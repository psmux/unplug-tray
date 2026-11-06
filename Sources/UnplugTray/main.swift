import AppKit
import UnplugCore

// `UnplugTray --list` prints what the menu would show and exits.
if CommandLine.arguments.contains("--list") {
    let drives = DriveScanner.scan()
    if drives.isEmpty { print("No removable drives") }
    for d in drives {
        let size = ByteCountFormatter.string(fromByteCount: d.size, countStyle: .file)
        print("\(d.id)  \(d.model.isEmpty ? "(no model)" : d.model)  \(d.bus)  \(size)")
        for v in d.volumes {
            let free = ByteCountFormatter.string(fromByteCount: v.free, countStyle: .file)
            print("    \(v.name)  \(v.mountPoint.path)  \(free) free")
        }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
