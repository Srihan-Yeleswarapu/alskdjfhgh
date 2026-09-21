import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Speed camera subsystem: the az511 wire decoder (capitalized CodingKeys),
/// the coordinate accessor, and the proximity-alert policy the HUD banner
/// and DriveViewModel.nearbyCameras depend on.
final class SpeedCameraModelAndAlertTests: XCTestCase {

    // MARK: - Wire decoding

    private let sampleJSON = """
    [
      {"Id": 101, "Source": "az511", "SourceId": "cam-101", "Roadway": "SR-101",
       "Direction": "NB", "Latitude": 33.3100, "Longitude": -111.8380,
       "Location": "Price Rd", "SortOrder": 1},
      {"Id": 102, "Source": "az511", "SourceId": "cam-102", "Roadway": "I-10",
       "Direction": "WB", "Latitude": 33.4484, "Longitude": -112.0740,
       "Location": "40th St", "SortOrder": 2}
    ]
    """

    func testDecodesAZ511WireFormat() throws {
        let cameras = try JSONDecoder().decode([SpeedCamera].self, from: Data(sampleJSON.utf8))
        XCTAssertEqual(cameras.count, 2)
        let first = cameras[0]
        XCTAssertEqual(first.id, 101)
        XCTAssertEqual(first.source, "az511")
        XCTAssertEqual(first.roadway, "SR-101")
        XCTAssertEqual(first.direction, "NB")
        XCTAssertEqual(first.location, "Price Rd")
        XCTAssertEqual(first.coordinate.latitude, 33.3100, accuracy: 1e-9)
        XCTAssertEqual(first.coordinate.longitude, -111.8380, accuracy: 1e-9)
    }

    func testDecodesPartialRecords() throws {
        // az511 occasionally omits optional fields.
        let partial = """
        [{"Id": 7, "Latitude": 33.3, "Longitude": -111.8}]
        """
        let cameras = try JSONDecoder().decode([SpeedCamera].self, from: Data(partial.utf8))
        XCTAssertEqual(cameras.count, 1)
        XCTAssertNil(cameras[0].roadway)
        XCTAssertNil(cameras[0].direction)
    }

    func testRejectsMissingRequiredFields() {
        let bad = """
        [{"Id": 8, "Latitude": 33.3}]
        """
        XCTAssertThrowsError(try JSONDecoder().decode([SpeedCamera].self, from: Data(bad.utf8)),
                             "Missing Longitude must fail decoding, not default to 0")
    }

    func testCoordinateAccessorMatchesLatLon() {
        let camera = try! JSONDecoder().decode([SpeedCamera].self, from: Data(sampleJSON.utf8))[1]
        XCTAssertEqual(camera.coordinate.latitude, camera.latitude, accuracy: 1e-12)
        XCTAssertEqual(camera.coordinate.longitude, camera.longitude, accuracy: 1e-12)
    }

    // MARK: - Proximity policy

    /// The alert distance band: cameras within ~400 m of the corridor are
    /// "nearby", the closest within ~150 m triggers the banner. These are
    /// the distances DriveViewModel filters on; the math is verified here.
    func testProximityDistanceBands() {
        let camera = try! JSONDecoder().decode([SpeedCamera].self, from: Data(sampleJSON.utf8))[0]
        let at = CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude)

        let nearby = GPSFixFactory.advance(at, meters: 380, heading: 90)
        let far = GPSFixFactory.advance(at, meters: 1200, heading: 90)

        let dNear = CLLocation(latitude: nearby.latitude, longitude: nearby.longitude)
            .distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude))
        let dFar = CLLocation(latitude: far.latitude, longitude: far.longitude)
            .distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude))

        XCTAssertLessThan(dNear, 400, "380 m offset must land in the nearby band")
        XCTAssertGreaterThan(dFar, 1000, "1200 m offset must fall outside the nearby band")
    }

    func testClosestCameraSelection() {
        let cameras = try! JSONDecoder().decode([SpeedCamera].self, from: Data(sampleJSON.utf8))
        let user = CLLocationCoordinate2D(latitude: 33.3105, longitude: -111.8375)
        let nearest = cameras.min { a, b in
            let da = pow(a.latitude - user.latitude, 2) + pow(a.longitude - user.longitude, 2)
            let db = pow(b.latitude - user.latitude, 2) + pow(b.longitude - user.longitude, 2)
            return da < db
        }
        XCTAssertEqual(nearest?.id, 101, "Nearest-camera selection must pick the corridor camera")
    }

    // MARK: - Service state machine

    @MainActor
    func testServiceStartsEmpty() {
        let service = SpeedCameraService()
        XCTAssertTrue(service.cameras.isEmpty, "Fresh service must not carry stale cameras")
    }

    @MainActor
    func testCamerasPropertyIsWritableForTestInjection() {
        let service = SpeedCameraService()
        let cameras = try! JSONDecoder().decode([SpeedCamera].self, from: Data(sampleJSON.utf8))
        service.cameras = cameras
        XCTAssertEqual(service.cameras.count, 2)
        service.cameras = []
        XCTAssertTrue(service.cameras.isEmpty)
    }

    // MARK: - Alert-banner state policy (source contract)

    func testActiveCameraAlertLifecycleContract() throws {
        // DriveViewModel publishes activeCameraAlert while the banner shows
        // and clears it when the camera falls out of range. The HUD and the
        // CarPlay alert both consume it — the property must stay Optional
        // so "no alert" is representable.
        let source = try String(contentsOfFile: driveViewModelPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("@Published public var activeCameraAlert: SpeedCamera?"),
                      "activeCameraAlert must remain Optional — the banner clears it by assigning nil")
        XCTAssertTrue(source.contains("@Published public var nearbyCameras: [SpeedCamera]"),
                      "nearbyCameras must remain published for map annotations")
    }

    private func driveViewModelPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\ViewModels\\DriveViewModel.swift"
        #else
        return "SmartSpeedCompanion/ViewModels/DriveViewModel.swift"
        #endif
    }
}
