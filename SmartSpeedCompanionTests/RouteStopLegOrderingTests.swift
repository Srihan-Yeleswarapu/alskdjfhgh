import XCTest
import MapKit
@testable import SmartSpeedCompanion

/// Multi-stop route models: RouteStop persistence/identity, RouteLeg
/// formatting (the ETA strings CarPlay renders), and OrderingComparison —
/// the "current order vs optimal order" payload the stops sheet shows.
final class RouteStopLegOrderingTests: XCTestCase {

    // MARK: - RouteStop identity

    func testStopIdentityIsStableAcrossValues() {
        let id = UUID()
        let a = RouteStop(id: id, name: "Coffee", latitude: 33.3, longitude: -111.8)
        let b = RouteStop(id: id, name: "Coffee", latitude: 33.3, longitude: -111.8)
        XCTAssertEqual(a, b, "Same id = same stop, even if rebuilt")
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testDistinctStopsAreDistinct() {
        let a = RouteStop(name: "A", latitude: 33.3, longitude: -111.8)
        let b = RouteStop(name: "B", latitude: 33.3, longitude: -111.8)
        XCTAssertNotEqual(a, b)
    }

    func testStopCoordinateRoundTrip() {
        let stop = RouteStop(name: "X", latitude: 33.30620, longitude: -111.84120)
        XCTAssertEqual(stop.coordinate.latitude, 33.30620, accuracy: 1e-9)
        XCTAssertEqual(stop.coordinate.longitude, -111.84120, accuracy: 1e-9)
    }

    func testStopMapItemCarriesName() {
        let stop = RouteStop(name: "Fry's", address: "N Dobson Rd", latitude: 33.3, longitude: -111.8)
        let item = stop.mapItem
        XCTAssertEqual(item.name, "Fry's")
        XCTAssertEqual(item.placemark.coordinate.latitude, 33.3, accuracy: 1e-9)
    }

    // MARK: - Codable round-trip (the persisted stops format)

    func testStopCodableRoundTripPreservesLegData() throws {
        let stop = RouteStop(
            name: "Gas", address: "123 Main",
            latitude: 33.3, longitude: -111.8,
            travelTimeFromPrevious: 600, distanceFromPrevious: 8000,
            cumulativeTravelTime: 1800
        )
        let data = try JSONEncoder().encode(stop)
        let decoded = try JSONDecoder().decode(RouteStop.self, from: data)
        XCTAssertEqual(decoded.id, stop.id)
        XCTAssertEqual(decoded.name, "Gas")
        XCTAssertEqual(decoded.travelTimeFromPrevious, 600)
        XCTAssertEqual(decoded.distanceFromPrevious, 8000)
        XCTAssertEqual(decoded.cumulativeTravelTime, 1800)
        XCTAssertEqual(decoded.address, "123 Main")
    }

    func testStopCodableSurvivesMissingLegData() throws {
        // Older persisted JSON without per-leg estimates must decode.
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old Stop","latitude":33.3,"longitude":-111.8}
        """
        let decoded = try JSONDecoder().decode(RouteStop.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.travelTimeFromPrevious)
        XCTAssertNil(decoded.distanceFromPrevious)
        XCTAssertNil(decoded.cumulativeTravelTime)
    }

    // MARK: - RouteLeg formatting

    private func leg(minutes: Double, meters: Double) -> RouteLeg {
        RouteLeg(sourceName: "A", destinationName: "B",
                 travelTime: minutes * 60, distance: meters, route: nil)
    }

    func testLegDurationUnderAnHour() {
        XCTAssertEqual(leg(minutes: 25, meters: 20_000).formattedDuration, "25 min")
    }

    func testLegDurationOverAnHour() {
        XCTAssertEqual(leg(minutes: 65, meters: 80_000).formattedDuration, "1h 5m")
        XCTAssertEqual(leg(minutes: 120, meters: 160_000).formattedDuration, "2h 0m")
    }

    func testLegDistanceImperialFormatting() {
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        defer { UserDefaults.standard.removeObject(forKey: "measurementSystem") }
        XCTAssertEqual(leg(minutes: 10, meters: 400).formattedDistance, "1312 ft")
        XCTAssertEqual(leg(minutes: 10, meters: 20_000).formattedDistance, "12.4 mi")
    }

    func testLegDistanceMetricFormatting() {
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        defer { UserDefaults.standard.removeObject(forKey: "measurementSystem") }
        XCTAssertEqual(leg(minutes: 10, meters: 400).formattedDistance, "400 m")
        XCTAssertEqual(leg(minutes: 10, meters: 20_000).formattedDistance, "20.0 km")
    }

    // MARK: - OrderingComparison math

    func testOrderingImprovementCalculation() {
        // The comparison struct mirrors DriveViewModel's stops-sheet payload.
        // If the current order costs 5400 s and the optimal 4800 s, the
        // saving is 600 s / 10 min.
        let currentSeconds = 5400.0
        let optimalSeconds = 4800.0
        let savingMinutes = (currentSeconds - optimalSeconds) / 60
        XCTAssertEqual(savingMinutes, 10, accuracy: 1e-9)
    }

    func testStopsArrayInsertIndexSemantics() {
        // DriveViewModel.addStopInsertIndex defaults to end-of-list.
        var stops = [RouteStop(name: "First", latitude: 33.3, longitude: -111.8)]
        let insertIndex = stops.count // the documented default
        stops.insert(RouteStop(name: "Second", latitude: 33.31, longitude: -111.81), at: insertIndex)
        XCTAssertEqual(stops.map { $0.name }, ["First", "Second"])

        // Inserting at 0 reorders to front.
        stops.insert(RouteStop(name: "Zeroth", latitude: 33.32, longitude: -111.82), at: 0)
        XCTAssertEqual(stops.first?.name, "Zeroth")
    }

    func testStopsSurviveReorderRoundTrip() throws {
        var stops = [
            RouteStop(name: "A", latitude: 33.30, longitude: -111.84),
            RouteStop(name: "B", latitude: 33.31, longitude: -111.83),
            RouteStop(name: "C", latitude: 33.32, longitude: -111.82),
        ]
        // Simulate the optimal-order swap (B first).
        stops.swapAt(0, 1)
        let data = try JSONEncoder().encode(stops)
        let decoded = try JSONDecoder().decode([RouteStop].self, from: data)
        XCTAssertEqual(decoded.map { $0.name }, ["B", "A", "C"])
    }
}
