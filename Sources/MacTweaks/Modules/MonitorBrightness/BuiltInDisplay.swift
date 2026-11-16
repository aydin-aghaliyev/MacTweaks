import AppKit

/// A display whose brightness a menu slider can drive, on a 0...`maxBrightness` scale.
@MainActor
protocol BrightnessControl: AnyObject {
    var name: String { get }
    var maxBrightness: Int { get }
    var brightness: Int { get }
    func setBrightness(_ value: Int)
    /// Re-reads the value, which may have changed outside MacTweaks, and reports it on the main actor.
    func refresh(then update: @escaping @MainActor (Int) -> Void)
}

/// The built-in panel, through the private DisplayServices framework (what the brightness keys use).
/// DisplayServices works in 0–1; this exposes 0–100 like the DDC monitors.
final class BuiltInDisplay: BrightnessControl {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool

    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let get: Get? = symbol("DisplayServicesGetBrightness")
    private static let set: Set? = symbol("DisplayServicesSetBrightness")
    private static let canChange: CanChange? = symbol("DisplayServicesCanChangeBrightness")

    let name: String
    let maxBrightness = 100
    private let displayID: CGDirectDisplayID

    private init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let screen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }
        name = screen?.localizedName ?? "Built-in Display"
    }

    /// Online built-in displays (none while the lid is closed).
    static func discover() -> [BuiltInDisplay] {
        guard let canChange else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        return ids.prefix(Int(count))
            .filter { CGDisplayIsBuiltin($0) != 0 && canChange($0) }
            .map(BuiltInDisplay.init)
    }

    var brightness: Int {
        var value: Float = 0
        guard Self.get?(displayID, &value) == 0 else { return 0 }
        return Int((value * 100).rounded())
    }

    func setBrightness(_ value: Int) {
        _ = Self.set?(displayID, Float(value) / 100)
    }

    func refresh(then update: @escaping @MainActor (Int) -> Void) {
        update(brightness) // a local call, fast enough to answer synchronously
    }

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(framework, name).map { unsafeBitCast($0, to: T.self) }
    }
}
