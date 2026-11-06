import UIKit

/// Drives a custom chart's own animations (#2682, extracted from #2673's weight chart).
///
/// `withAnimation` can't reach inside a `Canvas` — its drawing isn't an animatable value —
/// so momentum, spring-back, preset glides, the value axis and the readout's cross-fade all
/// ease here instead, on one display link that runs only while something is actually moving.
@MainActor
public final class ChartTicker {
    public var onTick: ((CFTimeInterval) -> Void)?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    public var isRunning: Bool { link != nil }

    public func start() {
        guard link == nil else { return }
        let proxy = Proxy { [weak self] timestamp, duration in
            guard let self else { return }
            // After a stall or a trip through the background an unclamped delta would
            // teleport the window across the whole domain in a single frame.
            let delta = self.lastTimestamp == 0 ? duration : min(timestamp - self.lastTimestamp, 1.0 / 20)
            self.lastTimestamp = timestamp
            self.onTick?(max(delta, 0))
        }
        let displayLink = CADisplayLink(target: proxy, selector: #selector(Proxy.step(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        proxy.link = displayLink
        link = displayLink
    }

    public func stop() {
        lastTimestamp = 0
        link?.invalidate()
        link = nil
    }

    deinit {
        link?.invalidate()
    }

    /// `CADisplayLink` retains its target, so the model can't be it — this stands in and
    /// holds the model weakly. Without it the link keeps firing at 120Hz for the life of
    /// the process after the chart has gone.
    private final class Proxy: NSObject {
        let handler: (CFTimeInterval, CFTimeInterval) -> Void
        weak var link: CADisplayLink?

        init(handler: @escaping (CFTimeInterval, CFTimeInterval) -> Void) {
            self.handler = handler
        }

        @objc func step(_ link: CADisplayLink) {
            handler(link.timestamp, link.duration)
        }
    }
}
