import SwiftUI
import UIKit

/// A custom chart's touch handling (#2682, extracted from #2673's weight chart), in UIKit
/// rather than SwiftUI gestures for two reasons that are fatal inside a scrolling list: a
/// `DragGesture` claims *every* touch on the chart, including the vertical ones the
/// enclosing `List` needs to scroll, and a `MagnifyGesture` running alongside it grabs
/// single-finger drags often enough to feel like the chart is fighting the finger.
///
/// A `UIPanGestureRecognizer` that refuses to begin unless the movement is clearly
/// horizontal hands vertical swipes straight back to the list, and a pinch that only ever
/// recognises two touches can then run beside it safely.
///
/// Note that `UIGestureRecognizerRepresentable` does **not** conform to `Gesture` — there is
/// exactly one modifier that takes one, `.gesture(_:)`. `.simultaneousGesture` and
/// `.highPriorityGesture` won't compile with these. Chain plain `.gesture()` calls and let
/// the delegates below settle simultaneity, which is UIKit's job anyway.

/// Tagged so the recognisers can identify each other for simultaneous recognition without
/// also volunteering to run alongside the enclosing scroll view's own pan.
public final class ChartPanRecognizer: UIPanGestureRecognizer {}
public final class ChartPinchRecognizer: UIPinchGestureRecognizer {}

// MARK: - Pan

public struct ChartPanGesture: UIGestureRecognizerRepresentable {
    public let onBegan: () -> Void
    public let onChanged: (CGFloat) -> Void
    public let onEnded: (CGFloat) -> Void

    public func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    public func makeUIGestureRecognizer(context: Context) -> ChartPanRecognizer {
        let recognizer = ChartPanRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    public func handleUIGestureRecognizerAction(_ recognizer: ChartPanRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            // Zero the translation the recogniser accumulated before it decided to begin,
            // so the chart doesn't jump by the recognition threshold on the first frame.
            recognizer.setTranslation(.zero, in: recognizer.view)
            onBegan()
        case .changed:
            onChanged(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed:
            onEnded(recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            // Clearly horizontal, or the list keeps the swipe. A refused pan simply falls
            // through — this is what stops the chart from eating a vertical scroll.
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other is ChartPinchRecognizer
        }
    }
}

// MARK: - Pinch

public struct ChartPinchGesture: UIGestureRecognizerRepresentable {
    public let onBegan: () -> Void
    /// (magnification since the gesture began, where its centre started, how far that centre
    /// has travelled since)
    public let onChanged: (CGFloat, CGFloat, CGFloat) -> Void
    public let onEnded: () -> Void

    public func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    public func makeUIGestureRecognizer(context: Context) -> ChartPinchRecognizer {
        let recognizer = ChartPinchRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    public func handleUIGestureRecognizerAction(_ recognizer: ChartPinchRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began:
            context.coordinator.origin = location
            onBegan()
        case .changed:
            let origin = context.coordinator.origin ?? location
            onChanged(recognizer.scale, origin.x, location.x - origin.x)
        case .ended, .cancelled, .failed:
            context.coordinator.origin = nil
            onEnded()
        default:
            break
        }
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Where the pinch's centre started — the anchor the zoom holds still. Kept in the
        /// coordinator rather than in view `@State`: no timing questions, no extra body pass.
        public var origin: CGPoint?

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other is ChartPanRecognizer
        }
    }
}

// MARK: - Tap

/// A plain tap. The readout lives only under a finger, so a tap has nothing to inspect —
/// on a chart shown in a row it opens the full-screen one instead.
public struct ChartTapGesture: UIGestureRecognizerRepresentable {
    public let onTap: (CGPoint) -> Void

    public func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        UITapGestureRecognizer()
    }

    public func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        onTap(context.converter.localLocation)
    }
}

// MARK: - Scrub

/// Press and hold, then slide: the readout follows the finger along the data without the
/// chart panning underneath it.
///
/// Exclusivity against the pan is free — UIKit's default `canPrevent` is true, so whichever
/// recognises first prevents the other. Move before 0.22s and you pan; hold still and you
/// scrub. No `require(toFail:)`, which would delay *every* pan by 0.22s. And 0.22 is the
/// floor: any shorter and the long press wins over a slow, careful pan, so the chart scrubs
/// when the user meant to move it.
public struct ChartScrubGesture: UIGestureRecognizerRepresentable {
    public let onBegan: (CGPoint) -> Void
    public let onChanged: (CGPoint) -> Void
    public let onEnded: () -> Void

    public func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.22
        recognizer.allowableMovement = 14
        return recognizer
    }

    public func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            onBegan(context.converter.localLocation)
        case .changed:
            onChanged(context.converter.localLocation)
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }
}

// MARK: - Installing them

extension View {
    /// Attaches the four recognisers a custom chart needs. Plain `.gesture()` calls, chained
    /// — see the note at the top of this file for why they can't be `.simultaneousGesture`.
    public func chartGestures<Series: ChartSeries>(
        viewport: ChartViewport<Series>,
        transform: ChartTransform,
        onTap: (() -> Void)? = nil
    ) -> some View {
        let width = transform.plot.width
        let base = self
            .contentShape(Rectangle())
            .gesture(
                ChartPanGesture(
                    onBegan: { viewport.beginPan() },
                    onChanged: { viewport.pan(translation: $0, width: width) },
                    onEnded: { viewport.endPan(velocityX: $0, width: width) }
                )
            )
            .gesture(
                ChartPinchGesture(
                    onBegan: { viewport.beginPinch() },
                    onChanged: { scale, anchorX, travelled in
                        viewport.pinch(
                            scale: scale,
                            anchor: (anchorX - transform.plot.minX) / max(width, 1),
                            translation: travelled,
                            width: width
                        )
                    },
                    onEnded: { viewport.endPinch() }
                )
            )
            .gesture(
                ChartScrubGesture(
                    onBegan: { viewport.beginScrub(atX: $0.x, transform: transform) },
                    onChanged: { viewport.scrub(atX: $0.x, transform: transform) },
                    onEnded: { viewport.endScrub() }
                )
            )
        // Only when there is something for a tap to do. An inert recogniser still cancels
        // touches when it recognises, which would silently swallow the tap of an enclosing
        // card that wanted it.
        guard let onTap else { return AnyView(base) }
        return AnyView(
            base.gesture(
                ChartTapGesture { _ in
                    ChartHooks.impact(.soft)
                    onTap()
                }
            )
        )
    }
}
