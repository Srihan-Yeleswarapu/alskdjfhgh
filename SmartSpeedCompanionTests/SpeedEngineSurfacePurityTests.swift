import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Property-based invariants: no matter WHAT fix sequence arrives (GPS
/// dropouts, teleports, ±mph noise storms, metric toggles mid-drive), the
/// engine's published surface must never enter an unrenderable state —
/// NaN speeds, negative limits, red status with unknown limit, warning
/// outside the band. These are the "can't crash the HUD" guarantees.
@MainActor
final class SpeedEngineSurfacePurityTests: XCTestCase {

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

    private func makeEngine(metric: Bool = false) -> SpeedEngine {
        UserDefaults.standard.set(metric ? "Metric" : "Imperial", forKey: "measurementSystem")
        return SpeedEngine(locationManager: LocationManager())
    }

    /// Deterministic seeded PRNG so failures are reproducible.
    private struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private func assertInvariants(_ engine: SpeedEngine, _ step: Int) {
        XCTAssertFalse(engine.speed.isNaN, "Step \(step): speed became NaN")
        XCTAssertFalse(engine.speed.isInfinite)
        XCTAssertGreaterThanOrEqual(engine.speed, 0, "Step \(step): negative display speed")
        XCTAssertGreaterThanOrEqual(engine.limit, 0, "Step \(step): negative limit")
        if engine.limit == 0 || !engine.isLimitResolved {
            XCTAssertEqual(engine.status, .safe,
                           "Step \(step): non-safe status with unknown limit")
        }
        if engine.status == .over {
            XCTAssertGreaterThan(engine.speed, 0, "Step \(step): over-status at zero speed")
        }
    }

    // MARK: - Randomized drive storm

    func testRandomFixStormKeepsSurfaceInvariants() {
        var rng = SeededRandom(seed: 0x5EED)
        let engine = makeEngine()
        var coord = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        var t = Date(timeIntervalSince1970: 1_700_000_000)

        for step in 0..<500 {
            // Random scenario mix.
            let roll = rng.next()
            let speedMph: Double
            let accuracy: CLLocationAccuracy
            if roll < 0.1 {
                speedMph = -1; accuracy = 5 // speedless fix
            } else if roll < 0.2 {
                speedMph = rng.next() * 90; accuracy = 150 // unusable accuracy
            } else if roll < 0.4 {
                speedMph = 0; accuracy = 5 // stop
            } else {
                speedMph = rng.next() * 85; accuracy = 4 + rng.next() * 3
            }
            coord = GPSFixFactory.advance(coord, meters: rng.next() * 50, heading: rng.next() * 360)
            t.addTimeInterval(0.5)

            let fix = speedMph < 0
                ? GPSFixFactory.speedlessFix(lat: coord.latitude, lon: coord.longitude, timestamp: t)
                : GPSFixFactory.fix(lat: coord.latitude, lon: coord.longitude,
                                    speedMph: speedMph, accuracy: accuracy, timestamp: t)
            engine.processLocationForTesting(fix)

            // Random limit publications (including stale tokens).
            if rng.next() < 0.2 {
                engine.applyResolvedLimit(Int(rng.next() * 80))
            }
            if rng.next() < 0.1 {
                _ = engine.beginLimitResolution()
            }
            assertInvariants(engine, step)
        }
    }

    // MARK: - Teleport handling

    func testTeleportDoesNotCorruptState() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                                           speedMph: 45, timestamp: t))
        // Jump to NYC.
        t.addTimeInterval(1)
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 40.7128, lon: -74.0060,
                                                           speedMph: 20, timestamp: t))
        assertInvariants(engine, 0)
        // The display must reseed (gap semantics don't apply — timestamps
        // are 1 s apart — but a 100 mph EMA jump engages the rapid factor).
        XCTAssertLessThanOrEqual(engine.speed, 20 * 1.7 + 1, "Speed must track the new location's physics")
    }

    // MARK: - Unit toggle mid-drive

    func testUnitToggleMidDriveKeepsInvariants() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)
        for step in 0..<20 {
            UserDefaults.standard.set(step.isMultiple(of: 2) ? "Imperial" : "Metric",
                                      forKey: "measurementSystem")
            t.addTimeInterval(1)
            engine.processLocationForTesting(GPSFixFactory.fix(
                lat: 33.3062 + Double(step) * 0.0003, lon: -111.8412,
                speedMph: 40 + Double(step) % 20, timestamp: t))
            assertInvariants(engine, step)
        }
    }

    // MARK: - Extreme inputs

    func testExtremeInputsNeverBreakSurface() {
        let engine = makeEngine()
        var t = Date(timeIntervalSince1970: 1_700_000_000)

        engine.processLocationForTesting(GPSFixFactory.fix(lat: 90, lon: 180, speedMph: 0, timestamp: t))
        assertInvariants(engine, 0)

        engine.processLocationForTesting(GPSFixFactory.fix(lat: -90, lon: -180, speedMph: 85, timestamp: t))
        assertInvariants(engine, 1)

        engine.applyResolvedLimit(90)   // legal max
        assertInvariants(engine, 2)
        engine.applyResolvedLimit(-5)   // corrupt input
        assertInvariants(engine, 3)
        engine.applyResolvedLimit(0)    // unknown
        assertInvariants(engine, 4)
    }

    // MARK: - Limit/status coupling property

    /// For resolved limits, the published status must ALWAYS match the
    /// threshold math recomputed from the published speed/limit/buffer.
    func testStatusAlwaysMatchesRecomputedThreshold() {
        let engine = makeEngine()
        UserDefaults.standard.set(7, forKey: "userBuffer")
        var t = Date(timeIntervalSince1970: 1_700_000_000)

        for step in 0..<100 {
            t.addTimeInterval(1)
            let speed = Double(step) % 90
            let limit = [0, 25, 35, 45, 55, 65, 75][step % 7]
            engine.processLocationForTesting(GPSFixFactory.fix(
                lat: 33.3062, lon: -111.8412 + Double(step) * 0.0003,
                speedMph: speed, timestamp: t))
            engine.speed = speed
            engine.applyResolvedLimit(limit)

            if limit > 0 && engine.isLimitResolved {
                let threshold = Double(limit + engine.userBuffer)
                let expected: SpeedStatus
                if speed > threshold { expected = .over }
                else if speed >= threshold - 1 { expected = .warning }
                else { expected = .safe }
                XCTAssertEqual(engine.status, expected,
                               "Step \(step): published status diverged from recomputed math")
            }
        }
    }
}
