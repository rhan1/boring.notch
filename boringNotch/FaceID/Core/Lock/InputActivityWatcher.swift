// From FaceMac by c1osed1 — https://github.com/c1osed1/FaceMac (GPL-3.0).
// Adapted for Boring Notch.

import CoreGraphics
import Foundation

/// Polls the system-wide input idle time while the screen is locked and reports
/// fresh activity — a key press, trackpad touch or mouse move. This lets the
/// user start a scan by tapping the space bar instead of the scan button,
/// without keeping the camera on while nobody is there.
public final class InputActivityWatcher {
    /// Called on the main queue when new input is seen, with how long the
    /// system had been idle just before it.
    public var onActivity: ((_ idleBefore: TimeInterval) -> Void)?

    private var timer: Timer?
    private var lastIdle: TimeInterval = .greatestFiniteMagnitude
    private let interval: TimeInterval = 0.2

    public init() {}

    public var isRunning: Bool { timer != nil }

    public func start() {
        guard timer == nil else { return }
        lastIdle = Self.secondsSinceLastInput()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Seconds since the last real (hardware) input event of any kind.
    public static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType is ~0 in C; Swift exposes it only as a raw value.
        guard let any = CGEventType(rawValue: ~0) else { return .greatestFiniteMagnitude }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    private func tick() {
        let idle = Self.secondsSinceLastInput()
        // Idle time only ever grows between events, so a drop means new input.
        if idle + 0.05 < lastIdle {
            onActivity?(lastIdle)
        }
        lastIdle = idle
    }
}
