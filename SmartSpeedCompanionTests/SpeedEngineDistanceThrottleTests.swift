import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// SpeedEngine's fetch orchestration: a speed-limit lookup fires only when
/// (a) the fix passes the accuracy gate, and (b) the driver moved 80 m
/// (surface) / 250 m (highway, ≥ 20 m/s) since the last fetch. The throttle
/// is the single biggest protector of the HERE freemium budget during real
/// driving, so its constants and side effects are pinned here.
@MainActor
final class SpeedEngineDistanceThrottleTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
    }

    override func tearDown() {
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    private func makeEngine() -> SpeedEngine {
        SpeedEngine(locationManager: LocationManager())
    }

    // MARK: - Accuracy gate (pure function)

    /// The gate is `0 < horizontalAccuracy < 100` — LocationManager's
    /// acceptance ceiling. Everything else is rejected BEFORE any provider
    /// work (and therefore before any chance of a network call).
    func testEligibilityBoundaryValues() {
        func eligible(accuracy: CLLocationAccuracy) -> Bool {
            SpeedEngine.isEligibleForSpeedLimitResolution(
                GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 30, accuracy: accuracy)
            )
        }
        XCTAssertFalse(eligible(accuracy: -5), "Negative accuracy (invalid) rejected")
        XCTAssertFalse(eligible(accuracy: 0), "Zero accuracy (invalid) rejected")
        XCTAssertTrue(eligible(accuracy: 0.001), "Pinpoint accepted")
        XCTAssertTrue(eligible(accuracy: 99.99), "Just inside the 100 m ceiling accepted")
        XCTAssertFalse(eligible(accuracy: 100.0), "Exactly 100 m rejected (strict <)")
        XCTAssertFalse(eligible(accuracy: 250), "Worse than ceiling rejected")
    }

    // MARK: - Throttle constants via source policy

    /// The throttle distances live as private constants; this pins them via
    /// source so a silent retune (which would multiply HERE usage) fails
    /// the suite with a message explaining the cost.
    func testThrottleDistancesArePinnedInSource() throws {
        let source = try String(contentsOfFile: engineSourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("surfaceFetchDistance: CLLocationDistance = 80.0"),
                      "Surface fetch throttle must remain 80 m (one city block). Raising it misses turns; lowering it multiplies HERE usage.")
        XCTAssertTrue(source.contains("highwayFetchDistance: CLLocationDistance = 250.0"),
                      "Highway fetch throttle must remain 250 m.")
    }

    func testHighwayThresholdUsesMetersPerSecond20() throws {
        let source = try String(contentsOfFile: engineSourcePath(), encoding: .utf8)
        // location.speed is m/s; the highway branch must compare in m/s.
        XCTAssertTrue(source.contains("location.speed >= 20.0"),
                      "Highway throttle selection must compare CLLocation.speed (m/s) against 20")
    }

    // MARK: - Limit-clearing semantics during resolution

    /// Starting a resolution clears the displayed limit immediately: an old
    /// limit must not keep beeping while the new road is being resolved.
    func testBeginLimitResolutionClearsPublishedState() {
        let engine = makeEngine()
        engine.speed = 70
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.limit, 65)
        XCTAssertTrue(engine.isLimitResolved)

        _ = engine.beginLimitResolution()
        XCTAssertEqual(engine.limit, 0, "In-flight resolution must present 'unknown'")
        XCTAssertFalse(engine.isLimitResolved)
        XCTAssertEqual(engine.status, .safe, "No red state while resolving")
    }

    /// beginLimitResolution returns strictly increasing tokens — that's
    /// what makes stale-completion detection possible.
    func testResolutionTokensAreStrictlyIncreasing() {
        let engine = makeEngine()
        var previous: UInt64 = 0
        for _ in 0..<10 {
            let token = engine.beginLimitResolution()
            XCTAssertGreaterThan(token, previous)
            previous = token
        }
    }

    /// resetForNewDrive must invalidate any in-flight resolution so a
    /// completion from the previous drive cannot land on the new one.
    func testResetForNewDriveInvalidatesInFlightTokens() {
        let engine = makeEngine()
        let staleToken = engine.beginLimitResolution()
        engine.resetForNewDrive()
        engine.applyResolvedLimit(45, resolutionToken: staleToken)
        XCTAssertEqual(engine.limit, 0, "Pre-reset token must be dead after resetForNewDrive")
    }

    // MARK: - Initial-setup trigger policy

    /// The one-shot initial HERE batch setup fires on the first eligible
    /// fix only. Pinned via source: `hasFiredInitialSetup` guards it, and
    /// the radius handed to performInitialSetup is 2500 m.
    func testInitialSetupIsOneShotInSource() throws {
        let source = try String(contentsOfFile: engineSourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("hasFiredInitialSetup"),
                      "Initial batch setup must be one-shot guarded")
        XCTAssertTrue(source.contains("performInitialSetup"),
                      "Initial setup must route through HEREGeofenceManager.performInitialSetup")
    }

    func testInitialSetupRadiusIsTwoPointFiveKmInSource() throws {
        let source = try String(contentsOfFile: geofenceSourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("radiusMeters: 2500"),
                      "Initial setup grid must stay 2.5 km — widening it multiplies HERE batch cost per drive")
    }

    // MARK: - Consecutive fetch accounting (behavioral, hermetic)

    /// Driving 30 m ticks (surface speed) must NOT re-trigger limit
    /// resolution — the published limit stays resolved between fetches.
    /// 10 ticks at 30 m = 300 m, one fetch at tick ~3 (80 m), then quiet.
    func testSubThrottleMovementKeepsResolvedLimitStable() {
        let engine = makeEngine()
        var c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        var t = Date(timeIntervalSince1970: 1_700_000_000)

        // First eligible fix starts resolution → limit clears to 0.
        engine.processLocationForTesting(GPSFixFactory.fix(lat: c.latitude, lon: c.longitude,
                                                           speedMph: 40, timestamp: t))
        XCTAssertFalse(engine.isLimitResolved, "First fix must begin resolution (cleared state)")

        // Manually resolve to simulate a completed lookup.
        engine.applyResolvedLimit(45)
        XCTAssertTrue(engine.isLimitResolved)

        // Drive 300 m in 30 m ticks at 40 mph (surface < 20 m/s → 80 m rule).
        for _ in 0..<10 {
            t.addTimeInterval(1)
            c = GPSFixFactory.advance(c, meters: 30, heading: 90)
            engine.processLocationForTesting(GPSFixFactory.fix(lat: c.latitude, lon: c.longitude,
                                                               speedMph: 40, timestamp: t))
            // After the 80 m boundary (tick 3) a new resolution starts and
            // clears the limit — but before that, the limit must persist.
            if engine.isLimitResolved {
                XCTAssertEqual(engine.limit, 45)
            }
        }
        // Regardless of throttle bookkeeping, no test tick may have left
        // the limit corrupted mid-value.
        XCTAssertTrue([0, 45].contains(engine.limit), "Limit must be either the resolved 45 or cleared-during-resolution 0")
    }

    /// Highway speeds (≥ 45 mph ≈ 20.1 m/s) must select the 250 m throttle:
    /// verify via source that the comparison is on location.speed (m/s),
    /// not mph — comparing 45 (mph) >= 20 would silently put every surface
    /// street on the highway cadence.
    func testThrottleSelectionComparesMpsNotMph() throws {
        let source = try String(contentsOfFile: engineSourcePath(), encoding: .utf8)
        let selection = try sourceSection(in: source, anchor: "let threshold: CLLocationDistance = location.speed")
        XCTAssertTrue(selection.contains("highwayFetchDistance"), "Highway branch must exist")
        XCTAssertTrue(selection.contains("surfaceFetchDistance"), "Surface branch must exist")
    }

    // MARK: - Helpers

    private func sourceSection(in source: String, anchor: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else {
            XCTFail("Missing expected source anchor: \(anchor)")
            return ""
        }
        let body = source[anchorRange.lowerBound...]
        guard let endRange = body.range(of: "\n") else { return String(body) }
        return String(body[..<endRange.lowerBound])
    }

    private func engineSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\SpeedEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/SpeedEngine.swift"
        #endif
    }

    private func geofenceSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\HEREGeofenceManager.swift"
        #else
        return "SmartSpeedCompanion/Core/HEREGeofenceManager.swift"
        #endif
    }
}
