import AppKit
import ApplicationServices

/// Shows a text list of an app's windows (current Space only) while hovering its Dock icon.
/// Clicking an entry brings that window to the front.
@MainActor
final class DockWindowsModule: Module {
    let id = "dockWindows"
    let title = "Dock Window List"

    private let panel = WindowListPanel()
    private var observer: AXObserver?
    private var dockList: AXUIElement?
    private var retryTimer: Timer?
    private var hideTimer: Timer?
    private var dockLaunchToken: NSObjectProtocol?
    /// Per-app window order as last shown or dragged, so the list doesn't reshuffle on every focus change.
    /// Kept in memory only: macOS has no window identity that survives relaunches.
    private var windowOrder: [pid_t: [AXUIElement]] = [:]

    init() {
        panel.onSelect = { [weak self] window in self?.focus(window) }
        panel.onReorder = { [weak self] windows in self?.remember(windows) }
        panel.onMouseExit = { [weak self] in self?.scheduleHide() }
    }

    func start() {
        // The Dock relaunches after crashes and some settings changes; reattach when it does.
        dockLaunchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated { self?.retryAttach() }
        }
        attach()
    }

    func stop() {
        if let dockLaunchToken { NSWorkspace.shared.notificationCenter.removeObserver(dockLaunchToken) }
        dockLaunchToken = nil
        retryTimer?.invalidate()
        detach()
        panel.hide()
    }

    // MARK: Dock observation

    private func attach() {
        detach()
        guard Accessibility.isTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return retryAttach() }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var created: AXObserver?
        guard let list = dockElement.elements(kAXChildrenAttribute).first(where: { $0.string(kAXRoleAttribute) == kAXListRole }),
              AXObserverCreate(dock.processIdentifier, dockSelectionCallback, &created) == .success,
              let created
        else { return retryAttach() }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, list, kAXSelectedChildrenChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        dockList = list
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockList = nil
    }

    /// Covers both "Accessibility not granted yet" and "Dock not ready yet".
    private func retryAttach() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    fileprivate func dockSelectionChanged() {
        guard let item = dockList?.elements(kAXSelectedChildrenAttribute).first else { return scheduleHide() }
        guard item.string(kAXSubroleAttribute) == "AXApplicationDockItem",
              let app = runningApp(for: item),
              let itemFrame = item.frame
        else { return panel.hide() }

        let windows = ordered(Self.windows(of: app), pid: app.processIdentifier)
        guard windows.count > 1 else { return panel.hide() } // a single window is reachable by clicking the icon
        remember(windows)
        hideTimer?.invalidate()
        panel.show(title: app.localizedName ?? "", windows: windows, anchor: itemFrame)
    }

    /// Known windows keep their remembered position; new ones go to the bottom.
    private func ordered(_ windows: [DockWindow], pid: pid_t) -> [DockWindow] {
        let known = windowOrder[pid] ?? []
        let kept = known.compactMap { element in windows.first { $0.element == element } }
        return kept + windows.filter { !known.contains($0.element) }
    }

    private func remember(_ windows: [DockWindow]) {
        guard let pid = windows.first?.pid else { return }
        windowOrder = windowOrder.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        windowOrder[pid] = windows.map(\.element)
    }

    private func runningApp(for item: AXUIElement) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let path = item.url(kAXURLAttribute)?.resolvingSymlinksInPath().path,
           let app = apps.first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == path }) {
            return app
        }
        let name = item.string(kAXTitleAttribute)
        return apps.first { $0.localizedName == name }
    }

    // MARK: Windows

    private static func windows(of app: NSRunningApplication) -> [DockWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3) // don't hang on unresponsive apps
        return appElement.elements(kAXWindowsAttribute).compactMap { window in
            let minimized = window.bool(kAXMinimizedAttribute) ?? false
            guard minimized || window.string(kAXSubroleAttribute) == kAXStandardWindowSubrole else { return nil }
            let title = window.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
            return DockWindow(pid: app.processIdentifier, element: window,
                              title: title ?? app.localizedName ?? "Untitled", isMinimized: minimized)
        }
    }

    private func focus(_ window: DockWindow) {
        panel.hide()
        NSRunningApplication(processIdentifier: window.pid)?.unhide()
        if window.isMinimized { window.element.set(kAXMinimizedAttribute, false) }
        window.element.perform(kAXRaiseAction)
        window.element.set(kAXMainAttribute, true)
        AXUIElementCreateApplication(window.pid).set(kAXFrontmostAttribute, true)
    }

    // MARK: Hiding

    /// Delay gives the pointer time to travel from the Dock icon into the panel.
    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panel.contains(NSEvent.mouseLocation),
                      NSEvent.pressedMouseButtons == 0 // mid-drag; the drag end re-checks
                else { return }
                self.panel.hide()
            }
        }
    }
}

private func dockSelectionCallback(_ observer: AXObserver, _ element: AXUIElement,
                                   _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let module = Unmanaged<DockWindowsModule>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { module.dockSelectionChanged() }
}
