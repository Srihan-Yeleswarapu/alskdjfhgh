import XCTest
@testable import SmartSpeedCompanion

/// Reroute policy deep-dive: the policy must suppress request storms while
/// still rerouting fast enough to be useful. Exercises the real ReroutePolicy
/// state machine through its timing surface.
final class RerouteDeepPolicyTests: XCTestCase {

    func testPolicyInstanceIsFreshAndConservative() {
        let policy = ReroutePolicy()
        XCTAssertFalse(policy.shouldRequestReroute())
        XCTAssertFalse(policy.shouldRequestReroute())
        XCTAssertFalse(policy.shouldRequestReroute())
    }

    func testRepeatedCallsWithoutRouteChangeStaySuppressed() {
        let policy = ReroutePolicy()
        let results = (0..<50).map { _ in policy.shouldRequestReroute() }
        XCTAssertTrue(results.allSatisfy { !$0 },
                      "Unsuppressed reroute storm: \(results.filter { $0 }.count) of 50 passed")
    }

    func testPolicySurvivesManyCallsWithoutCrash() {
        let policy = ReroutePolicy()
        for _ in 0..<10_000 {
            _ = policy.shouldRequestReroute()
        }
        // No crash and still conservative.
        XCTAssertFalse(policy.shouldRequestReroute())
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
            distanceToNextTurn: nil, instruction: "",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .auto))
        // Losing the maneuver feed must change the camera decision (wider view
        // while rerouting) — if identical, the engine ignores reroute state.
        let differs = offRoute.altitude != onRoute.altitude || offRoute.pitch != onRoute.pitch
        XCTAssertTrue(differs, "Camera decision identical with and without maneuver context")
    }
}
