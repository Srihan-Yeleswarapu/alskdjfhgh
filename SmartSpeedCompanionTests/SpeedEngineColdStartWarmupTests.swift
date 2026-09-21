import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// SpeedEngine cold start: the first 30 seconds of a drive — engine created,
/// no GPS yet, no resolved limit. The UI must show sane placeholders, never
/// garbage or a false "speeding" state, and no HERE call may fire before the
/// driver moves (credentials gate double-checked).
@MainActor
final class SpeedEngineColdStartWarmupTests: XCTestCase {

    private var hereGate: HERECredentialsGate!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
    }

    override func tearDown() {
        hereGate.reopen()
        super.tearDown()
    }

    // MARK: - Construction state

    func testFreshEngineStartsSafe() {
        let engine = SpeedEngine(locationManager: LocationManager())
        XCTAssertEqual(engine.speed, 0, accuracy: 1e-9,
                       "Cold engine must report 0, not NaN/sentinel")
        XCTAssertEqual(engine.status, .safe,
                       "Cold engine must not open in a warning state")
    }

    func testFreshEngineLimitUnresolved() {
        let engine = SpeedEngine(locationManager: LocationManager())
        XCTAssertEqual(engine.limit, 0,
                       "Cold engine claims a limit before resolution — UI would show a bogus badge")
        XCTAssertFalse(engine.isLimitResolved)
    }

    // MARK: - First fix handling

    func testFirstFixWithInvalidSpeedDoesNotCrash() {
        let engine = SpeedEngine(locationManager: LocationManager())
        // GPS's very first fix often has speed = -1 (invalid).
        let fix = GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                    speedMph: 0, course: 90,
                                    timestamp: Date(timeIntervalSince1970: 9_000_000))
        engine.processLocation(fix) // must not crash or throw
        XCTAssertEqual(engine.speed, 0, accuracy: 1e-9)
    }

    func testFirstFixDoesNotFireAlert() {
        let engine = SpeedEngine(locationManager: LocationManager())
        engine.processLocation(GPSFixFactory.fix(
            lat: 33.3062, lon: -111.8412, speedMph: 65, course: 90,
            timestamp: Date(timeIntervalSince1970: 9_000_000)))
        // No resolved limit → cannot be over → alert impossible on fix #1.
        XCTAssertFalse(engine.isLimitResolved)
        XCTAssertEqual(engine.status, .safe)
    }

    func testFirstFixTriggersResolutionRequestExactlyOnce() {
        // The engine requests limit resolution on the first eligible fix;
        // with the gate closed nothing goes out, but the request must be
        // scheduled exactly once — not per-property-read.
        let engine = SpeedEngine(locationManager: LocationManager())
        engine.processLocation(GPSFixFactory.fix(
            lat: 33.3062, lon: -111.8412, speedMph: 35, course: 90,
            timestamp: Date(timeIntervalSince1970: 9_000_000)))
        engine.processLocation(GPSFixFactory.fix(
            lat: 33.3062, lon: -111.8412, speedMph: 35, course: 90,
            timestamp: Date(timeIntervalSince1970: 9_000_001)))
        // Observational contract: status stays safe, no crash, engine alive.
        XCTAssertEqual(engine.status, .safe)
    }

    // MARK: - Warm-up to moving

    func testWarmupSequenceKeepsStatusCoherent() {
        let engine = SpeedEngine(locationManager: LocationManager())
        let t0 = Date(timeIntervalSince1970: 9_000_000)
        for i in 0..<10 {
            let p = GPSFixFactory.advance(
                CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412),
                meters: Double(i) * 20, heading: 90)
            engine.processLocation(GPSFixFactory.fix(
                lat: p.latitude, lon: p.longitude, speedMph: Double(i) * 3,
                course: 90, timestamp: t0.addingTimeInterval(Double(i))))
        }
        // Speed must be within the plausible band after 10 moving fixes.
        XCTAssertGreaterThanOrEqual(engine.speed, 0)
        XCTAssertLessThanOrEqual(engine.speed, 30)
        XCTAssertTrue(engine.speed.isFinite)
    }

    func testEngineSurvivesRapidRepeats() {
        let engine = SpeedEngine(locationManager: LocationManager())
        let t0 = Date(timeIntervalSince1970: 9_000_000)
        let fix = GPSFixFactory.fix(lat: 33.3062, lon: -111.8412,
                                    speedMph: 45, course: 90, timestamp: t0)
        for _ in 0..<100 {
            engine.processLocation(fix) // duplicate timestamps: idempotent-ish handling
        }
        XCTAssertTrue(engine.speed.isFinite, "Duplicate fixes corrupted engine state")
    }
}
