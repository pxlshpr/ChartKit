import SwiftUI
import UIKit
import OSLog

// The slider's UIKit gestures, as NutriKit's TimeSlider had them (#3950 moved them here whole).

let timeSliderGestureLogger = Logger(subsystem: "com.pxlshpr.shipyard.timeslider", category: "gesture")

// MARK: - Horizontal pan (live mode)

/// A UIViewRepresentable that adds a UIPanGestureRecognizer which only activates for horizontal movements.
/// Vertical movements are rejected at the UIKit level, allowing parent scroll views to receive them.
/// The host can further gate where a pan may start via `shouldBeginPan`, and opt into a
/// tap-and-hold that drives the same pan callbacks via `shouldBeginLongPress` (NutriKit #2280).
struct HorizontalPanGestureView<Content: View>: UIViewRepresentable {
    let content: Content
    let onPanChanged: (CGPoint, CGPoint) -> Void          // (translation, location)
    let onPanEnded: (CGPoint, CGPoint, CGPoint) -> Void   // (translation, location, velocity)
    var onTap: ((CGPoint) -> Void)? = nil                 // (location)
    /// Gates the pan at the UIKit level: a horizontal pan only begins when this returns true
    /// for its starting location; refused pans fall through to surrounding gestures. nil means
    /// any clearly-horizontal pan may begin.
    var shouldBeginPan: ((CGPoint) -> Bool)? = nil
    /// When this returns true for the press location, a tap-and-hold begins driving the pan
    /// callbacks — translation synthesized relative to the press point, zero end velocity.
    /// nil (or returning false) disables the long press entirely.
    var shouldBeginLongPress: ((CGPoint) -> Bool)? = nil

    func makeUIView(context: Context) -> UIView {
        let containerView = HorizontalPanContainerView()
        containerView.backgroundColor = .clear

        // Create and configure the pan gesture
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.delegate = context.coordinator
        containerView.addGestureRecognizer(panGesture)

        // Create and configure the tap gesture
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.require(toFail: panGesture)
        containerView.addGestureRecognizer(tapGesture)

        // Tap-and-hold summons the needle where it isn't otherwise showing (NutriKit #2280).
        // Once begun it feeds the same pan callbacks, so the needle follows the finger
        // until release creates the meal (or dragging out cancels).
        let longPressGesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.4
        longPressGesture.delegate = context.coordinator
        containerView.addGestureRecognizer(longPressGesture)

        // Host the SwiftUI content
        let hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        // Ensure proper intrinsic content size calculation
        hostingController.sizingOptions = [.intrinsicContentSize]

        containerView.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        context.coordinator.hostingController = hostingController

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Forward the parent SwiftUI transaction across the UIViewRepresentable
        // boundary. Without this, `withAnimation { ... }` blocks set upstream
        // (e.g., in NutriKit's MealTimeSlotsStore.update) never reach the hosted SwiftUI
        // tree, so removal transitions on ForEach children fire without an
        // animation curve and snap out instantly.
        withTransaction(context.transaction) {
            context.coordinator.hostingController?.rootView = content
        }
        context.coordinator.onTap = onTap
        context.coordinator.shouldBeginPan = shouldBeginPan
        context.coordinator.shouldBeginLongPress = shouldBeginLongPress
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPanChanged: onPanChanged,
            onPanEnded: onPanEnded,
            onTap: onTap,
            shouldBeginPan: shouldBeginPan,
            shouldBeginLongPress: shouldBeginLongPress
        )
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var hostingController: UIHostingController<Content>?
        let onPanChanged: (CGPoint, CGPoint) -> Void
        let onPanEnded: (CGPoint, CGPoint, CGPoint) -> Void
        var onTap: ((CGPoint) -> Void)?
        var shouldBeginPan: ((CGPoint) -> Bool)?
        var shouldBeginLongPress: ((CGPoint) -> Bool)?

        /// Where the active long press started — translations for the pan callbacks
        /// are synthesized relative to this point.
        private var longPressStartLocation: CGPoint?

        init(
            onPanChanged: @escaping (CGPoint, CGPoint) -> Void,
            onPanEnded: @escaping (CGPoint, CGPoint, CGPoint) -> Void,
            onTap: ((CGPoint) -> Void)?,
            shouldBeginPan: ((CGPoint) -> Bool)?,
            shouldBeginLongPress: ((CGPoint) -> Bool)?
        ) {
            self.onPanChanged = onPanChanged
            self.onPanEnded = onPanEnded
            self.onTap = onTap
            self.shouldBeginPan = shouldBeginPan
            self.shouldBeginLongPress = shouldBeginLongPress
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            let location = gesture.location(in: gesture.view)

            let velocity = gesture.velocity(in: gesture.view)

            switch gesture.state {
            case .changed:
                onPanChanged(translation, location)
            case .ended, .cancelled:
                onPanEnded(translation, location, velocity)
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let location = gesture.location(in: gesture.view)
            onTap?(location)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                longPressStartLocation = location
                TimeSliderHaptics.impact(.medium)
                onPanChanged(.zero, location)
            case .changed:
                guard let start = longPressStartLocation else { return }
                onPanChanged(CGPoint(x: location.x - start.x, y: location.y - start.y), location)
            case .ended, .cancelled, .failed:
                guard let start = longPressStartLocation else { return }
                longPressStartLocation = nil
                // Zero velocity — a deliberate hold-and-place must never read as a
                // quick flick (which would navigate to an adjacent day).
                onPanEnded(CGPoint(x: location.x - start.x, y: location.y - start.y), location, .zero)
            default:
                break
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UILongPressGestureRecognizer {
                let location = gestureRecognizer.location(in: gestureRecognizer.view)
                return shouldBeginLongPress?(location) ?? false
            }

            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }

            // The host decides where a needle drag may start (NutriKit #2280) — refused pans
            // fall through to the surrounding swipe/scroll gestures.
            if let shouldBeginPan, !shouldBeginPan(pan.location(in: pan.view)) {
                timeSliderGestureLogger.debug("[UIKit] pan refused by host hit test")
                return false
            }

            let velocity = pan.velocity(in: pan.view)
            // Use 1.5x threshold - horizontal must be 1.5x vertical to be considered horizontal
            let isHorizontal = abs(velocity.x) > abs(velocity.y) * 1.5

            timeSliderGestureLogger.debug("[UIKit] velocity x=\(velocity.x, privacy: .public), y=\(velocity.y, privacy: .public), isHorizontal=\(isHorizontal, privacy: .public)")

            // Only begin if the gesture is clearly horizontal
            // This allows vertical scrolls to pass through to parent scroll view
            return isHorizontal
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Don't recognize simultaneously with scroll views - we want exclusivity
            return false
        }
    }
}

/// Custom container view that properly forwards intrinsic content size
private final class HorizontalPanContainerView: UIView {
    override var intrinsicContentSize: CGSize {
        // Forward the intrinsic content size from the hosted view
        if let hostedView = subviews.first {
            return hostedView.intrinsicContentSize
        }
        return super.intrinsicContentSize
    }
}

// MARK: - Horizontal pan (interactive mode)

/// UIKit-backed horizontal pan for the interactive TimeSlider (NutriKit's Edit Meal, meal
/// form wizard, copy/move pickers; Overload's workout time). A SwiftUI `DragGesture` claims
/// every touch on the timeline — vertical swipes included — which blocks the containing
/// sheet's interactive swipe-to-dismiss (NutriKit #2025). Like live mode's
/// `HorizontalPanGestureView`, this recognizer refuses to begin unless the pan
/// velocity is clearly horizontal, so vertical swipes fall through to the
/// sheet's dismiss gesture.
struct InteractiveHorizontalPanGesture: UIGestureRecognizerRepresentable {
    /// Pan updates with the touch location in the attached view's local space
    let onChanged: (CGPoint) -> Void
    /// Pan ended or was cancelled
    let onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(context.converter.localLocation)
        // `.failed` is an end too (NutriKit #2575) — a pan that dies rather than finishes still
        // has to hand back the drag state it took, or the next gesture inherits it.
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            // Same 1.5x threshold as HorizontalPanGestureView — only clearly
            // horizontal movements begin; vertical ones reach the sheet.
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
