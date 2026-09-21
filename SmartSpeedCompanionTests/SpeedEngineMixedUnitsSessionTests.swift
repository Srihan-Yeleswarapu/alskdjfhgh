import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// A km/h user and a mph user driving the same road at the same physical
/// speed must see the SAME alert state — only the numbers on the dial differ.
/// That unit-invariance is the engine's most safety-adjacent invariant: if
/// the metric path scaled the speed but not the limit (or vice versa), the
/// metric user's alerts would fire at the wrong moment. This file drives the
/// SAME synthetic drive twice (once per unit system) through real engine
/// instances and demands identical status sequences, exactly-scaled display
/// values, and stable behavior across MID-DRIVE unit toggles and buffer
/// changes (the TestFlight 2.3.0 live-read bug class).
@MainActor
final class SpeedEngineMixedUnitsSessionTests: XCTestCase {

    private var guard_: UserDefaultsTestGuard!
    private var hereGate: HERECredentialsGate!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate()
        hereGate.close()
        guard_ = UserDefaultsTestGuard()
        guard_.snapshotNow()
        guard_.resetToFreshInstall()
    }

    override func tearDown() {
        guard_.restore()
        hereGate.reopen()
        super.tearDown()
    }

    private func makeEngine() -> SpeedEngine {
        SpeedEngine(locationManager: LocationManager())
    }

    /// A deterministic 8-fix arterial drive: 20→45→55→50 mph with a stop.
    /// Same timestamps for both unit systems so the EMA path is identical.
    private func driveFixes() -> [CLLocation] {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let speeds: [Double] = [20, 35, 45, 55, 55, 50, 2, 0]
        return speeds.enumerated().map { i, mph in
            GPSFixFactory.fix(lat: 33.3062, lon: -111.8412 + Double(i) * 0.0004,
                              speedMph: mph, accuracy: 150, // display-only: hermetic
                              timestamp: t0.addingTimeInterval(Double(i)))
        }
    }

    // MARK: - Unit invariance of the status sequence

    func testSameDriveProducesIdenticalStatusSequenceInBothUnits() {
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        let imperial = makeEngine()
        var imperialStatuses: [SpeedStatus] = []
        var imperialDisplays: [Double] = []
        for fix in driveFixes() {
            imperial.processLocationForTesting(fix)
            imperialStatuses.append(imperial.status)
            imperialDisplays.append(imperial.speed)
        }

        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        let metric = makeEngine()
        var metricStatuses: [SpeedStatus] = []
        var metricDisplays: [Double] = []
        for fix in driveFixes() {
            metric.processLocationForTesting(fix)
            metricStatuses.append(metric.status)
            metricDisplays.append(metric.speed)
        }

        XCTAssertEqual(imperialStatuses, metricStatuses,
                       "alert state must be unit-invariant for the same physical drive")
        // Display values: metric must be exactly the imperial value scaled.
        for (i, m) in zip(imperialDisplays, metricDisplays).enumerated() {
            XCTAssertEqual(m, imperialDisplays[i] * 1.60934, accuracy: 0.05,
                           "display \(i) broke the 1.60934 scaling")
        }
    }

    func testMidDriveUnitToggleKeepsAlertStateConsistent() {
        let engine = makeEngine()
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")

        // Establish overspeed: 60 on a 50 limit with buffer 5.
        engine.applyResolvedLimit(50)
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 60, accuracy: 150))
        XCTAssertEqual(engine.status, .over)

        // Toggle mid-drive: the same physical state must stay .over.
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3065, lon: -111.8412, speedMph: 60, accuracy: 150,
                              timestamp: Date().addingTimeInterval(1)))
        XCTAssertEqual(engine.status, .over, "toggling to Metric flipped the alert state")
        // Display is now km/h and physically consistent (60 mph ≈ 96.6).
        XCTAssertEqual(engine.speed, 96.6, accuracy: 0.5)

        // And back.
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3068, lon: -111.8412, speedMph: 60, accuracy: 150,
                              timestamp: Date().addingTimeInterval(2)))
        XCTAssertEqual(engine.status, .over)
        XCTAssertEqual(engine.speed, 60, accuracy: 0.3, "returning to Imperial must un-scale the display")
    }

    func testStatusMatrixIsIdenticalAcrossUnits() {
        // Sweep (speed, limit) states; status must match unit-for-unit.
        let states: [(speedMph: Double, limit: Int)] = [
            (30, 50), (50, 50), (54, 50), (56, 50), (65, 50),
            (15, 20), (20, 20), (25, 20), (70, 75), (0, 50)
        ]
        for state in states {
            UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
            let imp = makeEngine()
            imp.applyResolvedLimit(state.limit)
            imp.processLocationForTesting(
                GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: state.speedMph, accuracy: 150))
            let impStatus = imp.status

            UserDefaults.standard.set("Metric", forKey: "measurementSystem")
            let met = makeEngine()
            met.applyResolvedLimit(state.limit)
            met.processLocationForTesting(
                GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: state.speedMph, accuracy: 150))
            let metStatus = met.status

            XCTAssertEqual(impStatus, metStatus,
                           "status diverged across units at speed \(state.speedMph) / limit \(state.limit)")
        }
    }

    // MARK: - Internal smoothing stays MPH

    func testMetricDisplayIsExactlyScaledMphSeed() {
        // First fix seeds the EMA with the raw mph value; the metric display
        // must be that seed × 1.60934 — proof the EMA runs in mph space and
        // only the presentation scales. A km/h-internal EMA would compound
        // the factor on every tick.
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        let engine = makeEngine()
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 60, accuracy: 150))
        XCTAssertEqual(engine.speed, 60 * 1.60934, accuracy: 0.01, "first-fix seed not scaled from mph")

        // Steady state: no further compounding.
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3065, lon: -111.8412, speedMph: 60, accuracy: 150,
                              timestamp: Date().addingTimeInterval(1)))
        XCTAssertEqual(engine.speed, 60 * 1.60934, accuracy: 0.01,
                       "metric display compounded — the EMA is running in km/h")
    }

    func testImperialDisplayAppliesNoScaling() {
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        let engine = makeEngine()
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 47, accuracy: 150))
        XCTAssertEqual(engine.speed, 47, accuracy: 0.01,
                       "imperial display must be the raw smoothed mph (a ×1.6 bug shows 75)")
    }

    // MARK: - Live buffer read mid-drive (TestFlight 2.3.0 regression)

    func testBufferChangeMidDriveTakesEffectImmediatelyInMetric() {
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        UserDefaults.standard.set(3, forKey: "userBuffer")
        let engine = makeEngine()
        engine.applyResolvedLimit(50)

        // 90 km/h display (55.9 mph): over a 3-mph (4.8 km/h) buffer.
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 55.9, accuracy: 150))
        XCTAssertEqual(engine.status, .over)

        // User widens the buffer to 8 mph (12.9 km/h) mid-drive — no engine
        // recreation. The live read must pick it up on the next tick.
        UserDefaults.standard.set(8, forKey: "userBuffer")
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3065, lon: -111.8412, speedMph: 55.9, accuracy: 150,
                              timestamp: Date().addingTimeInterval(1)))
        XCTAssertEqual(engine.status, .safe, "mid-drive buffer change ignored (stale-launch value in use)")
    }

    // MARK: - Preferences survive drive resets

    func testResetForNewDrivePreservesUnitsAndBuffer() {
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        UserDefaults.standard.set(7, forKey: "userBuffer")
        let engine = makeEngine()
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 50, accuracy: 150))
        engine.applyResolvedLimit(45)

        engine.resetForNewDrive()
        XCTAssertEqual(engine.measurementSystem, "Metric", "reset must not clobber unit preference")
        XCTAssertEqual(engine.userBuffer, 7, "reset must not clobber buffer preference")
        XCTAssertEqual(engine.speed, 0)
        XCTAssertFalse(engine.isLimitResolved)
    }

    // MARK: - Deadband across a mid-drive toggle

    func testZeroDeadbandSurvivesUnitToggle() {
        let engine = makeEngine()
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")

        // Build deadband: 5 sub-3-mph readings.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            engine.processLocationForTesting(
                GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 1.5, accuracy: 150,
                                  timestamp: t0.addingTimeInterval(Double(i))))
        }
        XCTAssertEqual(engine.speed, 0, "deadband must clamp noise to zero")

        // Toggle units mid-stop: the deadband state must not reset into
        // showing phantom 2.4 km/h noise, nor stay stuck when motion resumes.
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 1.5, accuracy: 150,
                              timestamp: t0.addingTimeInterval(5)))
        XCTAssertEqual(engine.speed, 0, "unit toggle resurrected deadband noise")

        engine.processLocationForTesting(
            GPSFixFactory.fix(lat: 33.3065, lon: -111.8412, speedMph: 40, accuracy: 150,
                              timestamp: t0.addingTimeInterval(6)))
        XCTAssertEqual(engine.speed, 40 * 1.60934, accuracy: 0.5, "motion after toggle did not recover")
    }

    // MARK: - Metric-only deadband boundary scaling

    func testDeadbandThresholdsStayMphDenominatedInMetricMode() {
        // The deadband (3.0/0.8 mph) is defined on RAW mph regardless of the
        // display unit: 2 km/h of genuine creep (1.24 mph raw) must still be
        // treated as sub-threshold noise, not rounded up into "moving".
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        let engine = makeEngine()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            engine.processLocationForTesting(
                GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 1.24, accuracy: 150,
                                  timestamp: t0.addingTimeInterval(Double(i))))
        }
        XCTAssertEqual(engine.speed, 0, "1.24 mph (2 km/h) creep must hit the deadband in metric mode too")
    }
}
