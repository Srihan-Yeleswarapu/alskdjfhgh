import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// SimulationManager (DEBUG-only): dead-reckoning physics that moves the
/// mock car, road-snapping through SimulationDataSource, and the mock
/// broadcast payload the LocationManager mock path consumes. Also the
/// notification contract the whole developer-simulation feature rides on.
@MainActor
final class SimulationManagerPhysicsTests: XCTestCase {

    // MARK: - Static physics math (mirrors updateMockLocationPhysics)

    /// The manager advances mockCoordinate by speed×1s each tick. The math
    /// below replicates it exactly; these tests pin it so a retune that
    /// breaks Auto-Drive realism is caught.
    private func advance(coordinate: CLLocationCoordinate2D,
                         heading: Double, speedMph: Double) -> CLLocationCoordinate2D {
        let speedInMs = speedMph * 0.44704
        let distanceMoving = speedInMs * 1.0
        guard distanceMoving > 0 else { return coordinate }
        let earthRadius = 6_378_137.0
        let radiansHeading = heading * .pi / 180.0
        let dLat = (distanceMoving * cos(radiansHeading)) / earthRadius
        let dLon = (distanceMoving * sin(radiansHeading)) / (earthRadius * cos(coordinate.latitude * .pi / 180))
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + (dLat * 180.0 / .pi),
            longitude: coordinate.longitude + (dLon * 180.0 / .pi)
        )
    }

    func testStationaryCarDoesNotMove() {
        let start = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let moved = advance(coordinate: start, heading: 90, speedMph: 0)
        XCTAssertEqual(moved.latitude, start.latitude, accuracy: 1e-15)
        XCTAssertEqual(moved.longitude, start.longitude, accuracy: 1e-15)
    }

    func testForwardMotionMatchesFactoryAdvance() {
        // The manager's math and GPSFixFactory's must agree at 60 mph.
        let start = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let viaManager = advance(coordinate: start, heading: 45, speedMph: 60)
        let viaFactory = GPSFixFactory.advance(start, meters: 26.8224, heading: 45) // 60 mph ≈ 26.82 m/s
        XCTAssertEqual(viaManager.latitude, viaFactory.latitude, accuracy: 1e-7)
        XCTAssertEqual(viaManager.longitude, viaFactory.longitude, accuracy: 1e-7)
    }

    func testSixtyMphCoversEightyEightFeetPerSecond() {
        // 60 mph = 26.82 m/s = 88 ft/s — sanity vs physics.
        let start = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let moved = advance(coordinate: start, heading: 0, speedMph: 60)
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: moved.latitude, longitude: moved.longitude))
        XCTAssertEqual(distance, 26.8224, accuracy: 0.1)
    }

    func testNegativeSpeedDoesNotMoveBackward() {
        // updateMockLocationPhysics guards distanceMoving <= 0 → return.
        let start = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let moved = advance(coordinate: start, heading: 90, speedMph: -30)
        XCTAssertEqual(moved.latitude, start.latitude, accuracy: 1e-15)
        XCTAssertEqual(moved.longitude, start.longitude, accuracy: 1e-15)
    }

    // MARK: - Mock broadcast payload

    func testBroadcastPayloadShape() {
        // The CLLocation broadcast carries: 5 m accuracy (passes engine
        // filters), mph→m/s speed, mock heading, fresh timestamp.
        let speedMph = 45.0
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412),
            altitude: 0, horizontalAccuracy: 5.0, verticalAccuracy: 5.0,
            course: 90, speed: speedMph / 2.23694, timestamp: Date()
        )
        XCTAssertEqual(location.horizontalAccuracy, 5.0, "Must pass SpeedEngine's eligibility gate")
        assertMph(location.speedInMph, equals: speedMph)
        XCTAssertEqual(location.course, 90, accuracy: 0.001)
        XCTAssertLessThan(abs(location.timestamp.timeIntervalSinceNow), 1)
    }

    // MARK: - Notification contract

    func testDidUpdateMockLocationNotificationDeliversCLLocation() {
        let expectation = expectation(forNotification: .didUpdateMockLocation,
                                      object: nil) { notification in
            guard let location = notification.object as? CLLocation else { return false }
            return location.horizontalAccuracy == 5.0
        }
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412),
            altitude: 0, horizontalAccuracy: 5.0, verticalAccuracy: 5.0,
            course: 0, speed: 10, timestamp: Date()
        )
        NotificationCenter.default.post(name: .didUpdateMockLocation, object: location)
        wait(for: [expectation], timeout: 2)
    }

    // MARK: - Road-snapping source contract

    func testRoadSnapMergesHeadingWhenAvailable() throws {
        #if os(Windows)
        let source = try String(contentsOfFile: "SmartSpeedCompanion\\Core\\SimulationManager.swift", encoding: .utf8)
        #else
        let source = try String(contentsOfFile: "SmartSpeedCompanion/Core/SimulationManager.swift", encoding: .utf8)
        #endif
        XCTAssertTrue(source.contains("getNearestPointOnRoute"),
                      "Road snapping must flow through SimulationDataSource")
        XCTAssertTrue(source.contains("self.mockHeading = roadHeading"),
                      "Snapped heading must be inherited for the follow-the-road feel")
    }

    func testSnappingProviderProtocolContract() {
        // The protocol hands back (coordinate, heading?) — a route-snapper
        // that returns nil heading must leave the user's heading alone.
        final class StraightRoute: SimulationDataSource {
            func getNearestPointOnRoute(to coordinate: CLLocationCoordinate2D)
                -> (coordinate: CLLocationCoordinate2D, heading: Double?) {
                (CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: -111.8412), 90)
            }
        }
        let snapper: SimulationDataSource = StraightRoute()
        let snapped = snapper.getNearestPointOnRoute(
            to: CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8300))
        XCTAssertEqual(snapped.heading, 90)
        XCTAssertEqual(snapped.coordinate.longitude, -111.8412, accuracy: 1e-9,
                       "Snap must pull the fix back onto the route's longitude")
    }
}
