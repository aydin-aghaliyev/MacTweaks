import AppKit
import ApplicationServices

enum Accessibility {
    /// Whether MacTweaks has Accessibility access. With `prompt`, macOS shows its permission dialog if not.
    static func isTrusted(prompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

extension AXUIElement {
    func value(of attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { value(of: attribute) as? String }
    func bool(_ attribute: String) -> Bool? { value(of: attribute) as? Bool }
    func url(_ attribute: String) -> URL? { value(of: attribute) as? URL }
    func elements(_ attribute: String) -> [AXUIElement] { value(of: attribute) as? [AXUIElement] ?? [] }

    /// Frame in Accessibility coordinates: origin at the top-left of the primary screen, y pointing down.
    var frame: CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = axValue(kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let extent = axValue(kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func set(_ attribute: String, _ value: Bool) {
        AXUIElementSetAttributeValue(self, attribute as CFString, value as CFBoolean)
    }

    func perform(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }

    private func axValue(_ attribute: String) -> AXValue? {
        guard let value = value(of: attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
