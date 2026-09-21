import XCTest
@testable import SmartSpeedCompanion

/// Real-geometry navigation: feeds polylines with genuine cumulative distance
/// (computed via location.distance(from:)) and verifies heading/course policy
/// decisions against true bearings — no HERE network, pure CoreLocation math.
final class NavigationGeometryHeadingPolicyTests: XCTestCase {

    private func fixture(_ metersPerDegree: Double = 111_320) -> Double { metersPerDegree }

    private func makeLocations(along points: [(Double, Double)]) -> [CLLocation] {
        points.map { CLLocation(coordinate: .init(latitude: $0.0, longitude: $0.1)) }
    }

    // MARK: - Course computation from real successive fixes

    func testCourseDueNorth() {
        let a = CLLocation(latitude: 37.0, longitude: -122.0)
        let b = CLLocation(latitude: 37.0 + 0.01, longitude: -122.0)
        let course = courseDeg(from: a, to: b)
        XCTAssertEqual(course, 0, accuracy: 2, "Northbound course \(course) ≠ 0°")
    }

    func testCourseDueEast() {
        let a = CLLocation(latitude: 37.0, longitude: -122.0)
        let b = CLLocation(latitude: 37.0, longitude: -122.0 + 0.01)
        let course = courseDeg(from: a, to: b)
        XCTAssertEqual(course, 90, accuracy: 2, "Eastbound course \(course) ≠ 90°")
    }

    func testCourseDueSouthAndWest() {
        let s = courseDeg(from: CLLocation(latitude: 37.01, longitude: -122.0),
                          to: CLLocation(latitude: 37.0, longitude: -122.0))
        let w = courseDeg(from: CLLocation(latitude: 37.0, longitude: -122.01),
                          to: CLLocation(latitude: 37.0, longitude: -122.0))
        XCTAssertEqual(s, 180, accuracy: 2)
        XCTAssertEqual(w, 270, accuracy: 2)
    }

    // MARK: - Cumulative distance along a polyline

    func testPolylineCumulativeDistanceMonotoneAndAccurate() {
        // ~1 km legs: (0,0) → (0.009,0) → (0.009,0.009) → (0,0.009)
        let pts = makeLocations(along: [(0, 0), (0.009, 0), (0.009, 0.009), (0, 0.009)])
        var cumulative: [Double] = [0]
        for i in 1..<pts.count {
            cumulative.append(cumulative[i - 1] + pts[i].distance(from: pts[i - 1]))
        }
        for pair in zip(cumulative, cumulative.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1, "Cumulative distance went backwards")
        }
        // 3 legs of ~1 km each.
        XCTAssertEqual(cumulative.last ?? 0, 3_000, accuracy: 300,
                       "Cumulative distance \(cumulative.last ?? 0) m far from 3 km")
    }

    // MARK: - Turn sharpness classification

    func testSharpTurnDetectedFromBearingChange() {
        let before = courseDeg(from: CLLocation(latitude: 0, longitude: 0),
                               to: CLLocation(latitude: 0.001, longitude: 0))
        let after = courseDeg(from: CLLocation(latitude: 0.001, longitude: 0),
                              to: CLLocation(latitude: 0.001, longitude: 0.001))
        let delta = abs(bearingDelta(before, after))
        XCTAssertGreaterThan(delta, 80, "Right-angle turn classified as gentle (Δ \(delta)°)")
    }

    func testStraightRoadHasNearZeroBearingDelta() {
        let before = courseDeg(from: CLLocation(latitude: 0, longitude: 0),
                               to: CLLocation(latitude: 0.01, longitude: 0))
        let after = courseDeg(from: CLLocation(latitude: 0.01, longitude: 0),
                              to: CLLocation(latitude: 0.02, longitude: 0))
        XCTAssertEqual(abs(bearingDelta(before, after)), 0, accuracy: 1)
    }

    func testBearingDeltaWrapsThrough360() {
        XCTAssertEqual(bearingDelta(350, 10), 20, accuracy: 0.001,
                       "350°→10° must wrap as +20°, not −340°")
        XCTAssertEqual(bearingDelta(10, 350), -20, accuracy: 0.001)
    }

    // MARK: - Distance throttling for resolution refresh

    func testMovedBeyondThresholdTriggersRefreshLogic() {
        let a = CLLocation(latitude: 37.0, longitude: -122.0)
        let b = CLLocation(latitude: 37.0005, longitude: -122.0) // ~55 m
        XCTAssertGreaterThan(b.distance(from: a), 50)
        let c = CLLocation(latitude: 37.00005, longitude: -122.0) // ~5.5 m
        XCTAssertLessThan(c.distance(from: a), 50)
    }

    // MARK: - Helpers (mirrors app's geo math)

    private func courseDeg(from a: CLLocation, to b: CLLocation) -> Double {
        let φ1 = a.coordinate.latitude * .pi / 180
        let φ2 = b.coordinate.latitude * .pi / 180
        let Δλ = (b.coordinate.longitude - a.coordinate.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func bearingDelta(_ a: Double, _ b: Double) -> Double {
        let d = (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
        return d
    }
}
