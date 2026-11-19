import AppKit

/// Reapplies the Dock edge so macOS updates the space available to windows.
@MainActor
final class DockRefreshAction: Action {
    let title = "Refresh Dock Position"

    private enum Edge: Int32 {
        case bottom = 2
        case left = 3
        case right = 4
    }

    private typealias Get = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
    private typealias Set = @convention(c) (Int32, Int32) -> Void

    // Resolve the private CoreDock API at runtime so its absence doesn't prevent the app from launching.
    private static let framework = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_LAZY
    )
    private static let get: Get? = symbol("CoreDockGetOrientationAndPinning")
    private static let set: Set? = symbol("CoreDockSetOrientationAndPinning")
    private static let keepPinning: Int32 = 0

    private var originalEdge: Edge?
    var isRunning: Bool { originalEdge != nil }

    func run() {
        guard !isRunning, !start() else { return }

        let alert = NSAlert()
        alert.messageText = "Couldn’t refresh the Dock position"
        alert.informativeText = "In System Settings → Desktop & Dock, move the Dock to another edge and then back."
        alert.runModal()
    }

    func cancel() {
        restore()
    }

    private func start() -> Bool {
        guard let get = Self.get, let set = Self.set else { return false }

        var orientation: Int32 = 0
        var pinning: Int32 = 0
        get(&orientation, &pinning)
        guard let edge = Edge(rawValue: orientation) else { return false }

        originalEdge = edge
        let temporaryEdge: Edge = edge == .bottom ? .left : .bottom
        set(temporaryEdge.rawValue, Self.keepPinning)

        // Give Dock time to apply the first move before restoring its position.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in
            self?.restore()
        }
        return true
    }

    private func restore() {
        guard let edge = originalEdge else { return }
        Self.set?(edge.rawValue, Self.keepPinning)
        originalEdge = nil
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let framework, let address = dlsym(framework, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
