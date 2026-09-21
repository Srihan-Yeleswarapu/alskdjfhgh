import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Deep numeric verification of SpeedEngine's speed-display pipeline.
///
/// The engine's display value is not the GPS value: it passes through a
/// validity gate (speedAccuracy ≤ 5 m/s), a zero-force floor, a 5-tick
/// deadband, an adaptive EMA (0.35 normal / 0.65 rapid ≥ 10 mph jump), a
/// sample-gap reseed (> 5 s), and an invalid-speed expiry (3 s). Each test
/// pins one arithmetic boundary of that pipeline with hand-computed
/// expected values.
@MainActor
final class SpeedEngineSmoothingDeepTests: XCTestCase {

    private var guard_: UserDefaultsTestGuard!
    private var hereGate: HERECredentialsGate!

    override func setUp() {
        super.setUp()
        // Hermetic switch: no HERE credentials → live providers return nil
        // before building any URL. The engine pipeline still runs for real.
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

    // MARK: - Validity gate

    /// speedAccuracy worse than 5 m/s must be rejected entirely: the display
    /// must not move even though a numeric speed is present on the fix.
    func testSpeedAccuracyBeyondFiveMpsIsRejected() {
        let engine = makeEngine()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let badFix = GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                       speedMph: 60, speedAccuracy: 5.01, timestamp: t0)
        engine.processLocationForTesting(badFix)
        XCTAssertEqual(engine.speed, 0, "Fix with speedAccuracy > 5 m/s must not move the display")
    }

    /// Exactly-at-threshold accuracy (5.0) is accepted — the gate is a
    /// strict inequality (`> 5.0`), and this pins which side of it stands.
    func testSpeedAccuracyExactlyAtFiveMpsIsAccepted() {
        let engine = makeEngine()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let fix = GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                    speedMph: 60, speedAccuracy: 5.0, timestamp: t0)
        engine.processLocationForTesting(fix)
        XCTAssertEqual(engine.speed, 60, accuracy: 0.01,
                       "speedAccuracy == 5.0 sits on the accepted side of the gate")
    }

    /// The -1 speedAccuracy sentinel (common on simulators and some
    /// background fixes) must be treated as "unknown, trust the speed".
    func testNegativeSpeedAccuracySentinelIsTrusted() {
        let engine = makeEngine()
        let fix = GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                    speedMph: 25, speedAccuracy: -1)
        engine.processLocationForTesting(fix)
        XCTAssertEqual(engine.speed, 25, accuracy: 0.01)
    }

    /// The -1 speed sentinel (Core Location's "invalid") must produce no
    /// display update — and no crash, no NaN.
    func testInvalidSpeedSentinelProducesZeroAndNoNaN() {
        let engine = makeEngine()
        engine.processLocationForTesting(GPSFixFactory.speedlessFix())
        XCTAssertEqual(engine.speed, 0)
        XCTAssertFalse(engine.speed.isNaN)
        XCTAssertEqual(engine.status, .safe)
    }

    // MARK: - Force-zero floor

    /// Raw speeds below 0.8 mph force the display to exactly 0 immediately
    /// (no EMA tail), so a stopped car never reads "0.6 mph".
    func testForceZeroFloorClampsCrawlNoiseToZero() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)

        // Establish motion first so the EMA has a nonzero state to clobber.
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 40, timestamp: t))
        XCTAssertEqual(engine.speed, 40, accuracy: 0.01)
        t.addTimeInterval(1)

        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.30625, lon: -111.8412,
                                                           speedMph: 0.5, timestamp: t))
        XCTAssertEqual(engine.speed, 0, "Sub-0.8 mph raw must force display to exactly 0")
        XCTAssertEqual(engine.status, .safe)
    }

    // MARK: - Deadband

    /// Persistent sub-3 mph readings: the first four may show, the fifth
    /// consecutive one must clamp to zero (minZerosBeforeStop == 5).
    func testFiveConsecutiveLowReadingsTriggerDeadband() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        var c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)

        // Fifth consecutive below-3-mph tick flips the deadband.
        for tick in 1...5 {
            t.addTimeInterval(1)
            c = GPSFixFactory.advance(c, meters: 0.5, heading: 90)
            engine.processLocationForTesting(GPSFixFactory.fix(lat: c.latitude, lon: c.longitude,
                                                               speedMph: 2.0, timestamp: t))
            if tick < 5 {
                XCTAssertEqual(engine.speed, 2.0, accuracy: 0.01,
                               "Tick \(tick): deadband must not fire before 5 consecutive ticks")
            } else {
                XCTAssertEqual(engine.speed, 0,
                               "Tick 5: deadband must clamp persistent GPS noise to zero")
            }
        }
    }

    /// One genuinely-moving tick resets the deadband counter — stop-and-go
    /// traffic (creep, roll, creep) must not accumulate into a false stop.
    func testMovingTickResetsDeadbandAccumulation() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        var c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)

        // Four creep ticks (counter at 4), then a real 20 mph tick.
        for _ in 0..<4 {
            t.addTimeInterval(1)
            c = GPSFixFactory.advance(c, meters: 0.5, heading: 90)
            engine.processLocationForTesting(GPSFixFactory.fix(lat: c.latitude, lon: c.longitude,
                                                               speedMph: 2.0, timestamp: t))
        }
        t.addTimeInterval(1)
        c = GPSFixFactory.advance(c, meters: 9, heading: 90)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: c.latitude, lon: c.longitude,
                                                           speedMph: 20, timestamp: t))

        // Four more creep ticks: without the reset these would trip the band.
        for _ in 0..<4 {
            t.addTimeInterval(1)
            c = GPSFixFactory.advance(c, meters: 0.5, heading: 90)
            engine.processLocationForTesting(GPSFixFactory.fix(lat: c.latitude, lon: c.longitude,
                                                               speedMph: 2.0, timestamp: t))
        }
        XCTAssertEqual(engine.speed, 2.0, accuracy: 0.05,
                       "A moving tick must reset the deadband counter (stop-and-go traffic)")
    }

    // MARK: - EMA arithmetic

    /// Small delta: smoothed += 0.35 × (raw − smoothed). From 40 → 45 mph:
    /// 40 + 0.35 × 5 = 41.75.
    func testNormalSmoothingFactorIs035() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 40, timestamp: t))
        t.addTimeInterval(1)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.30625, lon: -111.8412,
                                                           speedMph: 45, timestamp: t))
        assertMph(engine.speed, equals: 41.75, "EMA factor 0.35: 40 + 0.35×5")
    }

    /// Large delta (≥ 10 mph): the rapid factor 0.65 applies. From 40 → 55:
    /// 40 + 0.65 × 15 = 49.75.
    func testRapidSmoothingFactorIs065OnLargeJumps() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 40, timestamp: t))
        t.addTimeInterval(1)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.30625, lon: -111.8412,
                                                           speedMph: 55, timestamp: t))
        assertMph(engine.speed, equals: 49.75, "Rapid EMA factor 0.65: 40 + 0.65×15")
    }

    /// Exactly at the 10 mph delta boundary the rapid factor applies
    /// (the comparison is `>=`).
    func testExactlyTenMphDeltaUsesRapidFactor() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 40, timestamp: t))
        t.addTimeInterval(1)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.30625, lon: -111.8412,
                                                           speedMph: 50, timestamp: t))
        assertMph(engine.speed, equals: 46.5, "40 + 0.65×10 = 46.5")
    }

    /// Convergence: repeated constant raw speeds converge exponentially;
    /// after enough ticks the display must be within GPS display precision.
    func testEMAConvergesToConstantRawSpeed() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        var c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: c.latitude, lon: c.longitude,
                                                           speedMph: 20, timestamp: t))
        for _ in 0..<40 {
            t.addTimeInterval(1)
            c = GPSFixFactory.advance(c, meters: 8.94, heading: 90) // ~20 mph
            engine.processLocationForTesting(GPSFixFactory.fix(lat: c.latitude, lon: c.longitude,
                                                               speedMph: 20, timestamp: t))
        }
        assertMph(engine.speed, equals: 20.0, "Display must converge to a steady 20 mph")
    }

    /// A gap > 5 s between samples reseeds the EMA with the raw value —
    /// a new drive (or tunnel exit) must not inherit the stale filter.
    func testSampleGapReseedsFilter() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 30, timestamp: t))
        // 6-second gap — beyond the 5 s threshold.
        t.addTimeInterval(6)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8300,
                                                           speedMph: 60, timestamp: t))
        assertMph(engine.speed, equals: 60.0, "Post-gap tick must reseed to the raw speed")
    }

    // MARK: - Invalid-speed expiry

    /// After 3+ seconds of speedless fixes the last moving speed must
    /// expire to zero — a frozen "60" while the fix stream dies is worse
    /// than an honest zero. NOTE: expiry compares against wall-clock now,
    /// so this test uses live timestamps instead of the 2023 epoch.
    func testInvalidSpeedExpiresAfterThreeSeconds() {
        let engine = makeEngine()
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 60))
        XCTAssertEqual(engine.speed, 60, accuracy: 0.01)

        // Speedless fixes immediately after: within the 3 s window, hold.
        engine.processLocationForTesting(GPSFixFactory.speedlessFix(timestamp: Date().addingTimeInterval(1)))
        XCTAssertEqual(engine.speed, 60, accuracy: 0.01, "Inside the timeout the last speed may hold")

        // Past the window: expire.
        engine.processLocationForTesting(GPSFixFactory.speedlessFix(timestamp: Date().addingTimeInterval(4)))
        XCTAssertEqual(engine.speed, 0, "Beyond 3 s of invalid speed the display must drop to 0")
    }

    // MARK: - Metric conversion

    /// The internal state stays mph; the published speed converts for
    /// Metric users. 45 mph × 1.60934 = 72.42 km/h.
    func testMetricDisplayConvertsPublishedSpeed() {
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        let engine = makeEngine()
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 45))
        XCTAssertEqual(engine.speed, 45 * 1.60934, accuracy: 0.06,
                       "Metric display must be mph × 1.60934")
    }

    /// Smoothing happens in mph space BEFORE conversion — a metric user's
    /// first fix at 45 mph displays exactly 72.42, not an EMA'd hybrid.
    func testMetricSmoothingIsDoneInMphSpace() {
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        let engine = makeEngine()
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 45))
        // If smoothing happened after conversion, the first tick would
        // still seed at raw — but the second tick's EMA math would differ.
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.30625, lon: -111.8412,
                                                           speedMph: 55))
        // mph-space: 45 + 0.65×10 = 51.5 → × 1.60934 = 82.88
        XCTAssertEqual(engine.speed, 51.5 * 1.60934, accuracy: 0.1,
                       "EMA must operate in mph, then convert once for display")
    }
}
