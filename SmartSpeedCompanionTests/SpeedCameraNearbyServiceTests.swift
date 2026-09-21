import XCTest
@testable import SmartSpeedCompanion

/// Speed camera model & nearby filtering: AZ511 wire decode (Capitalized
/// CodingKeys) and the `getNearbyCameras` radius filter the HUD uses to
/// warn "camera ahead". The network fetch itself is environment-bound; the
/// decode and filter math are not, and both drive safety-relevant UI.
@MainActor
final class SpeedCameraNearbyServiceTests: XCTestCase {

    // MARK: - Wire decode (AZ511 shape)

    func testCameraDecodesAZ511WireFormat() throws {
        let json = """
        [{"Id": 42, "Source": "az511", "SourceId": "AZ-042",
          "Roadway": "I-10", "Direction": "E",
          "Latitude": 33.4501, "Longitude": -112.0667,
          "Location": "Near 7th St", "SortOrder": 3}]
        """.data(using: .utf8)!
        let cameras = try JSONDecoder().decode([SpeedCamera].self, from: json)
        XCTAssertEqual(cameras.count, 1)
        let c = cameras[0]
        XCTAssertEqual(c.id, 42)
        XCTAssertEqual(c.roadway, "I-10")
        XCTAssertEqual(c.direction, "E")
        XCTAssertEqual(c.latitude, 33.4501, accuracy: 1e-9)
        XCTAssertEqual(c.location, "Near 7th St")
        XCTAssertEqual(c.sortOrder, 3)
    }

    func testCameraDecodeToleratesNullOptionalFields() throws {
        let json = """
        [{"Id": 7, "Latitude": 33.0, "Longitude": -112.0}]
        """.data(using: .utf8)!
        let cameras = try JSONDecoder().decode([SpeedCamera].self, from: json)
        XCTAssertEqual(cameras.count, 1)
        XCTAssertNil(cameras[0].roadway)
        XCTAssertNil(cameras[0].direction)
    }

    func testCameraIdIsMandatory() {
        // "Id" is non-optional; a row without it must fail decode loudly
        // rather than insert an unidentifiable camera.
        let json = """
        [{"Latitude": 33.0, "Longitude": -112.0}]
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode([SpeedCamera].self, from: json),
                             "Row without Id decoded — camera dedup would break")
    }

    func testCameraCoordinateAccessor() throws {
        let json = """
        [{"Id": 1, "Latitude": 33.45, "Longitude": -112.07}]
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode([SpeedCamera].self, from: json)[0]
        XCTAssertEqual(c.coordinate.latitude, 33.45, accuracy: 1e-9)
        XCTAssertEqual(c.coordinate.longitude, -112.07, accuracy: 1e-9)
    }

    // MARK: - Nearby filtering (real service, seeded locally)

    func testNearbyFilterRespectsRadius() {
        let service = SpeedCameraService.shared
        service.cameras = [
            SpeedCamera(id: 1, source: nil, sourceId: nil, roadway: "I-10",
                        direction: "E", latitude: 33.4500, longitude: -112.0600,
                        location: nil, sortOrder: nil),
            SpeedCamera(id: 2, source: nil, sourceId: nil, roadway: "SR-51",
                        direction: "N", latitude: 33.5200, longitude: -112.0600,
                        location: nil, sortOrder: nil) // ~7.8 km north
        ]
        let here = CLLocation(latitude: 33.4500, longitude: -112.0600)
        let within5km = service.getNearbyCameras(to: here, radiusInMeters: 5_000)
        XCTAssertEqual(within5km.map { $0.id }, [1], "Radius filter leaked a 7.8 km camera")
        let within10km = service.getNearbyCameras(to: here, radiusInMeters: 10_000)
        XCTAssertEqual(Set(within10km.map { $0.id }), [1, 2])
    }

    func testNearbyFilterOnEmptyListIsSafe() {
        let service = SpeedCameraService.shared
        let saved = service.cameras
        service.cameras = []
        let result = service.getNearbyCameras(
            to: CLLocation(latitude: 33.45, longitude: -112.06))
        XCTAssertTrue(result.isEmpty)
        service.cameras = saved
    }

    func testBoundaryCameraAtExactRadiusExcludedNotCrash() {
        // A camera at ~exactly the radius: inclusive/exclusive is fine, a
        // crash or duplicate is not.
        let service = SpeedCameraService.shared
        service.cameras = [
            SpeedCamera(id: 9, source: nil, sourceId: nil, roadway: nil,
                        direction: nil, latitude: 33.4500 + 0.0045, // ~500 m north
                        longitude: -112.0600, location: nil, sortOrder: nil)
        ]
        let result = service.getNearbyCameras(
            to: CLLocation(latitude: 33.4500, longitude: -112.0600),
            radiusInMeters: 500)
        XCTAssertTrue(result.count <= 1)
        service.cameras = []
    }

    // MARK: - Bulk decode (a statewide feed is ~1k rows)

    func testBulkDecode1000Rows() throws {
        var rows: [String] = []
        for i in 0..<1_000 {
            rows.append("""
            {"Id": \(i), "Roadway": "R\(i % 40)", "Latitude": \(33 + Double(i % 100) / 100), "Longitude": \(-112 + Double(i % 80) / 100)}
            """)
        }
        let json = ("[" + rows.joined(separator: ",") + "]").data(using: .utf8)!
        let cameras = try JSONDecoder().decode([SpeedCamera].self, from: json)
        XCTAssertEqual(cameras.count, 1_000)
        // IDs unique — the HUD keys dedup on them.
        XCTAssertEqual(Set(cameras.map { $0.id }).count, 1_000)
    }

    override func tearDown() {
        SpeedCameraService.shared.cameras = []
        super.tearDown()
    }
}
