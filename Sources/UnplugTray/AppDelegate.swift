import AppKit
import ServiceManagement
import UnplugCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var drives: [Drive] = []
    private var ejecting: Set<String> = []
    private var scanGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon("eject")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            ws.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        rescan()
    }

    // MARK: Scanning

    @objc private func volumesChanged(_ note: Notification) { rescan() }

    private func rescan() {
        scanGeneration += 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let found = DriveScanner.scan()
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                self.drives = found
                self.statusItem.button?.appearsDisabled = found.isEmpty
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        drives = DriveScanner.refreshSpace(drives)
        menu.removeAllItems()

        if drives.isEmpty {
            menu.addItem(disabled("No removable drives"))
        }
        for (i, drive) in drives.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            menu.addItem(disabled(header(for: drive)))
            for v in drive.volumes {
                let item = disabled("\(v.name)    \(size(v.free)) free of \(size(v.total))")
                item.indentationLevel = 1
                menu.addItem(item)
            }
            let busy = ejecting.contains(drive.id)
            let eject = action(busy ? "Ejecting \(drive.displayName)…" : "Eject \(drive.displayName)",
                               #selector(ejectClicked(_:)), drive.id)
            eject.image = symbol("eject")
            eject.isEnabled = !busy
            eject.indentationLevel = 1
            menu.addItem(eject)

            let force = action("Force Eject \(drive.displayName)…", #selector(forceClicked(_:)), drive.id)
            force.image = symbol("exclamationmark.triangle")
            force.isAlternate = true
            force.keyEquivalentModifierMask = .option
            force.isEnabled = !busy
            force.indentationLevel = 1
            menu.addItem(force)
        }

        menu.addItem(.separator())
        if drives.count > 1 {
            menu.addItem(action("Eject All", #selector(ejectAllClicked), nil))
        }
        let login = action("Open at Login", #selector(toggleLogin), nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = action("Quit Unplug Tray", #selector(NSApplication.terminate(_:)), nil)
        quit.target = NSApp
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func header(for d: Drive) -> String {
        var parts: [String] = []
        if !d.model.isEmpty { parts.append(d.model) }
        if !d.bus.isEmpty { parts.append(d.bus) }
        if d.size > 0 { parts.append(size(d.size)) }
        return parts.isEmpty ? d.id : parts.joined(separator: "  ·  ")
    }

    // MARK: Actions

    @objc private func ejectClicked(_ sender: NSMenuItem) {
        guard let d = drive(sender) else { return }
        start(d, force: false)
    }

    @objc private func forceClicked(_ sender: NSMenuItem) {
        guard let d = drive(sender) else { return }
        if confirmForce(d, holders: []) { start(d, force: true) }
    }

    @objc private func ejectAllClicked() {
        for d in drives where !ejecting.contains(d.id) { start(d, force: false) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Could not change Open at Login", error.localizedDescription)
        }
    }

    private func start(_ d: Drive, force: Bool) {
        ejecting.insert(d.id)
        setIcon("arrow.triangle.2.circlepath")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Ejector.eject(d, force: force)
            DispatchQueue.main.async { [weak self] in self?.finish(d, result) }
        }
    }

    private func finish(_ d: Drive, _ result: EjectResult) {
        ejecting.remove(d.id)
        if ejecting.isEmpty { setIcon("eject") }
        switch result {
        case .ejected:
            notify("\(d.displayName) is safe to unplug", "You can remove the drive now.")
            flashIcon("checkmark.circle")
        case let .busy(holders, message):
            handleBusy(d, holders, message)
        case let .failed(message):
            alert("Could not eject \(d.displayName)", message.isEmpty ? "macOS did not say why." : message)
        }
        rescan()
    }

    private func handleBusy(_ d: Drive, _ holders: [Holder], _ message: String) {
        let apps = holders.compactMap { NSRunningApplication(processIdentifier: $0.pid) }
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }

        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "\(d.displayName) is in use"
        var info = holders.isEmpty
            ? "Something still has files open on it, but macOS did not say what."
            : "These programs have files open on it:\n" + holders.map { "  •  \($0.name) (PID \($0.pid))" }.joined(separator: "\n")
        info += "\n\nClose them and try again. Force eject unmounts anyway, which can lose unsaved work in those programs."
        a.informativeText = info
        if !apps.isEmpty { a.addButton(withTitle: apps.count == 1 ? "Quit \(apps[0].localizedName ?? "App") and Eject" : "Quit Apps and Eject") }
        a.addButton(withTitle: "Try Again")
        a.addButton(withTitle: "Force Eject")
        a.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        var choice = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if apps.isEmpty { choice += 1 }
        switch choice {
        case 0: quitThenEject(d, apps)
        case 1: start(d, force: false)
        case 2: if confirmForce(d, holders: holders) { start(d, force: true) }
        default: break
        }
    }

    private func quitThenEject(_ d: Drive, _ apps: [NSRunningApplication]) {
        apps.forEach { $0.terminate() }
        ejecting.insert(d.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, apps.contains(where: { !$0.isTerminated }) { usleep(200_000) }
            DispatchQueue.main.async { [weak self] in
                self?.ejecting.remove(d.id)
                self?.start(d, force: false)
            }
        }
    }

    private func confirmForce(_ d: Drive, holders: [Holder]) -> Bool {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Force eject \(d.displayName)?"
        a.informativeText = "Programs with files open on the drive can lose unsaved work, and a file that is being written can end up damaged. Use this only when a normal eject keeps failing."
        a.addButton(withTitle: "Force Eject")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Helpers

    private func drive(_ item: NSMenuItem) -> Drive? {
        guard let id = item.representedObject as? String else { return nil }
        return drives.first { $0.id == id }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, _ id: String?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = id
        return i
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    private func setIcon(_ name: String) {
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Unplug Tray")
        statusItem.button?.image?.isTemplate = true
    }

    private func flashIcon(_ name: String) {
        setIcon(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.ejecting.isEmpty else { return }
            self.setIcon("eject")
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
