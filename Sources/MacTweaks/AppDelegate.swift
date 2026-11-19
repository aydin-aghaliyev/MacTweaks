import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let modules: [Module] = [DockWindowsModule(), ScrollDirectionModule(), MonitorBrightnessModule()]
    private let actions: [Action] = [DockRefreshAction()]
    private var statusItem: NSStatusItem!

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
        actions.forEach { $0.cancel() }
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
        for action in actions {
            if action.isRunning {
                menu.addItem(NSMenuItem(title: action.title + "…", action: nil, keyEquivalent: ""))
            } else {
                let entry = item(action.title, #selector(runAction(_:)))
                entry.representedObject = action
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
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

    @objc private func runAction(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }

    @objc private func openAccessibilitySettings() {
        Accessibility.openSettings()
    }
}
