// Path: SmartSpeedCompanionWatchTests/WatchLogicTests.swift
//
// Unit tests for the watch-side pure logic (runs on the watchOS simulator
// via `xcodebuild test -scheme SmartSpeedCompanionWatch`):
//   • WatchLink payload round-trips (phone↔watch schema contract)
//   • WatchHaptics 15 s overspeed cadence (BackgroundHapticBridge parity)
//   • SpeedFormatting unit conversions the watch HUD renders

import XCTest
@testable import SmartSpeedCompanionWatch

final class WatchLogicTests: XCTestCase {

    // MARK: - WatchPhoneState round-trips

    func testWatchPhoneStateRoundTrip() throws {
        let state = WatchPhoneState(
            speed: 62.4,
            limitMph: 55,
            status: SpeedStatus.over.rawValue,
            isRecording: true,
            isNavigating: true,
            measurementSystem: "Imperial",
            nextManeuver: "Turn right onto Main Street",
            distanceToNextTurnMeters: 412.5,
            eta: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let dict = state.encodedDictionary()
        let decoded = try XCTUnwrap(WatchPhoneState.from(dictionary: dict))

        XCTAssertEqual(decoded.speed, state.speed, accuracy: 0.001)
        XCTAssertEqual(decoded.limitMph, state.limitMph)
        XCTAssertEqual(decoded.status, state.status)
        XCTAssertEqual(decoded.isRecording, state.isRecording)
        XCTAssertEqual(decoded.isNavigating, state.isNavigating)
        XCTAssertEqual(decoded.measurementSystem, state.measurementSystem)
        XCTAssertEqual(decoded.nextManeuver, state.nextManeuver)
        XCTAssertEqual(decoded.distanceToNextTurnMeters ?? -1, state.distanceToNextTurnMeters ?? -1, accuracy: 0.001)
        XCTAssertEqual(decoded.eta, state.eta)
    }

    func testWatchPhoneStateFromEmptyDictionaryReturnsNil() {
        XCTAssertNil(WatchPhoneState.from(dictionary: [:]))
        XCTAssertNil(WatchPhoneState.from(dictionary: ["garbage": 42]))
    }

    /// The unit contract: `speed` is display-unit, `limitMph` is canonical
    /// MPH. A metric payload must survive the round-trip with its mixed
    /// units intact (watch renders `speed` as-is and converts the limit).
    func testMetricPayloadUnitsPreserved() throws {
        let state = WatchPhoneState(
            speed: 100.5,        // km/h (display)
            limitMph: 65,        // canonical MPH
            status: "warning",
            isRecording: true,
            isNavigating: false,
            measurementSystem: "Metric"
        )
        let decoded = try XCTUnwrap(WatchPhoneState.from(dictionary: state.encodedDictionary()))
        XCTAssertEqual(decoded.measurementSystem, "Metric")
        XCTAssertEqual(decoded.limitMph, 65) // still canonical MPH
        XCTAssertEqual(decoded.speed, 100.5, accuracy: 0.001) // still display km/h
    }

    // MARK: - WatchCommand round-trips

    func testWatchCommandRoundTrip() {
        for command in [WatchCommand.startSession, .endSession, .snoozeAlert, .requestState, .applySettings] {
            let dict = command.encodedDictionary()
            XCTAssertEqual(WatchCommand.from(dictionary: dict), command)
        }
    }

    func testWatchCommandUnknownRawValueReturnsNil() {
        XCTAssertNil(WatchCommand.from(dictionary: ["watchCommand": "launchMissiles"]))
    }

    // MARK: - WatchSettingsSync round-trips

    func testSettingsSyncRoundTrip() throws {
        let settings = WatchSettingsSync(measurementSystem: "Metric", userBufferMPH: 7, watchHapticsEnabled: false)
        let decoded = try XCTUnwrap(WatchSettingsSync.from(dictionary: settings.encodedDictionary()))
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - WatchHaptics cadence

    /// One pulse at the over transition, then silence inside the 15 s window.
    func testOverspeedPulseThrottle() {
        let haptics = WatchHaptics()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // First over tick: pulses immediately.
        XCTAssertTrue(haptics.shouldPulse(now: t0, status: .over))

        // 14.9 s later, still over: throttled.
        XCTAssertFalse(haptics.shouldPulse(now: t0.addingTimeInterval(14.9), status: .over))

        // 15 s after the pulse: re-pulse fires.
        XCTAssertTrue(haptics.shouldPulse(now: t0.addingTimeInterval(15.0), status: .over))
    }

    /// Dropping back inside the limit resets the throttle so the NEXT
    /// over-transition pulses immediately (BackgroundHapticBridge.reset
    /// parity — a fresh speeding episode must never be swallowed).
    func testReturnToSafeResetsThrottle() {
        let haptics = WatchHaptics()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(haptics.shouldPulse(now: t0, status: .over))
        // Back inside the limit (resets internally).
        XCTAssertFalse(haptics.shouldPulse(now: t0.addingTimeInterval(1), status: .safe))
        // A brand-new overspeed episode 2 s later pulses immediately.
        XCTAssertTrue(haptics.shouldPulse(now: t0.addingTimeInterval(2), status: .over))
    }

    /// Warning/safe ticks never fire the overspeed pulse.
    func testNonOverStatusNeverPulses() {
        let haptics = WatchHaptics()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(haptics.shouldPulse(now: t0, status: .safe))
        XCTAssertFalse(haptics.shouldPulse(now: t0, status: .warning))
    }

    /// The watch cadence constant must match the phone's
    /// BackgroundHapticBridge alert interval so both surfaces feel identical.
    func testCadenceMatchesPhoneBridge() {
        // BackgroundHapticBridge.alertInterval is private; 15.0 is its
        // documented value (see the header of Core/BackgroundHapticBridge).
        XCTAssertEqual(WatchHaptics.repeatInterval, 15.0)
    }
}
