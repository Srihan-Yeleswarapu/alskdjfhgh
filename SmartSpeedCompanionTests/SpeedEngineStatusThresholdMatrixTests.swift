import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Exhaustive threshold matrix for the speed→status mapping.
///
/// The status boundaries (from SpeedEngine.updateStatus):
///   over     : speed > limit + buffer
///   warning  : limit + buffer − 1 ≤ speed ≤ limit + buffer   (Imperial)
///   safe     : speed < limit + buffer − 1
/// Metric multiplies both limit and buffer by 1.60934 and widens the
/// warning band to 2.0 (km/h). Each row of the matrix below is a real
/// driving scenario the HUD + AlertEngine both consume.
@MainActor
final class SpeedEngineStatusThresholdMatrixTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
    }

    override func tearDown() {
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    private func makeEngine(buffer: Int, metric: Bool = false) -> SpeedEngine {
        let engine = SpeedEngine(locationManager: LocationManager())
        UserDefaults.standard.set(metric ? "Metric" : "Imperial", forKey: "measurementSystem")
        UserDefaults.standard.set(buffer, forKey: "userBuffer")
        return engine
    }

    // MARK: - Imperial matrix (45 limit, +5 buffer → threshold 50)

    func testMatrix45LimitPlus5Buffer() {
        let engine = makeEngine(buffer: 5)
        engine.speed = 44.0
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .safe, "44 < 49 (threshold−1)")

        engine.speed = 48.9
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .safe, "48.9 < 49")

        engine.speed = 49.0
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .warning, "49 == threshold−1 enters the warning band")

        engine.speed = 49.9
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .warning, "49.9 is the top of the 1-mph band")

        engine.speed = 50.0
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .warning, "50 == threshold is still warning (strict > for over)")

        engine.speed = 50.01
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .over, "Anything above threshold is over")
    }

    // MARK: - Buffer shapes the boundary

    func testZeroBufferMakesLimitTheBoundary() {
        let engine = makeEngine(buffer: 0)
        engine.speed = 65.0
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .warning, "Exactly at limit with 0 buffer: warning band")

        engine.speed = 65.01
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .over)
    }

    func testNegativeBufferMakesStrictEnforcement() {
        let engine = makeEngine(buffer: -5)
        engine.speed = 58.0
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .safe,
                       "Threshold 60, warning band starts at 59; 58 is still safe")
    }

    func testNegativeBufferBoundaryPrecision() {
        let engine = makeEngine(buffer: -5)
        engine.speed = 58.9
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .safe, "58.9 < 59 (threshold 60 minus 1)")

        engine.speed = 59.0
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .warning)

        engine.speed = 60.0
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .warning, "At threshold exactly: warning")

        engine.speed = 60.5
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .over)
    }

    // MARK: - Unknown limit semantics

    func testUnknownLimitForcesSafeStatus() {
        let engine = makeEngine(buffer: 5)
        engine.speed = 90
        engine.applyResolvedLimit(0)
        XCTAssertEqual(engine.status, .safe,
                       "limit 0 is 'unknown', never an alertable condition")
        XCTAssertFalse(engine.isLimitResolved)
    }

    func testManualLimitApplyResolvesTheBadge() {
        let engine = makeEngine(buffer: 5)
        engine.speed = 30
        engine.applyResolvedLimit(35)
        XCTAssertTrue(engine.isLimitResolved)
        XCTAssertEqual(engine.limit, 35)
        XCTAssertEqual(engine.status, .safe)
    }

    // MARK: - Metric matrix

    /// Metric: 65 mph limit, +5 mph buffer → threshold (65+5)×1.60934 =
    /// 112.65 km/h; warning band = [110.65, 112.65] (2.0 km/h wide).
    func testMetricThresholdUsesConvertedLimitAndBuffer() {
        let engine = makeEngine(buffer: 5, metric: true)
        engine.speed = 100.0 // km/h display
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .safe, "100 < 110.65")

        engine.speed = 111.0
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .warning, "111 is inside the 2 km/h band")

        engine.speed = 112.7
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .over, "112.7 > 112.65")
    }

    /// The conversion must use the SAME 1.60934 factor as SpeedFormatting —
    /// a mismatch would make the HUD color and the alert audio disagree.
    func testMetricFactorMatchesSpeedFormattingConstant() {
        XCTAssertEqual(1.60934, SpeedFormatting.kmhPerMph, accuracy: 1e-9)
    }

    // MARK: - Resolution-token discipline

    /// A stale completion (older token) must be discarded: the driver turned
    /// onto a new road while the old lookup was in flight.
    func testStaleResolutionTokenIsDiscarded() {
        let engine = makeEngine(buffer: 5)
        let staleToken = engine.beginLimitResolution()
        // Simulate a newer resolution starting (bumps the generation).
        _ = engine.beginLimitResolution()
        engine.applyResolvedLimit(25, resolutionToken: staleToken)
        XCTAssertEqual(engine.limit, 0, "Stale token must not publish its limit")
        XCTAssertFalse(engine.isLimitResolved)
    }

    func testCurrentResolutionTokenIsAccepted() {
        let engine = makeEngine(buffer: 5)
        let token = engine.beginLimitResolution()
        engine.applyResolvedLimit(40, resolutionToken: token)
        XCTAssertEqual(engine.limit, 40)
        XCTAssertTrue(engine.isLimitResolved)
    }

    func testNilTokenAlwaysApplies() {
        let engine = makeEngine(buffer: 5)
        _ = engine.beginLimitResolution()
        engine.applyResolvedLimit(40, resolutionToken: nil)
        XCTAssertEqual(engine.limit, 40, "Manual/no-token applies are always authoritative")
    }

    // MARK: - New-drive reset

    func testResetForNewDriveClearsEverything() {
        let engine = makeEngine(buffer: 5)
        engine.speed = 60
        engine.applyResolvedLimit(55)
        XCTAssertEqual(engine.status, .over)

        engine.resetForNewDrive()
        XCTAssertEqual(engine.speed, 0)
        XCTAssertEqual(engine.limit, 0)
        XCTAssertFalse(engine.isLimitResolved)
        XCTAssertEqual(engine.status, .safe)
    }

    // MARK: - Full sweep: monotone status staircase

    /// For a fixed limit/buffer, sweeping speed upward must produce the
    /// exact status sequence safe…safe, warning…warning, over…over with no
    /// interleaving — a property check across 400 speed values.
    func testStatusStaircaseIsMonotoneAcrossFullSweep() {
        let engine = makeEngine(buffer: 5)
        var sawWarning = false
        var sawOver = false
        var lastStatus: SpeedStatus?

        for step in 0...400 {
            let mph = Double(step) * 0.25 // 0…100 mph in 0.25 steps
            engine.speed = mph
            engine.applyResolvedLimit(45)
            let status = engine.status

            if status == .warning { sawWarning = true }
            if status == .over { sawOver = true }
            if let last = lastStatus {
                let order: [SpeedStatus: Int] = [.safe: 0, .warning: 1, .over: 2]
                XCTAssertGreaterThanOrEqual(order[status]!, order[last]!,
                                            "Status regressed at \(mph) mph (\(last) → \(status))")
            }
            lastStatus = status
        }
        XCTAssertTrue(sawWarning, "Sweep must pass through warning")
        XCTAssertTrue(sawOver, "Sweep must reach over")
    }
}
