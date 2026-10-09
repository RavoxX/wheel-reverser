import AppKit
import CoreGraphics

enum ScrollSource {
    case mouse
    case trackpad
}

/// Decides whether a scroll event came from a mouse or a trackpad.
///
/// macOS doesn't tag scroll events with their device, so this combines two signals:
/// - Line-based wheel events, and continuous events without a gesture phase (smooth-scrolling
///   mice), always come from a mouse.
/// - Phased events come from a trackpad or a Magic Mouse. Those are told apart by the finger
///   count of the latest touch gesture: trackpads scroll with two fingers, Magic Mouse with one.
///
/// The decision is made when a scroll gesture begins and kept through its momentum phase,
/// when no fingers are touching anymore.
struct ScrollSourceClassifier {
    private var touchCount = 0
    private var gestureSource = ScrollSource.trackpad

    mutating func observeGesture(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        touchCount = nsEvent.touches(matching: .touching, in: nil).count
    }

    mutating func classify(_ event: CGEvent) -> ScrollSource {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
            return .mouse
        }

        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        if momentumPhase != 0 {
            return gestureSource
        }
        if phase == 0 {
            return .mouse
        }
        if phase == Int64(CGScrollPhase.began.rawValue) || phase == Int64(CGScrollPhase.mayBegin.rawValue) {
            gestureSource = touchCount >= 2 ? .trackpad : .mouse
        }
        return gestureSource
    }
}
