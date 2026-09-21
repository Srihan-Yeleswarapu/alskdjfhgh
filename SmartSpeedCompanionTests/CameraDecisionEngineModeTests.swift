import XCTest
@testable import SmartSpeedCompanion

/// CameraDecisionEngine: mode classification and the altitude/pitch
/// outcomes each mode produces. Every scenario is a real drive moment —
/// parked, free-driving, approaching a turn, sharp turn, arriving.
final class CameraDecisionEngineModeTests: XCTestCase {

    private func context(speed: Double, dtt: CLLocationDistance,
                         destination: CLLocationDistance = 50_000,
                         navigating: Bool = true, hasRoute: Bool = true,
                         pitch: DriveViewModel.MapPitchMode = .auto) -> CameraContext {
        CameraContext(
            speed: speed, speedLimit: 45, isNavigating: navigating, isRecording: true,
            distanceToNextTurn: dtt, instruction: "Turn left onto W Frye Rd",
            maneuverImageName: "arrow.turn.up.left", destinationDistance: destination,
            hasRoute: hasRoute, userPitchOverride: pitch
        )
    }

    // MARK: - Mode classification

    func testStationaryClassifiesParked() {
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 0, dtt: 0, navigating: false)),
                       .parked)
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 2.9, dtt: 0, navigating: false)),
                       .parked, "Below 3 mph is stationary by contract")
    }

    func testFreeDriveWithoutNavigation() {
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 40, dtt: 0, navigating: false)),
                       .freeDrive)
    }

    func testNavigationDistanceBands() {
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 30, dtt: 60)), .sharpTurn,
                       "Inside 125 m: sharp turn")
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 30, dtt: 400)), .approachingTurn,
                       "125–700 m: approaching")
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 30, dtt: 2000)), .navigating)
    }

    func testDestinationArrivalBand() {
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 20, dtt: 900, destination: 100)),
                       .destinationArrival, "Inside 150 m of destination: arrival framing")
    }

    func testModeBoundaries() {
        // Exact band edges.
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 30, dtt: 125)), .approachingTurn)
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 30, dtt: 700)), .navigating)
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 20, dtt: 2000, destination: 150)), .destinationArrival)
        XCTAssertEqual(CameraDecisionEngine.classifyMode(context(speed: 20, dtt: 2000, destination: 151)), .navigating)
    }

    // MARK: - Altitude outcomes per scenario

    func testHighwayCruiseIsHighest() {
        let highway = CameraDecisionEngine.computeTarget(from: context(speed: 70, dtt: 30_000))
        let city = CameraDecisionEngine.computeTarget(from: context(speed: 25, dtt: 30_000))
        XCTAssertGreaterThan(highway.altitude, city.altitude)
    }

    func testNearTurnZoomsInDuringNavigation() {
        let far = CameraDecisionEngine.computeTarget(from: context(speed: 30, dtt: 900))
        let near = CameraDecisionEngine.computeTarget(from: context(speed: 30, dtt: 60))
        XCTAssertLessThan(near.altitude, far.altitude)
        XCTAssertLessThan(near.pitch, far.pitch, "Pitch flattens near the turn")
    }

    func testFreeDriveIgnoresTurnDistance() {
        // Without navigation, dtt is meaningless — altitude must equal the
        // plain cruise level.
        let far = CameraDecisionEngine.computeTarget(from: context(speed: 30, dtt: 5000, navigating: false, hasRoute: false))
        let near = CameraDecisionEngine.computeTarget(from: context(speed: 30, dtt: 50, navigating: false, hasRoute: false))
        XCTAssertEqual(far.altitude, near.altitude, accuracy: 0.001,
                       "Turn distance must not zoom a free-drive camera")
    }

    func testClampsHold() {
        // Extreme inputs: altitude clamps to [250, 4200], pitch to [0, 60].
        let extreme = CameraDecisionEngine.computeTarget(from: context(speed: 200, dtt: 0))
        XCTAssertGreaterThanOrEqual(extreme.altitude, 250)
        XCTAssertLessThanOrEqual(extreme.altitude, 4200)
        XCTAssertGreaterThanOrEqual(extreme.pitch, 0)
        XCTAssertLessThanOrEqual(extreme.pitch, 60)
    }

    func testArrivalZoomsTightest() {
        let arriving = CameraDecisionEngine.computeTarget(from: context(speed: 15, dtt: 2000, destination: 40))
        let cruising = CameraDecisionEngine.computeTarget(from: context(speed: 15, dtt: 2000, destination: 50_000))
        XCTAssertLessThan(arriving.altitude, cruising.altitude,
                          "Arrival framing must be tighter than cruise")
    }

    // MARK: - Determinism

    func testSameInputSameOutput() {
        let a = CameraDecisionEngine.computeTarget(from: context(speed: 45, dtt: 300))
        let b = CameraDecisionEngine.computeTarget(from: context(speed: 45, dtt: 300))
        XCTAssertEqual(a, b, "The decision engine must be a pure function")
    }

    func testTargetCameraStateEquatable() {
        let x = TargetCameraState(altitude: 500, pitch: 30)
        let y = TargetCameraState(altitude: 500, pitch: 30)
        XCTAssertEqual(x, y)
        XCTAssertNotEqual(x, TargetCameraState(altitude: 500, pitch: 31))
    }
}
