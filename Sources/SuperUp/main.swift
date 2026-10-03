import AppKit
import ServiceManagement
import SuperUpCore

@MainActor
final class SuperUpApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let configDirectory = ConfigLoader.userDirectory()
    private let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SuperUp", isDirectory: true)
    private var manager: ServerManager!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let menuImageSize = NSSize(width: 12, height: 12)
    private var configError: String?
    private var loginError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try ConfigLoader.prepareDirectory(at: configDirectory)
        } catch {
            configError = "Config setup failed: \(error.localizedDescription)"
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "SuperUp")
        statusItem.button?.imagePosition = .imageLeft
        statusItem.menu = menu
        menu.delegate = self

        manager = ServerManager(configDirectory: configDirectory, logDirectory: logDirectory) { url in
            NSWorkspace.shared.open(url)
        }
        manager.onUpdate = { [weak self] in self?.updateStatusItem() }
        manager.start()
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stopAll()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.title = " \(manager.healthyCount)"
        button.toolTip = "SuperUp: \(manager.healthyCount) of \(manager.statuses.count) local apps running"
        button.setAccessibilityLabel(button.toolTip ?? "SuperUp")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let statuses = manager.statuses
        if statuses.isEmpty {
            let item = NSMenuItem(title: "No configured apps", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let hint = NSMenuItem(title: "Add an app JSON in Open Config Folder", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        for status in statuses {
            let title = status.message == "Running" || status.message == "Running externally"
                ? status.config.name : "\(status.config.name) — \(status.message)"
            let item = NSMenuItem(title: title, action: #selector(selectApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = status.config.id
            item.image = menuImage(status.healthy ? .systemGreen : .systemRed)
            menu.addItem(item)

            if status.owned {
                let stop = NSMenuItem(title: "Stop \(status.config.name)", action: #selector(stopApp(_:)), keyEquivalent: "")
                stop.target = self
                stop.representedObject = status.config.id
                stop.image = menuImage()
                menu.addItem(stop)
            }
            if let logURL = manager.logURL(for: status.config.id), FileManager.default.fileExists(atPath: logURL.path) {
                let log = NSMenuItem(title: "View Log", action: #selector(viewLog(_:)), keyEquivalent: "")
                log.target = self
                log.representedObject = status.config.id
                log.image = menuImage()
                menu.addItem(log)
            }
        }
        if !manager.issues.isEmpty {
            menu.addItem(.separator())
            for issue in manager.issues {
                let item = NSMenuItem(title: "⚠ \(issue.filename): \(issue.message)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        addItem("Open Config Folder", action: #selector(openConfigFolder))
        addItem("Reload Configs", action: #selector(reloadConfigs))

        if let configError {
            let item = NSMenuItem(title: configError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let login = NSMenuItem(title: loginStatusTitle(), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.isEnabled = isInstalled
        if !isInstalled {
            let hint = NSMenuItem(title: "Install to enable Launch at Login", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(login)
        if SMAppService.mainApp.status != .enabled {
            addItem("Open Login Items Settings", action: #selector(openLoginItems))
        }
        if let loginError {
            let item = NSMenuItem(title: loginError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem("Quit SuperUp", action: #selector(quit), keyEquivalent: "q")
    }

    private func addItem(_ title: String, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private func menuImage(_ color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: menuImageSize, flipped: false) { rect in
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func loginStatusTitle() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Launch at Login: On"
        case .requiresApproval: return "Launch at Login: Needs approval"
        default: return "Launch at Login: Off"
        }
    }

    private var isInstalled: Bool {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/SuperUp.app").standardizedFileURL
        return Bundle.main.bundleURL.standardizedFileURL == installed
    }

    @objc private func toggleLaunchAtLogin() {
        guard isInstalled else { return }
        loginError = nil
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            loginError = "Launch at Login: \(error.localizedDescription)"
            NSLog("SuperUp login setting failed: %@", error.localizedDescription)
        }
    }

    @objc private func selectApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        manager.select(id)
    }

    @objc private func stopApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        manager.stop(id)
    }

    @objc private func viewLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let url = manager.logURL(for: id) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openConfigFolder() { NSWorkspace.shared.open(configDirectory) }
    @objc private func reloadConfigs() { manager.reloadConfigs() }
    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct SuperUpMain {
    @MainActor static var delegate: SuperUpApp?

    static func main() {
        if CommandLine.arguments.contains("--login-status") {
            print("bundle: \(Bundle.main.bundleURL.path)")
            print("login status: \(SMAppService.mainApp.status.rawValue)")
            return
        }
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let appDelegate = SuperUpApp()
            delegate = appDelegate
            application.delegate = appDelegate
            application.setActivationPolicy(.accessory)
            application.run()
        }
    }
}
