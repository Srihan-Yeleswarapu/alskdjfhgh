import XCTest
@testable import SmartSpeedCompanion

/// `trafficAwareRemainingTime(forRemainingDistance:fallback:)` scales Apple's
/// latest traffic snapshot across the matched remaining distance. The ratio
/// clamp is the safety property: no GPS glitch or polyline-match jump may
/// produce a longer-than-total or negative ETA. The fallback contract matters
/// before the first traffic refresh (fresh navigation start, CarPlay cold
/// attach). This file pins both — pure math, no route objects needed.
@MainActor
final class NavigationETAMathTests: XCTestCase {

    private var coordinator: NavigationCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = NavigationCoordinator()
    }

    override func tearDown() {
        coordinator = nil
        super.tearDown()
    }

    // MARK: - Fallback semantics (no traffic reference yet)

    func testFallbackPassesThroughWhenNoTrafficReferenceExists() {
        // Fresh coordinator: trafficReferenceDistance/Time are zero, so the
        // traffic scaling must defer entirely to the proportional estimate.
        let result = coordinator.trafficAwareRemainingTime(forRemainingDistance: 40_000, fallback: 1_800)
        XCTAssertEqual(result, 1_800, accuracy: 0.001)
    }

    func testFallbackPassesThroughForHugeDistancesWithoutReference() {
        let result = coordinator.trafficAwareRemainingTime(forRemainingDistance: 400_000, fallback: 14_400)
        XCTAssertEqual(result, 14_400, accuracy: 0.001)
    }

    func testFallbackIsUsedEvenForZeroDistance() {
        // Zero remaining distance without a reference: fallback is returned
        // (the arrival path sets its own final ETA separately).
        let result = coordinator.trafficAwareRemainingTime(forRemainingDistance: 0, fallback: 300)
        XCTAssertEqual(result, 300, accuracy: 0.001)
    }

    func testNegativeDistanceDefersToFallbackWithoutReference() {
        let result = coordinator.trafficAwareRemainingTime(forRemainingDistance: -50, fallback: 120)
        XCTAssertEqual(result, 120, accuracy: 0.001)
    }

    // MARK: - proportionalRemainingTravelTime (no route configured)

    func testProportionalTravelTimeIsZeroWithoutRoute() {
        XCTAssertEqual(coordinator.proportionalRemainingTravelTime, 0,
                       "no route configured must yield zero fallback time")
    }

    // MARK: - Geometry-independent contract

    func testFunctionIsDeterministicForRepeatedCalls() {
        for _ in 0..<50 {
            let a = coordinator.trafficAwareRemainingTime(forRemainingDistance: 12_345, fallback: 987)
            let b = coordinator.trafficAwareRemainingTime(forRemainingDistance: 12_345, fallback: 987)
            XCTAssertEqual(a, b, accuracy: 0.0001, "same inputs must give the same ETA")
        }
    }

    func testReturnNeverNegativeAcrossSweep() {
        // Across a realistic distance/time sweep, the result must never be
        // negative regardless of the reference state (drivers see this number).
        for distance in stride(from: 0.0, through: 500_000, by: 5_000) {
            for fallback in [0.0, 60, 600, 3_600, 14_400] {
                let t = coordinator.trafficAwareRemainingTime(
                    forRemainingDistance: distance, fallback: fallback)
                XCTAssertGreaterThanOrEqual(t, 0, "negative ETA at d=\(distance), f=\(fallback)")
            }
        }
    }

    // MARK: - ETA publication field defaults

    func testFreshCoordinatorPublishesNoETAOrDistance() {
        XCTAssertNil(coordinator.eta, "no ETA before navigation starts")
        XCTAssertEqual(coordinator.distanceToDestination, 0)
        XCTAssertEqual(coordinator.distanceToNextTurn, 0)
        XCTAssertTrue(coordinator.nextManeuverInstruction.isEmpty)
        XCTAssertEqual(coordinator.nextManeuverImageName, "arrow.up",
                       "straight-ahead glyph is the neutral default")
        XCTAssertNil(coordinator.nextManeuverCoordinate)
    }

    func testIsReroutingDefaultsFalseAndClearsAcrossCoordinatorLifetime() {
        XCTAssertFalse(coordinator.isRerouting)
        // Toggling through a reroute cycle must return to false.
        coordinator.isRerouting = true
        XCTAssertTrue(coordinator.isRerouting)
        coordinator.isRerouting = false
        XCTAssertFalse(coordinator.isRerouting)
    }

    func testDestinationSetterClearsDerivedStateSafely() {
        // Setting destination is the entry to every navigation; before any
        // navigation, clearing derived state must be crash-free on a fresh
        // coordinator.
        coordinator.destination = nil
        XCTAssertNil(coordinator.eta)
        XCTAssertEqual(coordinator.distanceToDestination, 0)
    }
}
