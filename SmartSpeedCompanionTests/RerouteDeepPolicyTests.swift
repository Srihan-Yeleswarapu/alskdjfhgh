import XCTest
@testable import SmartSpeedCompanion

/// Reroute policy deep-dive: the coordinator's reroute machinery must stay
/// stable under the off-route camera decision paths. The historical
/// standalone ReroutePolicy class was folded into NavigationCoordinator's
/// generation/timer state; the camera cross-check below still pins that
/// losing the maneuver feed changes the camera decision.
@MainActor
final class RerouteDeepPolicyTests: XCTestCase {

    func testCoordinatorStartsConservativeWithoutOffRouteEvents() {
        let coordinator = NavigationCoordinator()
        XCTAssertFalse(coordinator.isRerouting,
                       "A fresh coordinator must never be mid-reroute")
    }

    // MARK: - Cross-check with CameraDecisionEngine nav context

    func testOffRouteContextChangesCameraBehavior() {
        let onRoute = CameraDecisionEngine.computeTarget(from: CameraContext(
            speed: 40, speedLimit: 45, isNavigating: true, isRecording: false,
            distanceToNextTurn: 250, instruction: "Turn",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .auto))
        let offRoute = CameraDecisionEngine.computeTarget(from: CameraContext(
            speed: 40, speedLimit: 45, isNavigating: true, isRecording: false,
            distanceToNextTurn: 0, instruction: "",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .auto))
        // Losing the maneuver feed must change the camera decision (wider view
        // while rerouting) — if identical, the engine ignores reroute state.
        let differs = offRoute.altitude != onRoute.altitude || offRoute.pitch != onRoute.pitch
        XCTAssertTrue(differs, "Camera decision identical with and without maneuver context")
    }
}
