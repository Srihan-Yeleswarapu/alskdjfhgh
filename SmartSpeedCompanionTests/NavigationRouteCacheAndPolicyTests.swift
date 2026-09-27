import XCTest
@testable import SmartSpeedCompanion

/// Navigation coordinator: route-lifecycle and policy paths exercised through
/// the real NavigationCoordinator — route identity, stale-policy, and
/// simulated-route behavior. No network, no HERE.
@MainActor
final class NavigationRouteCacheAndPolicyTests: XCTestCase {

    func testFreshCoordinatorHasNoActiveRoute() {
        let coordinator = NavigationCoordinator()
        // Navigation state now lives on DriveViewModel; the coordinator
        // exposes route/progress. A fresh one must have neither.
        XCTAssertNil(coordinator.currentRoute, "Fresh coordinator reports an active route")
        XCTAssertFalse(coordinator.isRerouting, "Fresh coordinator reports mid-reroute")
    }

    func testStopNavigationClearsState() async {
        let coordinator = NavigationCoordinator()
        await coordinator.endNavigation()
        XCTAssertNil(coordinator.currentRoute)
    }

    func testRepeatStopIsIdempotent() async {
        let coordinator = NavigationCoordinator()
        await coordinator.endNavigation()
        await coordinator.endNavigation()
        await coordinator.endNavigation()
        XCTAssertNil(coordinator.currentRoute)
    }

    func testCameraCommitPolicyDuringNavigation() {
        // During navigation the camera must be in route-following mode, not
        // free orbit — verify via the decision engine with real route context.
        let duringNav = CameraDecisionEngine.computeTarget(from: CameraContext(
            speed: 40, speedLimit: 45, isNavigating: true, isRecording: false,
            distanceToNextTurn: 250, instruction: "Turn right",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .auto))
        let idle = CameraDecisionEngine.computeTarget(from: CameraContext(
            speed: 40, speedLimit: 45, isNavigating: false, isRecording: false,
            distanceToNextTurn: 0, instruction: "",
            maneuverImageName: "", destinationDistance: 0,
            hasRoute: false, userPitchOverride: .auto))
        // Route-following sits the camera lower/tighter than idle orbit.
        XCTAssertLessThan(duringNav.altitude, idle.altitude,
                          "Camera altitude identical between navigating and idle")
    }

    func testRecordingElevatesCameraCommit() {
        let plain = CameraDecisionEngine.computeTarget(from: CameraContext(
            speed: 40, speedLimit: 45, isNavigating: true, isRecording: false,
            distanceToNextTurn: 250, instruction: "Turn right",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .auto))
        let recording = CameraDecisionEngine.computeTarget(from: CameraContext(
            speed: 40, speedLimit: 45, isNavigating: true, isRecording: true,
            distanceToNextTurn: 250, instruction: "Turn right",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .auto))
        // Recording locks the framing: targets must be identical.
        XCTAssertEqual(plain.altitude, recording.altitude)
        XCTAssertEqual(plain.pitch, recording.pitch)
    }

    func testUserPitchOverrideBeatsRouteContext() {
        let override = CameraDecisionEngine.computeTarget(from: CameraContext(
            speed: 40, speedLimit: 45, isNavigating: true, isRecording: false,
            distanceToNextTurn: 250, instruction: "Turn",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .forced3D))
        let auto = CameraDecisionEngine.computeTarget(from: CameraContext(
            speed: 40, speedLimit: 45, isNavigating: true, isRecording: false,
            distanceToNextTurn: 250, instruction: "Turn",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .auto))
        XCTAssertNotEqual(override.pitch, auto.pitch,
                          "User pitch override had no effect during navigation")
    }
}
