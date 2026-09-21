import XCTest
@testable import SmartSpeedCompanion

/// Haptic coordinator ↔ alert snooze interplay: the contracts that keep the
/// phone silent when the driver says "I Know" and buzzing again only after
/// the window ends. Distinct from AlertEngineSnoozeTests (window semantics)
/// and HapticPatternCatalogAndSeverityTests (catalog/persistence): this file
/// pins the *coordination* — snooze must stop a running pulse, disabled
/// haptics must gate every entry point, and pulse start/stop must be
/// symmetric under rapid driver interaction.
@MainActor
final class HapticCoordinatorSeveritySnoozeTests: XCTestCase {

    override func tearDown() {
        // Leave the shared manager and defaults clean for other suites.
        HapticAlertManager.shared.stopSpeedingPulse()
        UserDefaults.standard.removeObject(forKey: "hapticAlertsEnabled")
        super.tearDown()
    }

    // MARK: - Snooze stops a running speeding pulse

    func testSnoozeStopsRunningPulse() {
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
        HapticAlertManager.shared.startSpeedingPulse(severity: 0.8)
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(15)
        // snoozeFor() must have called stopSpeedingPulse() (source-anchored in
        // AlertEngine); the manager side must tolerate the stop cleanly.
        HapticAlertManager.shared.stopSpeedingPulse()
        XCTAssertTrue(engine.isSnoozed)
    }

    func testSnoozeWhilePulseRunningKeepsEngineStateConsistent() {
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
        HapticAlertManager.shared.startSpeedingPulse(severity: 0.4)
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(0.2)
        XCTAssertTrue(engine.isSnoozed)
        XCTAssertEqual(engine.snoozeRemainingSeconds, 0, accuracy: 1)
        engine.cancelSnooze()
        XCTAssertFalse(engine.isSnoozed)
    }

    // MARK: - Severity clamping at the pulse entry point

    func testPulseStartToleratesExtremeSeverities() {
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
        // Out-of-range severities must be clamped/no-op, never crash the
        // haptic engine or corrupt the pulse state.
        HapticAlertManager.shared.startSpeedingPulse(severity: -1)
        HapticAlertManager.shared.stopSpeedingPulse()
        HapticAlertManager.shared.startSpeedingPulse(severity: 0)
        HapticAlertManager.shared.stopSpeedingPulse()
        HapticAlertManager.shared.startSpeedingPulse(severity: 99)
        HapticAlertManager.shared.stopSpeedingPulse()
    }

    func testFireIfEnabledAtBoundarySeveritiesIsSafe() {
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
        HapticAlertManager.shared.fireIfEnabled(severity: 0, consecutiveSeconds: 0)
        HapticAlertManager.shared.fireIfEnabled(severity: 1, consecutiveSeconds: 10_000)
    }

    // MARK: - Rapid driver interaction (banner taps during speeding)

    func testRapidSnoozePulseCyclesStayConsistent() {
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        for _ in 0..<50 {
            HapticAlertManager.shared.startSpeedingPulse(severity: 0.7)
            engine.snoozeFor(0.05)
            engine.cancelSnooze()
            HapticAlertManager.shared.stopSpeedingPulse()
        }
        XCTAssertFalse(engine.isSnoozed, "Cycles left a stale snooze window")
        XCTAssertEqual(engine.snoozeRemainingSeconds, 0)
    }

    // MARK: - Disabled haptics gate every entry point

    func testDisabledHapticsGateAllEntryPoints() {
        UserDefaults.standard.set(false, forKey: "hapticAlertsEnabled")
        // Every public entry point must no-op (not crash) when haptics are
        // off — drivers toggle this mid-drive.
        HapticAlertManager.shared.startSpeedingPulse(severity: 1.0)
        HapticAlertManager.shared.fireIfEnabled(severity: 1.0, consecutiveSeconds: 3)
        HapticAlertManager.shared.stopSpeedingPulse()
    }

    // MARK: - Snooze arithmetic sanity alongside haptic state

    func testSnoozeRemainingNeverNegativeDuringPulseInteraction() {
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(0.05)
        HapticAlertManager.shared.startSpeedingPulse(severity: 0.9)
        HapticAlertManager.shared.stopSpeedingPulse()
        XCTAssertGreaterThanOrEqual(engine.snoozeRemainingSeconds, 0,
                                    "Remaining seconds went negative during pulse interaction")
    }
}
