// Adapted from Scroll Reverser by Nick Moore (pilotmoon), Apache License 2.0:
// https://github.com/pilotmoon/scroll-reverser (MouseTap.m, ScrollSource.m).
// Rewritten in Swift and reduced to a per-device-type direction. See THIRD_PARTY_NOTICES.md.

import AppKit
import IOKit

/// Sets the scroll direction separately for trackpads and mice; macOS only has one shared "natural scrolling" switch.
@MainActor
final class ScrollDirectionModule: Module {
    let id = "scrollDirection"
    let title = "Scroll Direction"

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var retryTimer: Timer?
    /// Whether each HID sender is a trackpad (`nil`: not in the registry). Registry entry IDs aren't reused within a boot.
    private var trackpadBySender: [UInt64: Bool?] = [:]

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard Accessibility.isTrusted(),
              let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: scrollTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
    }

    func stop() {
        retryTimer?.invalidate()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        // macOS disables taps that respond slowly or get interrupted; turn it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .scrollWheel, let natural = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice else { return }

        // Unidentified sources (synthetic events, Universal Control) fall back to: continuous scrolling means trackpad.
        let hidEvent = HIDEvent(event)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let trackpad = hidEvent.flatMap { isTrackpad(sender: $0.senderID) } ?? continuous

        let key = trackpad ? "scroll_direction.trackpad" : "scroll_direction.mouse"
        let wantNatural: Bool
        switch Config.string(key)?.lowercased() ?? (trackpad ? "natural" : "classic") {
        case "natural": wantNatural = true
        case "classic": wantNatural = false
        default: return // "system" or anything else: leave as macOS has it
        }
        if wantNatural != natural { reverse(event, hidEvent) }
    }

    /// Point and fixed-point deltas must be written after the line delta: writing the line delta makes macOS
    /// recompute the others from it, which would lose smooth scrolling. So read everything first.
    private func reverse(_ event: CGEvent, _ hidEvent: HIDEvent?) {
        let axes: [(line: CGEventField, point: CGEventField, fixed: CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2),
        ]
        for axis in axes {
            let line = event.getIntegerValueField(axis.line)
            let point = event.getIntegerValueField(axis.point)
            let fixed = event.getDoubleValueField(axis.fixed)
            event.setIntegerValueField(axis.line, value: -line)
            event.setDoubleValueField(axis.fixed, value: -fixed)
            event.setIntegerValueField(axis.point, value: -point)
        }
        hidEvent?.negateScroll()
    }

    /// The sender is the registry entry ID of the HID service. Trackpads declare trackpad scroll acceleration,
    /// or are driven by the multitouch trackpad driver (which publishes the sending service as its child).
    private func isTrackpad(sender: UInt64) -> Bool? {
        guard sender != 0 else { return nil }
        if let cached = trackpadBySender[sender] { return cached }

        var result: Bool?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender))
        if service != 0 {
            let acceleration = IORegistryEntryCreateCFProperty(service, "HIDScrollAccelerationType" as CFString,
                                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            result = acceleration == "HIDTrackpadScrollAcceleration"
                || conforms(service, toSelfOrParent: "AppleMultitouchTrackpadHIDEventDriver")
            IOObjectRelease(service)
        }
        trackpadBySender[sender] = result
        return result
    }

    private func conforms(_ service: io_service_t, toSelfOrParent className: String) -> Bool {
        if IOObjectConformsTo(service, className) != 0 { return true }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, "IOService", &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return IOObjectConformsTo(parent, className) != 0
    }
}

private func scrollTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                               _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        let module = Unmanaged<ScrollDirectionModule>.fromOpaque(refcon).takeUnretainedValue()
        nonisolated(unsafe) let event = event // the tap's run loop source is on the main run loop
        MainActor.assumeIsolated { module.handle(type, event) }
    }
    return Unmanaged.passUnretained(event)
}

/// The IOHIDEvent behind a CGEvent, through private CoreGraphics/IOKit functions (as Scroll Reverser uses).
/// Looked up at runtime, so if Apple removes them the module degrades to the continuous-scrolling guess.
@MainActor
private struct HIDEvent {
    private typealias Copy = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias GetSender = @convention(c) (CFTypeRef) -> UInt64
    private typealias GetFloat = @convention(c) (CFTypeRef, UInt32) -> Double
    private typealias SetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void

    private static let copy: Copy? = symbol("CGEventCopyIOHIDEvent")
    private static let getSender: GetSender? = symbol("IOHIDEventGetSenderID")
    private static let getFloat: GetFloat? = symbol("IOHIDEventGetFloatValue")
    private static let setFloat: SetFloat? = symbol("IOHIDEventSetFloatValue")
    private static let scrollFields: [UInt32] = [6 << 16, 6 << 16 | 1] // kIOHIDEventFieldScrollX, ScrollY

    private let ref: CFTypeRef

    init?(_ event: CGEvent) {
        guard let ref = Self.copy?(event)?.takeRetainedValue() else { return nil }
        self.ref = ref
    }

    var senderID: UInt64 { Self.getSender?(ref) ?? 0 }

    func negateScroll() {
        guard let getFloat = Self.getFloat, let setFloat = Self.setFloat else { return }
        for field in Self.scrollFields { setFloat(ref, field, -getFloat(ref, field)) }
    }

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) } // RTLD_DEFAULT
    }
}
