import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let modules: [Module] = [DockWindowsModule(), ScrollDirectionModule(), MonitorBrightnessModule()]
    private var statusItem: NSStatusItem!
    private let dockRefresh = DockRefresh()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "MacTweaks")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !Accessibility.isTrusted() { _ = Accessibility.isTrusted(prompt: true) }
        for module in modules where isEnabled(module) { module.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockRefresh.restore()
    }

    // Rebuilt on every open so checkmarks reflect the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Accessibility.isTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }

        for module in modules {
            let entry = item(module.title, #selector(toggleModule(_:)))
            entry.representedObject = module.id
            entry.state = isEnabled(module) ? .on : .off
            menu.addItem(entry)
            if isEnabled(module) { module.menuItems().forEach(menu.addItem) }
        }

        menu.addItem(.separator())
        if dockRefresh.isRefreshing {
            menu.addItem(NSMenuItem(title: "Refreshing Dock Position…", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(item("Refresh Dock Position", #selector(refreshDockPosition)))
        }
        menu.addItem(item("Open Config File…", #selector(openConfig)))
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit MacTweaks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func isEnabled(_ module: Module) -> Bool {
        UserDefaults.standard.object(forKey: "module.\(module.id).enabled") as? Bool ?? true
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let module = modules.first(where: { $0.id == sender.representedObject as? String }) else { return }
        let enable = !isEnabled(module)
        UserDefaults.standard.set(enable, forKey: "module.\(module.id).enabled")
        enable ? module.start() : module.stop()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("MacTweaks: launch at login failed: \(error)")
        }
    }

    @objc private func openConfig() {
        Config.openInEditor()
    }

    @objc private func refreshDockPosition() {
        guard !dockRefresh.isRefreshing else { return }
        guard !dockRefresh.start() else { return }

        let alert = NSAlert()
        alert.messageText = "Couldn’t refresh the Dock position"
        alert.informativeText = "In System Settings → Desktop & Dock, move the Dock to another edge and then back."
        alert.runModal()
    }

    @objc private func openAccessibilitySettings() {
        Accessibility.openSettings()
    }
}
