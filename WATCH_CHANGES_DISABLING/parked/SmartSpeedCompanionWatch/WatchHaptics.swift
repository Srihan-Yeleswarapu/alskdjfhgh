// Path: SmartSpeedCompanionWatch/WatchHaptics.swift
//
// Native wrist haptics for overspeed alerts.
//
// WHY THIS EXISTS (the mirror of Core/BackgroundHapticBridge.swift)
// ─────────────────────────────────────────────────────────────────
// The phone app's BackgroundHapticBridge documents the core iOS
// limitation: third-party apps may NOT drive the taptic engine while
// backgrounded, so the phone fakes a buzz via a silent local
// notification. watchOS has no such restriction for an actively
// running watch session: `WKInterfaceDevice.play(_:)` delivers a real
// haptic pulse while the driver's wrist is down, phone locked, or
// CarPlay is driving the screen — the single strongest reason Speedio
// exists on the wrist.
//
// CADENCE
// ───────
// Mirrors BackgroundHapticBridge's 15 s throttle: one pulse at the
// over-limit transition, then a re-pulse every 15 s while still over,
// reset immediately when back inside the limit. The cadence lives in
// `shouldPulse(now:status:)` so unit tests can drive it with an
// injected clock instead of sleeping.

import WatchKit
import Foundation

/// Fires overspeed haptic pulses on the wrist with BackgroundHapticBridge's
/// 15 s cadence. All plays are on-device WKInterfaceDevice pulses — no
/// notification hacks, no audio session.
public final class WatchHaptics {

    public static let shared = WatchHaptics()

    /// Minimum gap between two overspeed pulses while still over the limit.
    /// Same value as `BackgroundHapticBridge.alertInterval` so both surfaces
    /// feel identical to the user.
    public static let repeatInterval: TimeInterval = 15.0

    /// Last overspeed pulse time, used by `shouldPulse` for throttling.
    /// `var` (not private) so tests can seed/reseed it directly.
    var lastOverPulseAt: Date = .distantPast

    /// Internal (not singleton-private) so `WatchLogicTests` can create
    /// isolated instances and drive the cadence with injected clocks.
    init() {}

    // MARK: - Cadence decision (testable)

    /// Whether an overspeed pulse is due at `now`. Pure decision logic so
    /// `WatchHapticThrottleTests` can drive transitions without a device:
    ///   • status `.over`  → pulse if the 15 s gap has elapsed
    ///   • status anything else → reset the throttle so the NEXT over
    ///     transition pulses immediately (mirrors `BackgroundHapticBridge.reset()`).
    public func shouldPulse(now: Date, status: SpeedStatus) -> Bool {
        guard status == .over else {
            lastOverPulseAt = .distantPast
            return false
        }
        guard now.timeIntervalSince(lastOverPulseAt) >= Self.repeatInterval else {
            return false
        }
        lastOverPulseAt = now
        return true
    }

    // MARK: - Delivery

    /// Evaluates the current status and plays a `.notification` double-pulse
    /// when a re-pulse is due. Called by `WatchDriveViewModel` on every
    /// 1 s monitor tick; safe to call at any frequency (it self-throttles).
    /// - Parameter hapticsEnabled: the user's watch haptics master switch.
    public func tick(status: SpeedStatus, hapticsEnabled: Bool) {
        guard hapticsEnabled else { return }
        guard shouldPulse(now: Date(), status: status) else { return }
        play(.notification)
    }

    /// Plays a haptic immediately. Used for session start (`.start`), a
    /// manual alert test from Settings (`.directionUp`), and overspeed
    /// pulses (`.notification`).
    public func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    /// Resets the throttle so the next overspeed entry pulses immediately.
    /// Called when a session starts or ends.
    public func reset() {
        lastOverPulseAt = .distantPast
    }
}
