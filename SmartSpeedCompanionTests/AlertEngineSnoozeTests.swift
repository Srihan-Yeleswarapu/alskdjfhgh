import XCTest
@testable import SmartSpeedCompanion

/// Regression coverage for TestFlight 2.3.0 b640 ("The 'I Know (15s)' button
/// needs fixing. I click it and it's not doing anything. It's hiding the
/// prompt but shows it back within 3 seconds."). The CarPlay banner
/// (`CarPlayNavigationRootTemplate.handleAlerts`) re-presented the overspeed
/// alert on every ~1 Hz speed tick because it never checked
/// `alertEngine.isSnoozed` — only the snooze *button* did. The banner now
/// gates presentation on this exact contract; these tests pin the snooze
/// window semantics it relies on.
@MainActor
final class AlertEngineSnoozeTests: XCTestCase {

    /// While snoozed, `isSnoozed` is true for the full window and flips back
    /// to false when it expires — the flag `handleAlerts` checks each tick.
    func testSnoozeWindowSuppressesThenExpires() throws {
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(0.3)
        XCTAssertTrue(engine.isSnoozed, "snooze must be active immediately after 'I Know (15s)'")
        XCTAssertGreaterThan(engine.snoozeRemainingSeconds, 0)

        // Advance past the window.
        let expired = expectation(description: "snooze expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { expired.fulfill() }
        wait(for: [expired], timeout: 3)

        XCTAssertFalse(engine.isSnoozed, "alerts must resume once the window passes")
        XCTAssertEqual(engine.snoozeRemainingSeconds, 0)
    }

    /// Tapping "I Know (15s)" again while already snoozed restarts the window
    /// from *now* (not from the previous end), so repeated taps never leave a
    /// shorter effective silence than a fresh 15 s.
    func testSnoozeWhileSnoozedExtendsFromNow() {
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(0.3)
        engine.snoozeFor(15)
        XCTAssertGreaterThanOrEqual(engine.snoozeRemainingSeconds, 14,
                                    "second tap must extend the window from now")
    }

    /// Cancel ends the suppression immediately.
    func testCancelSnoozeAllowsImmediateAlerting() {
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(15)
        XCTAssertTrue(engine.isSnoozed)
        engine.cancelSnooze()
        XCTAssertFalse(engine.isSnoozed)
        XCTAssertEqual(engine.snoozeRemainingSeconds, 0)
    }

    // MARK: - Snooze survives monitoring teardown
    //
    // Root cause of the repeat reports after the b640 fix:
    // `stopMonitoringState()` called `cancelSnooze()`, and it runs on every
    // transient status wobble — most importantly SpeedEngine's limit-refresh
    // cycle, which resets `limit = 0` / `status = .safe` while it looks up
    // the next value (every ~80 m surface / ~250 m highway). That erased the
    // driver's "I Know" acknowledgement seconds after every tap, so the
    // banner and beeps returned while still speeding.

    /// The snooze must outlive monitoring teardown; only time expiry, the
    /// stopped-car auto-expire monitor, or an explicit `cancelSnooze()` may
    /// end it.
    func testSnoozeSurvivesMonitoringTeardown() throws {
        let source = try String(contentsOfFile: alertEngineSourcePath(), encoding: .utf8)
        let body = try sourceSection(in: source, anchor: "private func stopMonitoringState()")
        XCTAssertFalse(
            body.contains("cancelSnooze()"),
            "stopMonitoringState runs on every transient status/limit wobble; cancelling the snooze there erases the 'I Know' acknowledgement mid-window."
        )
    }

    /// Tapping "I Know" must release the alert audio lease (media resumes)
    /// and a snoozed episode must not re-acquire focus or restart the
    /// vibration pulse while the window is active.
    func testSnoozeReleasesAudioFocusAndSuppressesPulseRestart() throws {
        let source = try String(contentsOfFile: alertEngineSourcePath(), encoding: .utf8)
        let snoozeBody = try sourceSection(in: source, anchor: "public func snoozeFor(")
        XCTAssertTrue(
            snoozeBody.contains("endAlertAudioFocus()"),
            "snoozeFor must release the alert audio lease so interrupted media resumes during the window."
        )
        let startBody = try sourceSection(in: source, anchor: "private func startMonitoring()")
        XCTAssertTrue(
            startBody.contains("!isSnoozed"),
            "startMonitoring must not re-acquire audio focus or restart the haptic pulse while snoozed."
        )
    }

    // MARK: - Helpers

    private func sourceSection(in source: String, anchor: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else {
            XCTFail("Missing expected source anchor: \(anchor)")
            return ""
        }
        let body = source[anchorRange.lowerBound...]
        guard let endRange = body.range(of: "\n    }") else {
            XCTFail("Could not locate the end of the section for anchor: \(anchor)")
            return ""
        }
        return String(body[..<endRange.lowerBound])
    }

    private func alertEngineSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\AlertEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/AlertEngine.swift"
        #endif
    }
}
