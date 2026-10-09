// Mouse acceleration and sensitivity, adapted from LinearMouse's PointerKit module and its
// Device / PointerSchemeApplication sources: https://github.com/linearmouse/linearmouse
//
// MIT License
//
// Copyright (c) 2021-2026 LinearMouse
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import IOKit.hid
import IOKit.hidsystem
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScrollReverser", category: "MouseMovement")

/// Gives mice linear, unaccelerated movement with an adjustable sensitivity.
///
/// Like LinearMouse, this never touches mouse-moved events. It configures the pointer services
/// of the HID event system, so movement keeps flowing through macOS's own input pipeline with
/// no extra processing or latency:
/// - `HIDUseLinearScalingMouseAcceleration = 1` (macOS 14+) makes the HID pointer filter replace
///   its acceleration curve with a constant multiplier (`IOHIDSimpleAccelerator` in Apple's
///   IOHIDFamily). That multiplier is the `HIDMouseAcceleration` value, set to the sensitivity.
/// - Without linear scaling support, `HIDMouseAcceleration = -1` turns the accelerator off
///   entirely, giving raw 1:1 movement without a sensitivity setting.
///
/// Trackpads are never modified.
@MainActor
final class MouseMovementController {
    static let sensitivityRange = 0.1 ... 6.0

    /// LinearMouse's fallback when the system value can't be read (macOS's default tracking speed).
    private static let defaultSystemAcceleration = 0.6875

    private var isEnabled = false
    private var sensitivity = 1.0
    private let eventSystem = HIDEventSystem()
    /// Each mouse's linear-scaling flag before it was first changed, by registry ID.
    private var baselines: [UInt64: Int] = [:]

    /// The tracking speed set in System Settings > Mouse.
    var systemTrackingSpeed: Double? {
        eventSystem.systemFixedProperty(kIOHIDMouseAccelerationTypeKey)
    }

    func update(enabled: Bool, sensitivity: Double) {
        let wasEnabled = isEnabled
        isEnabled = enabled
        self.sensitivity = sensitivity.clamped(to: Self.sensitivityRange)

        if enabled {
            eventSystem.startObserving { [weak self] in self?.applyToAllMice() }
            applyToAllMice()
        } else if wasEnabled {
            eventSystem.stopObserving()
            restoreAllMice()
        }
    }

    /// Hands control back to System Settings, e.g. when the app quits.
    func restore() {
        guard isEnabled else { return }
        restoreAllMice()
    }

    // MARK: - Applying

    /// Idempotent, so it's safe to run whenever devices or system properties change.
    private func applyToAllMice() {
        guard isEnabled else { return }
        for mouse in eventSystem.services().filter(\.isMouse) {
            if mouse.supportsLinearScaling {
                if let registryID = mouse.registryID, baselines[registryID] == nil {
                    baselines[registryID] = mouse.intProperty(kIOHIDUseLinearScalingMouseAccelerationKey)
                }
                // Same order as LinearMouse: switch to linear mode, then set the multiplier.
                mouse.setIntProperty(1, forKey: kIOHIDUseLinearScalingMouseAccelerationKey)
                mouse.setFixedProperty(sensitivity, forKey: mouse.accelerationKey)
            } else {
                mouse.setFixedProperty(-1, forKey: mouse.accelerationKey)
            }
        }
    }

    private func restoreAllMice() {
        let systemAcceleration = systemTrackingSpeed ?? Self.defaultSystemAcceleration
        let systemLinearScaling = eventSystem.systemIntProperty(kIOHIDUseLinearScalingMouseAccelerationKey)

        for mouse in eventSystem.services().filter(\.isMouse) {
            if mouse.supportsLinearScaling,
               let linear = systemLinearScaling ?? mouse.registryID.flatMap({ baselines[$0] }) {
                mouse.setIntProperty(linear, forKey: kIOHIDUseLinearScalingMouseAccelerationKey)
            }
            mouse.setFixedProperty(systemAcceleration, forKey: mouse.accelerationKey)
        }
        logger.info("Restored system pointer settings")
    }
}

// MARK: - HID services

/// A pointer service of the HID event system, i.e. one mouse, trackpad or pointing interface.
struct PointerService {
    let client: IOHIDServiceClient

    private static let appleVendorIDs: Set = [0x004C, 0x05AC]
    private static let magicMouseProductIDs: Set = [0x0269, 0x030D]

    var registryID: UInt64? {
        IOHIDServiceClientGetRegistryID(client) as? UInt64
    }

    /// Mice and other pointers, excluding trackpads. Magic Mouse is a multitouch digitizer too,
    /// so it's matched by ID first (as in LinearMouse's `Device.detectCategory`).
    var isMouse: Bool {
        guard conforms(to: kHIDPage_GenericDesktop, kHIDUsage_GD_Mouse)
            || conforms(to: kHIDPage_GenericDesktop, kHIDUsage_GD_Pointer)
        else { return false }

        if let vendorID = intProperty(kIOHIDVendorIDKey), let productID = intProperty(kIOHIDProductIDKey),
           Self.appleVendorIDs.contains(vendorID), Self.magicMouseProductIDs.contains(productID) {
            return true
        }
        return !conforms(to: kHIDPage_Digitizer, kHIDUsage_Dig_TouchPad)
            && accelerationKey != kIOHIDTrackpadAccelerationType
    }

    /// Present (macOS 14+) only on services whose filter supports linear scaling.
    var supportsLinearScaling: Bool {
        intProperty(kIOHIDUseLinearScalingMouseAccelerationKey) != nil
    }

    /// The property that holds this service's acceleration, normally `HIDMouseAcceleration`.
    var accelerationKey: String {
        property(kIOHIDPointerAccelerationTypeKey) as String? ?? kIOHIDMouseAccelerationTypeKey
    }

    func property<T>(_ key: String) -> T? {
        IOHIDServiceClientCopyProperty(client, key as CFString) as? T
    }

    func intProperty(_ key: String) -> Int? {
        (property(key) as NSNumber?)?.intValue
    }

    func setIntProperty(_ value: Int, forKey key: String) {
        guard intProperty(key) != value else { return }
        if !IOHIDServiceClientSetProperty(client, key as CFString, value as NSNumber) {
            logger.error("Failed to set \(key) on a pointer service")
        }
    }

    /// Acceleration values are 16.16 fixed-point numbers.
    func setFixedProperty(_ value: Double, forKey key: String) {
        let fixed = Int32((value * 65_536).rounded())
        guard (property(key) as NSNumber?)?.int32Value != fixed else { return }
        if !IOHIDServiceClientSetProperty(client, key as CFString, fixed as NSNumber) {
            logger.error("Failed to set \(key) on a pointer service")
        }
    }

    private func conforms(to usagePage: Int, _ usage: Int) -> Bool {
        IOHIDServiceClientConformsTo(client, UInt32(usagePage), UInt32(usage)) != 0
    }
}

/// The HID event system client, plus the private functions LinearMouse's PointerKit uses for
/// full property access and change notifications. Each falls back gracefully when missing.
@MainActor
private final class HIDEventSystem {
    private typealias CreateFunction = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
    private typealias SetMatchingFunction = @convention(c) (IOHIDEventSystemClient, CFArray) -> Void
    private typealias ScheduleFunction = @convention(c) (IOHIDEventSystemClient, CFRunLoop, CFString) -> Void
    private typealias ServiceBlock = @convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, IOHIDServiceClient?) -> Void
    private typealias RegisterMatchingFunction = @convention(c) (IOHIDEventSystemClient, @escaping ServiceBlock, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias PropertyCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, CFString?, CFTypeRef?) -> Void
    private typealias RegisterPropertyFunction = @convention(c) (IOHIDEventSystemClient, CFString, PropertyCallback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static func function<T>(_ name: String, as _: T.Type) -> T? {
        dlsym(iokit, name).map { unsafeBitCast($0, to: T.self) }
    }

    /// Properties macOS writes when the user changes mouse settings (from LinearMouse's DeviceManager).
    private static let observedProperties = [
        kIOHIDMouseAccelerationTypeKey,
        kIOHIDPointerResolutionKey,
        kIOHIDUseLinearScalingMouseAccelerationKey,
    ]

    /// The simple client can't read most pointer properties, so prefer the full client.
    private let client: IOHIDEventSystemClient = {
        if let create = HIDEventSystem.function("IOHIDEventSystemClientCreate", as: CreateFunction.self),
           let client = create(kCFAllocatorDefault) {
            return client.takeRetainedValue()
        }
        return IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    }()

    private var observingClient: IOHIDEventSystemClient?
    private var onChange: (() -> Void)?

    func services() -> [PointerService] {
        let clients = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return clients.map(PointerService.init)
    }

    func systemFixedProperty(_ key: String) -> Double? {
        (IOHIDEventSystemClientCopyProperty(client, key as CFString) as? NSNumber).map { Double($0.int32Value) / 65_536 }
    }

    func systemIntProperty(_ key: String) -> Int? {
        (IOHIDEventSystemClientCopyProperty(client, key as CFString) as? NSNumber)?.intValue
    }

    /// Calls `onChange` when a mouse connects (e.g. a Bluetooth mouse waking up) or macOS
    /// rewrites pointer settings, so they can be reapplied.
    func startObserving(onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard observingClient == nil,
              let create = Self.function("IOHIDEventSystemClientCreate", as: CreateFunction.self),
              let setMatching = Self.function("IOHIDEventSystemClientSetMatchingMultiple", as: SetMatchingFunction.self),
              let schedule = Self.function("IOHIDEventSystemClientScheduleWithRunLoop", as: ScheduleFunction.self),
              let registerMatching = Self.function("IOHIDEventSystemClientRegisterDeviceMatchingBlock", as: RegisterMatchingFunction.self),
              let registerProperty = Self.function("IOHIDEventSystemClientRegisterPropertyChangedCallback", as: RegisterPropertyFunction.self),
              let observer = create(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            logger.info("HID change notifications unavailable")
            return
        }

        let matching = [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        }
        setMatching(observer, matching as CFArray)

        registerMatching(observer, { [weak self] _, _, _ in
            MainActor.assumeIsolated { self?.servicesChanged() }
        }, nil, nil)

        let context = Unmanaged.passUnretained(self).toOpaque()
        for property in Self.observedProperties {
            registerProperty(observer, property as CFString, { target, _, _, _ in
                guard let target else { return }
                let system = Unmanaged<HIDEventSystem>.fromOpaque(target).takeUnretainedValue()
                MainActor.assumeIsolated { system.onChange?() }
            }, context, nil)
        }

        schedule(observer, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        observingClient = observer
    }

    func stopObserving() {
        onChange = nil
        if let observingClient,
           let unschedule = Self.function("IOHIDEventSystemClientUnscheduleWithRunLoop", as: ScheduleFunction.self) {
            unschedule(observingClient, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        observingClient = nil
    }

    /// macOS applies its own settings to a newly connected mouse as well, so apply again
    /// shortly after to make sure ours win.
    private func servicesChanged() {
        onChange?()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.onChange?()
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
