import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Geographic primitives every subsystem leans on: the mph conversion in
/// CLLocation+Speed, GPSFixFactory's advance math (must match the providers'
/// flat-earth approximation), distance sanity at real latitudes, and
/// CLLocation course semantics (the -1 invalid sentinel).
final class CLLocationExtensionAndGeoTests: XCTestCase {

    // MARK: - mph conversion

    func testSpeedInMphConversion() {
        let fix = GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 60)
        assertMph(fix.speedInMph, equals: 60.0)
    }

    func testSpeedInMphClampsNegativeToZero() {
        let fix = GPSFixFactory.speedlessFix() // speed = -1
        XCTAssertEqual(fix.speedInMph, 0, "Invalid speed must clamp to 0 mph, never go negative")
    }

    func testZeroSpeedIsZeroMph() {
        let fix = GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 0)
        XCTAssertEqual(fix.speedInMph, 0)
    }

    // MARK: - Advance math consistency

    func testAdvanceNorthIncreasesLatitudeOnly() {
        let c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let advanced = GPSFixFactory.advance(c, meters: 100, heading: 0)
        XCTAssertEqual(advanced.longitude, c.longitude, accuracy: 1e-12)
        XCTAssertGreaterThan(advanced.latitude, c.latitude)
        let dist = CLLocation(latitude: c.latitude, longitude: c.longitude)
            .distance(from: CLLocation(latitude: advanced.latitude, longitude: advanced.longitude))
        XCTAssertEqual(dist, 100, accuracy: 0.5)
    }

    func testAdvanceEastIncreasesLongitudeOnly() {
        let c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let advanced = GPSFixFactory.advance(c, meters: 100, heading: 90)
        XCTAssertEqual(advanced.latitude, c.latitude, accuracy: 1e-12)
        XCTAssertGreaterThan(advanced.longitude, c.longitude)
    }

    func testAdvanceDiagonalIsPythagorean() {
        let c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let advanced = GPSFixFactory.advance(c, meters: 100, heading: 45)
        let dLat = (advanced.latitude - c.latitude) * 111_111
        let dLon = (advanced.longitude - c.longitude) * 111_111 * cos(c.latitude * .pi / 180)
        XCTAssertEqual((dLat * dLat + dLon * dLon).squareRoot(), 100, accuracy: 0.5,
                       "45° advance must decompose into equal N/E components")
        XCTAssertEqual(dLat, dLon, accuracy: 0.5)
    }

    func testAdvanceDistanceAccuracyAcrossCardinalPoints() {
        let c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        for heading in [0.0, 45, 90, 135, 180, 225, 270, 315] {
            let advanced = GPSFixFactory.advance(c, meters: 250, heading: heading)
            let dist = CLLocation(latitude: c.latitude, longitude: c.longitude)
                .distance(from: CLLocation(latitude: advanced.latitude, longitude: advanced.longitude))
            XCTAssertEqual(dist, 250, accuracy: 1.0, "Heading \(heading) drifted")
        }
    }

    func testLongitudinalContractionAtHighLatitude() {
        // At 60°N, one degree of longitude is half as long as at the
        // equator — the cos(latitude) correction must reflect that.
        let equator = GPSFixFactory.advance(CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                            meters: 1000, heading: 90)
        let north = GPSFixFactory.advance(CLLocationCoordinate2D(latitude: 60, longitude: 0),
                                          meters: 1000, heading: 90)
        let equatorSpan = equator.longitude
        let northSpan = north.longitude
        XCTAssertEqual(abs(northSpan) / abs(equatorSpan), 0.5, accuracy: 0.02,
                       "Longitude span at 60°N must be half the equatorial span")
    }

    // MARK: - Distance semantics

    func testCLLocationDistanceMatchesFactoryAdvance() {
        let c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let advanced = GPSFixFactory.advance(c, meters: 80, heading: 90)
        let from = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let to = CLLocation(latitude: advanced.latitude, longitude: advanced.longitude)
        XCTAssertEqual(from.distance(from: to), 80, accuracy: 0.5,
                       "GPSFixFactory and CLLocation must agree — the throttle logic mixes both")
    }

    func testZeroDistanceSelf() {
        let c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let a = CLLocation(latitude: c.latitude, longitude: c.longitude)
        XCTAssertEqual(a.distance(from: a), 0, accuracy: 1e-9)
    }

    // MARK: - Course sentinel semantics

    func testInvalidCourseSentinel() {
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 33.3, longitude: -111.8),
                             altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: -1, speed: 10, timestamp: Date())
        XCTAssertEqual(fix.course, -1, "CLLocationDirection invalid sentinel is -1")
        XCTAssertFalse(fix.course >= 0)
    }

    func testValidCourseRoundTrip() {
        let fix = GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 30, course: 271)
        XCTAssertEqual(fix.course, 271, accuracy: 0.001)
    }

    // MARK: - mph↔m/s round trips (the unit the engine consumes)

    func testMphToMsToMphRoundTrip() {
        for mph in stride(from: 5, through: 100, by: 5) {
            let ms = mph * GPSFixFactory.mphToMs
            let back = ms * 2.23694
            assertMph(back, equals: Double(mph), "Round trip \(mph) mph drifted")
        }
    }

    func testStandardConversionConstants() {
        XCTAssertEqual(GPSFixFactory.mphToMs * 2.23694, 1.0, accuracy: 1e-12)
        // 1 mph = 0.44704 m/s exactly.
        XCTAssertEqual(GPSFixFactory.mphToMs, 0.44704, accuracy: 1e-9)
    }

    // MARK: - GeoCorpus integrity (fixture-level)

    func testGeoCorpusSegmentsAreDistinct() {
        let keys = GeoCorpus.segments.map { "\($0.roadName)|\($0.latitude)|\($0.longitude)" }
        XCTAssertEqual(Set(keys).count, keys.count, "Corpus segments must not collide")
    }

    func testGeoCorpusHasBothDirectionsAndRoadClasses() {
        let directions = Set(GeoCorpus.segments.map { $0.direction })
        XCTAssertTrue(directions.contains("E") && directions.contains("W"))
        let roads = Set(GeoCorpus.segments.map { $0.roadName })
        XCTAssertTrue(roads.contains("SR-101"), "Need the highway class")
        XCTAssertTrue(roads.contains { $0.contains("Corpus Ave") }, "Need the arterial class")
    }

    func testGeoCorpusLimitsArePlausible() {
        for segment in GeoCorpus.segments {
            XCTAssertTrue((20...70).contains(segment.limitMph), segment.roadName)
        }
    }

    func testArterialDriveProducesEvenlySpacedEastwardFixes() {
        let fixes = GeoCorpus.arterialDrive(fixes: 8)
        XCTAssertEqual(fixes.count, 8)
        for (prev, next) in zip(fixes, fixes.dropFirst()) {
            let d = prev.distance(from: next)
            XCTAssertEqual(d, 30, accuracy: 0.5, "Drive fixes must be 30 m apart")
            XCTAssertGreaterThan(next.coordinate.longitude, prev.coordinate.longitude)
        }
        // Timestamps advance 1 s per fix.
        for (prev, next) in zip(fixes, fixes.dropFirst()) {
            XCTAssertEqual(next.timestamp.timeIntervalSince(prev.timestamp), 1.0, accuracy: 1e-9)
        }
    }
}
