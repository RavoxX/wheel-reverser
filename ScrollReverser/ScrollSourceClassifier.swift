import AppKit
import CoreGraphics

enum ScrollSource {
    case mouse
    case trackpad
}

/// Decides whether a scroll event came from a mouse or a trackpad.
///
/// Like LinearMouse, it reads the HID event behind each scroll event (`CGEventCopyIOHIDEvent`)
/// and looks up the device that sent it (`IOHIDEventGetSenderID`). Momentum events that carry no
/// sender keep the source of the gesture that started them. If those private functions are
/// unavailable, it falls back to a heuristic based on gesture phases and finger count.
@MainActor
final class ScrollSourceClassifier {
    private typealias CopyHIDEventFunction = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias SenderIDFunction = @convention(c) (CFTypeRef) -> UInt64

    private static let copyHIDEvent = dlsym(dlopen(nil, RTLD_LAZY), "CGEventCopyIOHIDEvent")
        .map { unsafeBitCast($0, to: CopyHIDEventFunction.self) }
    private static let senderID = dlsym(dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY), "IOHIDEventGetSenderID")
        .map { unsafeBitCast($0, to: SenderIDFunction.self) }

    private let eventSystem = HIDEventSystem()
    private var sourcesBySender: [UInt64: ScrollSource] = [:]
    private var gestureSource = ScrollSource.trackpad
    private var touchCount = 0

    func observeGesture(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        touchCount = nsEvent.touches(matching: .touching, in: nil).count
    }

    func classify(_ event: CGEvent) -> ScrollSource {
        if let source = senderSource(of: event) {
            gestureSource = source
            return source
        }
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 {
            return gestureSource
        }
        return heuristicSource(of: event)
    }

    private func senderSource(of event: CGEvent) -> ScrollSource? {
        guard let copyHIDEvent = Self.copyHIDEvent, let senderID = Self.senderID,
              let hidEvent = copyHIDEvent(event)?.takeRetainedValue()
        else { return nil }

        let sender = senderID(hidEvent)
        guard sender != 0 else { return nil }
        if let source = sourcesBySender[sender] {
            return source
        }
        guard let service = eventSystem.service(registryID: sender) else { return nil }
        let source: ScrollSource = service.isTrackpad ? .trackpad : .mouse
        sourcesBySender[sender] = source
        return source
    }

    /// Line-based wheel events and continuous events without a gesture phase (smooth-scrolling
    /// mice) come from a mouse. Phased events come from a trackpad or a Magic Mouse, told apart
    /// by finger count when the gesture begins.
    private func heuristicSource(of event: CGEvent) -> ScrollSource {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
            return .mouse
        }
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        if phase == 0 {
            return .mouse
        }
        if phase == Int64(CGScrollPhase.began.rawValue) || phase == Int64(CGScrollPhase.mayBegin.rawValue) {
            gestureSource = touchCount >= 2 ? .trackpad : .mouse
        }
        return gestureSource
    }
}
