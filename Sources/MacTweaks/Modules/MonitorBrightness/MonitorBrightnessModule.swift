import AppKit

/// Brightness sliders in the MacTweaks menu: the built-in display via DisplayServices, external ones over DDC/CI.
@MainActor
final class MonitorBrightnessModule: Module {
    let id = "monitorBrightness"
    let title = "Monitor Brightness Control"

    private var builtIn: [BuiltInDisplay] = []
    private var external: [ExternalMonitor] = []
    private var isRunning = false
    private var screenToken: NSObjectProtocol?

    func start() {
        isRunning = true
        // Displays connecting, disconnecting or waking up (or the lid closing) change what's available.
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.discover() } }
        discover()
    }

    func stop() {
        isRunning = false
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
        screenToken = nil
        builtIn = []
        external = []
    }

    func menuItems() -> [NSMenuItem] {
        let displays: [BrightnessControl] = builtIn + external
        guard !displays.isEmpty else {
            let item = NSMenuItem(title: "No adjustable displays", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            return [item]
        }
        return displays.map { display in
            let view = BrightnessSliderView(display: display)
            display.refresh { [weak view] value in view?.show(value) }
            let item = NSMenuItem()
            item.view = view
            return item
        }
    }

    private func discover() {
        builtIn = BuiltInDisplay.discover()
        ExternalMonitor.queue.async {
            let found = ExternalMonitor.discover()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.external = found
                }
            }
        }
    }
}

private final class BrightnessSliderView: NSView {
    private let display: BrightnessControl
    private let slider: NSSlider
    /// Once the user drags, a late-arriving refresh must not move the slider back.
    private var touched = false

    init(display: BrightnessControl) {
        self.display = display
        slider = NSSlider(value: Double(display.brightness), minValue: 0, maxValue: Double(display.maxBrightness),
                          target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))

        let label = NSTextField(labelWithString: display.name)
        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)

        let stack = NSStackView(views: [label, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ value: Int) {
        if !touched { slider.doubleValue = Double(value) }
    }

    @objc private func sliderChanged() {
        touched = true
        display.setBrightness(Int(slider.doubleValue.rounded()))
    }
}
