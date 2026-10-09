import AppKit
import CoreGraphics

/// Intercepts scroll events system-wide and flips their direction per input device.
///
/// The tap is attached to the main run loop, so its callback always runs on the main thread.
@MainActor
final class ScrollEventTap {
    var reverseMouse = false
    var reverseTrackpad = false

    /// Called when macOS disables the tap because Accessibility access was revoked.
    var onPermissionLost: (() -> Void)?

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let classifier = ScrollSourceClassifier()

    /// Returns `false` if the tap couldn't be created, which usually means missing permission.
    @discardableResult
    func start() -> Bool {
        guard machPort == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << NSEvent.EventType.gesture.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        machPort = port
        runLoopSource = source
        return true
    }

    func stop() {
        guard let port = machPort else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(port)
        machPort = nil
        runLoopSource = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .scrollWheel:
            let shouldReverse = switch classifier.classify(event) {
            case .mouse: reverseMouse
            case .trackpad: reverseTrackpad
            }
            if shouldReverse {
                Self.reverse(event)
            }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if AccessibilityPermission.isGranted, let machPort {
                CGEvent.tapEnable(tap: machPort, enable: true)
            } else {
                stop()
                onPermissionLost?()
            }

        default:
            if type.rawValue == NSEvent.EventType.gesture.rawValue {
                classifier.observeGesture(event)
            }
        }
    }

    private static func reverse(_ event: CGEvent) {
        let lineY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let lineX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let pointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)

        // Order matters: setting the line delta makes the system recompute the other two,
        // so it goes first and the precise values overwrite the recomputed ones.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lineY)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -lineX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixedX)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pointY)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -pointX)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let tap = Unmanaged<ScrollEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        // The tap's run loop source is on the main run loop, so the event never leaves this thread.
        nonisolated(unsafe) let event = event
        MainActor.assumeIsolated {
            tap.handle(type, event)
        }
    }
    return Unmanaged.passUnretained(event)
}
