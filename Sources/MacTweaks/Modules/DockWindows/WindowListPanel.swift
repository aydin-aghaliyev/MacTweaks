import AppKit

struct DockWindow {
    let pid: pid_t
    let element: AXUIElement
    let title: String
    let isMinimized: Bool
}

/// Floating, non-activating list of window titles anchored to a Dock icon.
@MainActor
final class WindowListPanel {
    var onSelect: ((DockWindow) -> Void)?
    var onReorder: (([DockWindow]) -> Void)?
    var onMouseExit: (() -> Void)?

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let stack = NSStackView()
    private lazy var minWidth = stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
    private lazy var maxWidth = stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
    private var eventMonitor: Any?
    private var activationToken: NSObjectProtocol?

    init() {
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = HoverEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.onExit = { [weak self] in self?.onMouseExit?() }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            minWidth,
            maxWidth,
        ])
        panel.contentView = background
    }

    func contains(_ screenPoint: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    func hide() {
        panel.orderOut(nil)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        eventMonitor = nil
        activationToken = nil
    }

    /// The panel never becomes key, so it can't see the user moving on. While visible, dismiss it on
    /// clicks or typing in other apps (our own clicks aren't reported to global monitors) and on app switches.
    private func dismissOnOutsideActivity() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
            [weak self] _ in MainActor.assumeIsolated { self?.hide() }
        }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
    }

    /// `anchor` is the Dock item's frame in Accessibility coordinates.
    func show(title: String, windows: [DockWindow], anchor: CGRect) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let fontSize = CGFloat(min(max(Config.double("dock_window_list.font_size") ?? 13, 8), 32))
        // The panel fits its titles within these bounds; equal values give a fixed width.
        minWidth.constant = CGFloat(min(max(Config.double("dock_window_list.min_width") ?? 160, 100), 1200))
        maxWidth.constant = max(CGFloat(min(max(Config.double("dock_window_list.max_width") ?? 360 * fontSize / 13, 100), 1200)),
                                minWidth.constant)
        stack.addArrangedSubview(Row(title: title, fontSize: fontSize))
        for window in windows {
            let row = Row(window: window, fontSize: fontSize)
            row.onClick = { [weak self] in self?.onSelect?(window) }
            row.onDrag = { [weak self] row, event in self?.drag(row, with: event) }
            row.onDragEnd = { [weak self] in self?.endDrag() }
            stack.addArrangedSubview(row)
        }
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }

        panel.setFrame(frame(for: stack.fittingSize, anchor: anchor), display: true)
        panel.orderFrontRegardless()
        dismissOnOutsideActivity()
    }

    private var windowRows: [Row] {
        stack.arrangedSubviews.compactMap { $0 as? Row }.filter { $0.dockWindow != nil }
    }

    /// Moves the dragged row into the slot under the pointer; rows share a height, so this doesn't oscillate.
    private func drag(_ row: Row, with event: NSEvent) {
        let y = stack.convert(event.locationInWindow, from: nil).y
        let rows = windowRows
        guard let target = rows.firstIndex(where: { y >= $0.frame.minY && y < $0.frame.maxY }),
              let current = rows.firstIndex(of: row), target != current
        else { return }
        stack.removeArrangedSubview(row)
        stack.insertArrangedSubview(row, at: stack.arrangedSubviews.firstIndex(of: rows[target])! + (target > current ? 1 : 0))
    }

    private func endDrag() {
        onReorder?(windowRows.compactMap(\.dockWindow))
        if !contains(NSEvent.mouseLocation) { onMouseExit?() }
    }

    private func frame(for size: NSSize, anchor: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return NSRect(origin: .zero, size: size) }
        // Flip from Accessibility (top-left origin) to Cocoa (bottom-left origin) coordinates.
        let item = NSRect(x: anchor.minX, y: primary.frame.maxY - anchor.maxY,
                          width: anchor.width, height: anchor.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(item) } ?? primary
        let gap: CGFloat = 4

        var origin: NSPoint
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": origin = NSPoint(x: item.maxX + gap, y: item.midY - size.height / 2)
        case "right": origin = NSPoint(x: item.minX - gap - size.width, y: item.midY - size.height / 2)
        default: origin = NSPoint(x: item.midX - size.width / 2, y: item.maxY + gap)
        }
        let bounds = screen.frame.insetBy(dx: gap, dy: gap)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}

private final class HoverEffectView: NSVisualEffectView {
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) { onExit?() }
}

private final class Row: NSView {
    enum Style { case header, normal, dimmed }

    /// `nil` for the header row.
    let dockWindow: DockWindow?
    var onClick: (() -> Void)?
    var onDrag: ((Row, NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?

    private let label: NSTextField
    private let style: Style
    private var dragStart: NSPoint?
    private var isDragging = false

    convenience init(title: String, fontSize: CGFloat) {
        self.init(title: title, style: .header, window: nil, font: .boldSystemFont(ofSize: max(fontSize - 2, 8)))
    }

    convenience init(window: DockWindow, fontSize: CGFloat) {
        self.init(title: window.title, style: window.isMinimized ? .dimmed : .normal, window: window,
                  font: .systemFont(ofSize: fontSize))
    }

    private init(title: String, style: Style, window: DockWindow?, font: NSFont) {
        self.style = style
        self.dockWindow = window
        label = NSTextField(labelWithString: title)
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 4
        resetColors()

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func highlight() {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        label.textColor = .alternateSelectedControlTextColor
    }

    private func resetColors() {
        layer?.backgroundColor = nil
        label.textColor = style == .normal ? .labelColor : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard dockWindow != nil else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    // Hover is ignored while a button is down so only the dragged row stays highlighted.
    override func mouseEntered(with event: NSEvent) {
        if NSEvent.pressedMouseButtons == 0 { highlight() }
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging { resetColors() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard dockWindow != nil, let dragStart else { return }
        let point = event.locationInWindow
        if !isDragging, hypot(point.x - dragStart.x, point.y - dragStart.y) < 3 { return }
        isDragging = true
        highlight()
        onDrag?(self, event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; isDragging = false }
        if isDragging {
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { resetColors() }
            onDragEnd?()
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            resetColors()
            onClick?()
        }
    }
}
