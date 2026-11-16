import AppKit

/// A self-contained feature that can be switched on and off from the menu bar.
@MainActor
protocol Module: AnyObject {
    /// Stable identifier, used as the preferences key.
    var id: String { get }
    /// Name shown in the menu.
    var title: String { get }
    func start()
    func stop()
    /// Extra items shown under the module's toggle while it's enabled. Called each time the menu opens.
    func menuItems() -> [NSMenuItem]
}

extension Module {
    func menuItems() -> [NSMenuItem] { [] }
}
