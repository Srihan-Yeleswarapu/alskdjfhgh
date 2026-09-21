import XCTest
import MapKit
@testable import SmartSpeedCompanion

/// Map tracking usability: the camera write governor (5 writes/sec cap —
/// the map-strobe fix), tracking-mode policy per drive state, and the
/// heading gates that keep the map from fighting MapKit's own animations.
final class CameraTrackingModeUsabilityTests: XCTestCase {

    // MARK: - Tracking mode policy

    func testRecordingOnlyIsPlainFollow() {
        XCTAssertEqual(LiveMapView.trackingMode(isNavigating: false), .follow)
    }

    func testNavigationNeverUsesCompassFollow() {
        // The b640 regression: .followWithHeading dislodged by camera writes
        // leaves the map north-up while the beam points up.
        for navigating in [true, false] {
            XCTAssertNotEqual(LiveMapView.trackingMode(isNavigating: navigating), .followWithHeading)
        }
        XCTAssertEqual(LiveMapView.trackingMode(isNavigating: true), .follow)
    }

    // MARK: - Write governor cadence

    func testGovernorCapsToFiveWritesPerSecond() {
        let governor = CameraWriteGovernor(minimumWriteInterval: 0.2)
        // 200 ms interval = 5 Hz max.
        var lastWrite: TimeInterval? = nil
        var writes = 0
        var clock = 0.0
        for _ in 0..<100 { // simulate 2 s at 50 Hz
            clock += 0.02
            let since = lastWrite.map { clock - $0 }
            if governor.shouldWrite(timeSinceLastWrite: since, altitudeDelta: 5, pitchDelta: 0) {
                writes += 1
                lastWrite = clock
            }
        }
        XCTAssertLessThanOrEqual(writes, 11, "2 s must yield ≤ 10–11 writes at the 5 Hz cap, got \(writes)")
        XCTAssertGreaterThanOrEqual(writes, 8, "The cap must not starve smooth gliding")
    }

    func testGovernorDeniesSettledState() {
        let governor = CameraWriteGovernor()
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: 5.0, altitudeDelta: 0.1, pitchDelta: 0))
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: 5.0, altitudeDelta: 0, pitchDelta: 0.05))
    }

    func testGovernorRespectsHeadingDelta() {
        let governor = CameraWriteGovernor()
        XCTAssertTrue(governor.shouldWrite(timeSinceLastWrite: nil, altitudeDelta: 0, pitchDelta: 0, headingDelta: 3))
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: nil, altitudeDelta: 0, pitchDelta: 0, headingDelta: 0.3))
    }

    func testPerWriteStepBoundedByRateCap() {
        // At the 200 ms cadence each write must move at most cap×0.2.
        for (current, target) in [(320.0, 2800.0), (2800.0, 320.0), (1100.0, 400.0)] {
            let next = CameraKinematics.approach(
                current: current, target: target, dt: 0.2,
                tightenTau: 1.2, releaseTau: 1.8,
                rateCapPerSecond: 85, snapEpsilon: 0.75)
            XCTAssertLessThanOrEqual(abs(next - current), 85 * 0.2 + 0.01,
                                     "Step from \(current)→\(target) exceeded the per-write bound")
        }
    }

    // MARK: - Heading rotation usability

    func testRotationTakesShortestArc() {
        // 350°→10° must rotate +20°, not −340°.
        let next = CameraMath.rotatingApproach(current: 350, target: 10, maxDelta: 30)
        XCTAssertEqual(next, 10, accuracy: 0.001)
    }

    func testRotationRespectsMaxDelta() {
        for maxDelta in [5.0, 15.0, 45.0] {
            let next = CameraMath.rotatingApproach(current: 0, target: 180, maxDelta: maxDelta)
            XCTAssertEqual(CameraMath.angularDistance(next - 0), maxDelta, accuracy: 0.001,
                           "Rotation must step exactly maxDelta toward the target")
        }
    }

    func testRotationNeverOvershootsTarget() {
        let next = CameraMath.rotatingApproach(current: 0, target: 20, maxDelta: 90)
        XCTAssertEqual(next, 20, accuracy: 0.001, "Small targets must snap, not overshoot")
    }

    func testNormalizedHeadingAlwaysInRange() {
        for degrees in stride(from: -1080.0, through: 1080.0, by: 7) {
            let normalized = CameraMath.normalizedHeading(degrees)
            XCTAssertTrue((0..<360).contains(normalized), "\(degrees) normalized to \(normalized)")
        }
    }

    func testAngularDistanceSignedAndShortest() {
        XCTAssertEqual(CameraMath.angularDistance(370), 10, accuracy: 0.0001)
        XCTAssertEqual(CameraMath.angularDistance(-370), -10, accuracy: 0.0001)
        XCTAssertEqual(CameraMath.angularDistance(180), 180, accuracy: 0.0001)
        XCTAssertEqual(CameraMath.angularDistance(181), -179, accuracy: 0.0001)
    }

    // MARK: - Course ownership (who rotates the map)

    func testCourseOwnershipPolicy() {
        // CarPlay passes course explicitly; the iPhone passes vehicleCourse
        // in the context only during navigation. MapKit keeps heading when
        // nil. Verified through CameraContextCourseTests' scenarios here:
        let navigating = CameraContext(
            speed: 30, speedLimit: 40, isNavigating: true, isRecording: true,
            distanceToNextTurn: 500, instruction: "Turn",
            maneuverImageName: "", destinationDistance: 5000,
            hasRoute: true, userPitchOverride: .auto, vehicleCourse: 271)
        XCTAssertEqual(navigating.vehicleCourse, 271)

        let freeDrive = CameraContext(
            speed: 30, speedLimit: 40, isNavigating: false, isRecording: true,
            distanceToNextTurn: 0, instruction: "", maneuverImageName: "",
            destinationDistance: 0, hasRoute: false, userPitchOverride: .auto)
        XCTAssertNil(freeDrive.vehicleCourse)
    }
}
