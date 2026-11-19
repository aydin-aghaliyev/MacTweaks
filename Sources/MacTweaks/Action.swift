import AppKit

/// A one-off command run from the menu bar, listed below the modules.
@MainActor
protocol Action: AnyObject {
    /// Name shown in the menu.
    var title: String { get }
    /// While true, the menu shows the action greyed out with a trailing ellipsis.
    var isRunning: Bool { get }
    func run()
    /// Called when MacTweaks quits, to undo any half-finished work.
    func cancel()
}

extension Action {
    var isRunning: Bool { false }
    func cancel() {}
}
