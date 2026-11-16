// Adapted from MonitorControl (Arm64DDC.swift), MIT License, Copyright © 2017 MonitorControl
// (@JoniVR, @theOneyouseek, @waydabber and others): https://github.com/MonitorControl/MonitorControl
// Reduced to Apple Silicon brightness read/write. See THIRD_PARTY_NOTICES.md.

import Foundation
import IOKit
import os

/// An external display that answers DDC/CI. Everything except `state` is immutable;
/// all I/O runs on `queue`, since a DDC transaction takes tens of milliseconds and they must not interleave.
nonisolated final class ExternalMonitor: BrightnessControl, @unchecked Sendable {
    static let queue = DispatchQueue(label: "MacTweaks.ddc")

    let name: String
    let maxBrightness: Int
    private let service: CFTypeRef

    private struct State: Sendable {
        var current: Int
        var target: Int?
    }
    private let state: OSAllocatedUnfairLock<State>

    private init(name: String, service: CFTypeRef, current: Int, max: Int) {
        self.name = name
        self.service = service
        self.maxBrightness = max
        state = OSAllocatedUnfairLock(initialState: State(current: current))
    }

    var brightness: Int { state.withLock { $0.target ?? $0.current } }

    /// Coalesces rapid calls (slider drags): each queued write sends the latest value, later ones find nothing to do.
    func setBrightness(_ value: Int) {
        state.withLock { $0.target = value }
        Self.queue.async { [self] in
            guard let target = state.withLock({ state -> Int? in
                defer { state.target = nil }
                return state.target
            }) else { return }
            state.withLock { $0.current = target }
            DDC.write(service, code: DDC.brightness, value: UInt16(target))
        }
    }

    /// Re-reads the value, which may have been changed with the monitor's own buttons.
    func refresh(then update: @escaping @MainActor (Int) -> Void) {
        Self.queue.async { [self] in
            guard let value = DDC.read(service, code: DDC.brightness)?.current else { return }
            state.withLock { $0.current = Int(value) }
            DispatchQueue.main.async { MainActor.assumeIsolated { update(Int(value)) } }
        }
    }

    /// Walks the IORegistry, where each display's framebuffer (named by its EDID attributes) is followed by its
    /// DCPAVServiceProxy, the I2C channel. Only external ones that answer a brightness read are returned.
    /// Blocking; call on `queue`.
    static func discover() -> [ExternalMonitor] {
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var monitors: [ExternalMonitor] = []
        var productName = "External Display"
        var nameBuffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS else { continue }
            switch String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) {
            case "AppleCLCD2", "IOMobileFramebufferShim":
                let attributes = property(entry, "DisplayAttributes") as? [String: Any]
                let product = attributes?["ProductAttributes"] as? [String: Any]
                productName = product?["ProductName"] as? String ?? "External Display"
            case "DCPAVServiceProxy":
                guard property(entry, "Location") as? String == "External",
                      let service = DDC.createService?(kCFAllocatorDefault, entry)?.takeRetainedValue(),
                      let (current, max) = DDC.read(service, code: DDC.brightness), max > 0
                else { continue }
                let duplicates = monitors.filter { $0.name.hasPrefix(productName) }.count
                let name = duplicates == 0 ? productName : "\(productName) (\(duplicates + 1))"
                monitors.append(ExternalMonitor(name: name, service: service, current: Int(current), max: Int(max)))
            default:
                continue
            }
        }
        return monitors
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// DDC/CI over the private IOAVService I2C functions (Apple Silicon), looked up at runtime.
private enum DDC {
    typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let createService: CreateService? = symbol("IOAVServiceCreateWithService")
    static let readI2C: TransferI2C? = symbol("IOAVServiceReadI2C")
    static let writeI2C: TransferI2C? = symbol("IOAVServiceWriteI2C")

    static let brightness: UInt8 = 0x10 // VCP code
    private static let address: UInt32 = 0x37 // 7-bit DDC/CI address (0x6E written)
    private static let hostAddress: UInt8 = 0x51

    /// Returns (current, max), or nil if the display doesn't answer.
    static func read(_ service: CFTypeRef, code: UInt8) -> (current: UInt16, max: UInt16)? {
        var reply = [UInt8](repeating: 0, count: 11)
        guard transfer(service, send: [code], reply: &reply) else { return nil }
        return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
    }

    @discardableResult
    static func write(_ service: CFTypeRef, code: UInt8, value: UInt16) -> Bool {
        var reply: [UInt8] = []
        return transfer(service, send: [code, UInt8(value >> 8), UInt8(value & 0xFF)], reply: &reply)
    }

    /// Timings and retry counts are MonitorControl's defaults: writes are repeated because some displays
    /// drop the first one, and replies need a pause before they can be read back.
    private static func transfer(_ service: CFTypeRef, send: [UInt8], reply: inout [UInt8]) -> Bool {
        guard let readI2C, let writeI2C else { return false }
        var packet = [0x80 | UInt8(send.count + 1), UInt8(send.count)] + send
        packet.append(packet.reduce(UInt8(address << 1) ^ hostAddress, ^))

        for _ in 0..<5 {
            var success = false
            for _ in 0..<2 {
                usleep(10_000)
                success = writeI2C(service, address, UInt32(hostAddress), &packet, UInt32(packet.count)) == 0
            }
            if !reply.isEmpty {
                usleep(50_000)
                success = readI2C(service, address, 0, &reply, UInt32(reply.count)) == 0
                    && reply.dropLast().reduce(0x50, ^) == reply.last
            }
            if success { return true }
            usleep(20_000)
        }
        return false
    }

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) } // RTLD_DEFAULT
    }
}
