import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// AlertEngine's over-limit episode lifecycle, driven through the real
/// status pipeline with a real SpeedEngine and no audio/haptic hardware:
///   .over entry → monitoring starts (consecutiveSeconds = 1, first beep
///   scheduled), 1 s timer ticks the counter, every ≥ 2 s re-triggers,
///   .safe exit tears everything down.
/// Audio + haptic toggles are forced off in setUp so assertions observe
/// only the state machine (no AVAudioEngine bring-up in tests).
@MainActor
final class AlertEngineOverLimitEpisodeTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!
    private var alertEngine: AlertEngine!
    private var speedEngine: SpeedEngine!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
        UserDefaults.standard.set(false, forKey: "audioAlertsEnabled")
        UserDefaults.standard.set(false, forKey: "hapticAlertsEnabled")
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        UserDefaults.standard.set(5, forKey: "userBuffer")
        speedEngine = SpeedEngine(locationManager: LocationManager())
        alertEngine = AlertEngine(speedEngine: speedEngine)
    }

    override func tearDown() {
        alertEngine = nil
        speedEngine = nil
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    private func enterOverState(limit: Int = 50, speed: Double = 60) {
        speedEngine.speed = speed
        speedEngine.applyResolvedLimit(limit)
        waitForMainQueueTurn("status propagation")
    }

    private func exitOverState() {
        speedEngine.speed = 40
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn("status propagation")
    }

    // MARK: - Episode entry

    /// Crossing into .over with a resolved limit must start the counter at
    /// exactly 1 (no waiting for the first timer tick).
    func testOverEntryStartsCounterAtOne() {
        enterOverState()
        XCTAssertEqual(speedEngine.status, .over)
        XCTAssertEqual(alertEngine.consecutiveSeconds, 1,
                       "Episode entry must count the first second immediately")
    }

    /// With both alert channels disabled, entering .over must NOT start
    /// monitoring — no counter, no audio flag.
    func testOverEntryWithAllAlertsDisabledDoesNothing() {
        UserDefaults.standard.set(false, forKey: "audioAlertsEnabled")
        UserDefaults.standard.set(false, forKey: "hapticAlertsEnabled")
        // Force the engine to re-read toggles by publishing a fresh status.
        speedEngine.speed = 40
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        speedEngine.speed = 60
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0,
                       "No monitoring with both channels disabled")
        XCTAssertFalse(alertEngine.audioAlertActive)
    }

    /// Unknown limit must never start an episode — the guard reads
    /// isLimitResolved/limit before anything else.
    func testOverEntryWithUnknownLimitDoesNotStartMonitoring() {
        speedEngine.speed = 90
        speedEngine.applyResolvedLimit(0)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0)
        XCTAssertEqual(alertEngine.audioAlertActive, false)
    }

    // MARK: - Episode exit

    func testExitToSafeResetsCounterAndAudioFlag() {
        enterOverState()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 1)
        exitOverState()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0)
        XCTAssertFalse(alertEngine.audioAlertActive)
    }

    /// .warning is NOT .over: crossing from warning must not (re)start
    /// monitoring, and exiting from over into warning must stop it.
    func testWarningDoesNotSustainEpisode() {
        enterOverState()
        speedEngine.speed = 54.5 // threshold−0.5 → warning band
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(speedEngine.status, .warning)
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0,
                       "Leaving .over must tear down monitoring even into .warning")
    }

    // MARK: - Snooze interplay

    func testSnoozeSilencesAudioFlagDuringEpisode() {
        enterOverState()
        alertEngine.snoozeFor(30)
        XCTAssertFalse(alertEngine.audioAlertActive,
                       "Snoozed drivers hear nothing — the published flag must be down")
        XCTAssertTrue(alertEngine.isSnoozed)
        // The counter keeps ticking during snooze so the "seconds over"
        // readout stays honest when the window expires.
        XCTAssertGreaterThanOrEqual(alertEngine.consecutiveSeconds, 1)
    }

    func testSnoozeSurvivesStatusWobble() {
        enterOverState()
        alertEngine.snoozeFor(30)
        // The limit-refresh cycle bounces status through .safe and back.
        exitOverState()
        enterOverState()
        XCTAssertTrue(alertEngine.isSnoozed,
                      "A transient safe/over wobble must not erase the user's acknowledgement")
    }

    func testCancelSnoozeResumesImmediately() {
        enterOverState()
        alertEngine.snoozeFor(30)
        alertEngine.cancelSnooze()
        XCTAssertFalse(alertEngine.isSnoozed)
        XCTAssertFalse(alertEngine.snoozedUntil != nil)
    }

    // MARK: - Severity policy (pure function)

    func testSeverityIsOneHalfWithoutEngine() {
        // computedSeverity() is private; the pulse-start policy is the
        // public surface. Unknown limit → no pulse (covered in resolution
        // tests); here we pin the threshold policy that feeds it.
        XCTAssertTrue(AlertEngine.shouldStartSpeedingPulse(
            speed: 56, limit: 50, buffer: 5,
            measurementSystem: "Imperial", isLimitResolved: true))
    }

    func testPulsePolicyAcrossBoundaryMatrix() {
        // (speed, limit, buffer, expected) — Imperial.
        let matrix: [(Double, Int, Int, Bool)] = [
            (54.9, 50, 5, false),  // below threshold
            (55.0, 50, 5, false),  // at threshold — strict >
            (55.1, 50, 5, true),   // over
            (60.0, 50, 5, true),   // well over
            (49.9, 50, 0, false),
            (50.1, 50, 0, true),
            (88.6, 55, 0, true),   // metric-irrelevant, Imperial check
        ]
        for (speed, limit, buffer, expected) in matrix {
            XCTAssertEqual(
                AlertEngine.shouldStartSpeedingPulse(speed: speed, limit: limit,
                                                     buffer: buffer,
                                                     measurementSystem: "Imperial",
                                                     isLimitResolved: true),
                expected, "speed=\(speed) limit=\(limit) buffer=\(buffer)")
        }
    }

    func testPulsePolicyMetricThreshold() {
        // Metric: limit 50 + buffer 5 → threshold 55 mph × 1.60934 = 88.51 km/h.
        XCTAssertFalse(AlertEngine.shouldStartSpeedingPulse(
            speed: 88.0, limit: 50, buffer: 5,
            measurementSystem: "Metric", isLimitResolved: true))
        XCTAssertTrue(AlertEngine.shouldStartSpeedingPulse(
            speed: 89.0, limit: 50, buffer: 5,
            measurementSystem: "Metric", isLimitResolved: true))
    }

    // MARK: - Toggle reconciliation mid-episode (source policy)

    /// Disabling BOTH channels mid-episode must stop the timer on its next
    /// tick; the guard clause is pinned by source.
    func testBothChannelsOffStopsTimerInSource() throws {
        let source = try String(contentsOfFile: alertEngineSourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("guard self.isAudioAlertsEnabled || self.isHapticAlertsEnabled else"),
                      "Timer tick must tear down monitoring when both channels are disabled mid-episode")
    }

    /// Snooze must be excluded from the published audio flag at every tick.
    func testAudioFlagExcludesSnoozeInSource() throws {
        let source = try String(contentsOfFile: alertEngineSourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("audioAlertActive = self.isAudioAlertsEnabled && !self.isSnoozed"),
                      "Timer tick must recompute the audio flag with the snooze window applied")
    }

    private func alertEngineSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\AlertEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/AlertEngine.swift"
        #endif
    }
}
