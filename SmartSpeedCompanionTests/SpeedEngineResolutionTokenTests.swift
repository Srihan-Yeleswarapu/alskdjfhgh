import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// SpeedEngine guards against a classicHERE race: two lookups in flight, the
/// slower (older) response arriving last and overwriting the limit for the
/// road the user is already on. The defense is a generation token —
/// `beginLimitResolution()` invalidates everything older, and
/// `applyResolvedLimit(_:resolutionToken:)` drops stale completions.
///
/// A stale limit is not cosmetic: with speed 70 and a stale 30-mph limit
/// applied, AlertEngine beeps on a road the user may legally be doing 70 on.
/// These tests replay the race with real engine state (no stubs), using
/// fixes whose horizontalAccuracy ≥ 100 m so the GPS-driven resolution path
/// stays out of the picture and the suite remains hermetic.
@MainActor
final class SpeedEngineResolutionTokenTests: XCTestCase {

    private var guard_: UserDefaultsTestGuard!
    private var hereGate: HERECredentialsGate!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate()
        hereGate.close()
        guard_ = UserDefaultsTestGuard()
        guard_.snapshotNow()
        guard_.resetToFreshInstall()
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
    }

    override func tearDown() {
        guard_.restore()
        hereGate.reopen()
        super.tearDown()
    }

    private func makeEngine() -> SpeedEngine {
        SpeedEngine(locationManager: LocationManager())
    }

    /// Accuracy 150 m: accepted for speed display, but ineligible for the
    /// coordinate-driven resolution path (keeps the test hermetic).
    private func displayOnlyFix(speedMph: Double, timestamp: Date = Date()) -> CLLocation {
        GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                          speedMph: speedMph, accuracy: 150, timestamp: timestamp)
    }

    // MARK: - begin: neutralize the HUD

    func testBeginLimitResolutionClearsDisplayedLimitAndFlags() {
        let engine = makeEngine()
        engine.applyResolvedLimit(65) // established limit (manual, no token)
        XCTAssertEqual(engine.limit, 65)
        XCTAssertTrue(engine.isLimitResolved)

        let token = engine.beginLimitResolution()
        XCTAssertGreaterThan(token, 0)
        XCTAssertEqual(engine.limit, 0, "begin must clear the displayed limit immediately")
        XCTAssertFalse(engine.isLimitResolved, "begin must unresolve the HUD")
        XCTAssertEqual(engine.status, .safe, "no red/green state while unresolved")
    }

    func testTokensIncreaseAcrossSequentialBegins() {
        let engine = makeEngine()
        let t1 = engine.beginLimitResolution()
        let t2 = engine.beginLimitResolution()
        XCTAssertGreaterThan(t2, t1, "each begin must produce a strictly newer token")
    }

    // MARK: - apply: fresh vs stale

    func testApplyWithCurrentTokenPublishesLimitAndResolution() {
        let engine = makeEngine()
        engine.processLocationForTesting(displayOnlyFix(speedMph: 40)) // speed = 40
        let token = engine.beginLimitResolution()

        engine.applyResolvedLimit(45, resolutionToken: token)
        XCTAssertEqual(engine.limit, 45)
        XCTAssertTrue(engine.isLimitResolved)
        XCTAssertEqual(engine.status, .safe)
    }

    func testApplyWithStaleTokenIsDiscardedCompletely() {
        let engine = makeEngine()
        let staleToken = engine.beginLimitResolution()
        _ = engine.beginLimitResolution() // newer lookup started; staleToken now dead

        engine.applyResolvedLimit(30, resolutionToken: staleToken)
        XCTAssertEqual(engine.limit, 0, "stale response must not publish a limit")
        XCTAssertFalse(engine.isLimitResolved, "stale response must not re-resolve the HUD")
        XCTAssertEqual(engine.status, .safe, "stale response must not drive alert state")
    }

    func testStaleApplyCannotCreatePhantomOverspeed() {
        // The money scenario: driver at 70 on a 70 road; an old lookup for a
        // 30-mph street arrives after a newer begin. If it published, the
        // user would get an over-limit alert while legal.
        let engine = makeEngine()
        engine.processLocationForTesting(displayOnlyFix(speedMph: 70))
        let stale = engine.beginLimitResolution()
        _ = engine.beginLimitResolution()

        engine.applyResolvedLimit(30, resolutionToken: stale)
        XCTAssertEqual(engine.status, .safe, "phantom overspeed from a stale limit")
        XCTAssertEqual(engine.limit, 0)
    }

    func testApplyWithoutTokenIsAlwaysAcceptedAsManualPath() {
        let engine = makeEngine()
        engine.processLocationForTesting(displayOnlyFix(speedMph: 50))
        _ = engine.beginLimitResolution()

        // DriveViewModel's manual refresh passes no token: current generation
        // is whatever it is, and the caller says "this answer is fresh".
        engine.applyResolvedLimit(55)
        XCTAssertEqual(engine.limit, 55)
        XCTAssertTrue(engine.isLimitResolved)
    }

    func testZeroLimitResolutionMarksUnresolvedRatherThanLimitZero() {
        let engine = makeEngine()
        engine.applyResolvedLimit(65)
        XCTAssertTrue(engine.isLimitResolved)

        engine.applyResolvedLimit(0)
        XCTAssertEqual(engine.limit, 0)
        XCTAssertFalse(engine.isLimitResolved, "a zero limit means 'no data', not 'unlimited'")
        XCTAssertEqual(engine.status, .safe)
    }

    func testReapplyWithSameTokenStillWorksUntilSuperseded() {
        // Tokens are generation checks, not one-time passwords: the same
        // lookup completing twice (retry path) must still apply.
        let engine = makeEngine()
        let token = engine.beginLimitResolution()
        engine.applyResolvedLimit(45, resolutionToken: token)
        engine.applyResolvedLimit(50, resolutionToken: token)
        XCTAssertEqual(engine.limit, 50)
        XCTAssertTrue(engine.isLimitResolved)
    }

    func testSupersededTokenCannotOverwriteFreshAnswer() {
        let engine = makeEngine()
        let t1 = engine.beginLimitResolution()
        engine.applyResolvedLimit(45, resolutionToken: t1)
        let t2 = engine.beginLimitResolution()
        engine.applyResolvedLimit(65, resolutionToken: t2)

        engine.applyResolvedLimit(45, resolutionToken: t1) // old response finally lands
        XCTAssertEqual(engine.limit, 65, "older generation must never overwrite a newer answer")
    }

    // MARK: - resetForNewDrive boundary

    func testResetForNewDriveInvalidatesOutstandingTokens() {
        let engine = makeEngine()
        let token = engine.beginLimitResolution()
        engine.resetForNewDrive()

        engine.applyResolvedLimit(65, resolutionToken: token)
        XCTAssertEqual(engine.limit, 0, "a token from before the reset is a stale response")
        XCTAssertFalse(engine.isLimitResolved)
    }

    func testResetForNewDriveClearsDisplayedState() {
        let engine = makeEngine()
        engine.processLocationForTesting(displayOnlyFix(speedMph: 55))
        engine.applyResolvedLimit(65)
        XCTAssertGreaterThan(engine.speed, 0)
        XCTAssertEqual(engine.limit, 65)

        engine.resetForNewDrive()
        XCTAssertEqual(engine.speed, 0, "new drive must not inherit the filtered speed")
        XCTAssertEqual(engine.limit, 0)
        XCTAssertFalse(engine.isLimitResolved)
        XCTAssertEqual(engine.status, .safe)
    }

    // MARK: - Status arithmetic through the token path

    func testAppliedLimitDrivesWarningAndOverThroughRealBuffer() {
        // limit 45, buffer 5 → warning at ≥ 49, over at > 50.
        let engine = makeEngine()
        UserDefaults.standard.set(5, forKey: "userBuffer")
        let token = engine.beginLimitResolution()

        engine.processLocationForTesting(displayOnlyFix(speedMph: 49))
        engine.applyResolvedLimit(45, resolutionToken: token)
        XCTAssertEqual(engine.status, .warning, "1-mph-over-buffer fringe must be yellow")

        engine.processLocationForTesting(displayOnlyFix(speedMph: 60,
                                                        timestamp: Date().addingTimeInterval(1)))
        engine.applyResolvedLimit(45, resolutionToken: token)
        XCTAssertEqual(engine.status, .over, "well over the buffered threshold must be red")
    }

    func testMetricModeScalesBufferThroughTokenPath() {
        let engine = makeEngine()
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        UserDefaults.standard.set(5, forKey: "userBuffer") // 5 mph → 8.05 km/h

        engine.processLocationForTesting(displayOnlyFix(speedMph: 45))
        let token = engine.beginLimitResolution()
        engine.applyResolvedLimit(45, resolutionToken: token)
        // Imperial threshold would be 50; metric is 45 + 8.05 = 53.05 (display km/h).
        XCTAssertEqual(engine.status, .safe, "metric threshold must include the scaled buffer")

        engine.processLocationForTesting(displayOnlyFix(speedMph: 62,
                                                        timestamp: Date().addingTimeInterval(1)))
        engine.applyResolvedLimit(45, resolutionToken: token)
        XCTAssertEqual(engine.status, .over, "62 mph ≈ 99.8 km/h clears the metric threshold")
    }
}
