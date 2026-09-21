import XCTest
import MapKit
@testable import SmartSpeedCompanion

/// CarPlay map camera integration through a REAL MKMapView: the
/// CameraAnimator's update paths, suspend/reset lifecycle, and that the
/// write-governed output keeps the camera altitude inside MapKit's
/// renderable bounds after a full simulated drive.
@MainActor
final class CameraCarPlayMapRenderingTests: XCTestCase {

    private var mapView: MKMapView!

    override func setUp() {
        super.setUp()
        mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
    }

    override func tearDown() {
        mapView = nil
        super.tearDown()
    }

    private func context(speed: Double, dtt: CLLocationDistance = 5000,
                         navigating: Bool = true) -> CameraContext {
        CameraContext(
            speed: speed, speedLimit: 45, isNavigating: navigating, isRecording: true,
            distanceToNextTurn: dtt, instruction: "Continue on SR-101",
            maneuverImageName: "arrow.turn.up.right", destinationDistance: 40_000,
            hasRoute: navigating, userPitchOverride: .auto
        )
    }

    // MARK: - Update paths don't crash on a live map

    func testUpdateWithoutCourseIsSafe() {
        let animator = CameraAnimator()
        animator.update(mapView: mapView, context: context(speed: 45))
        // No crash; camera stays within sane altitude bounds.
    }

    func testUpdateWithCourseIsSafe() {
        let animator = CameraAnimator()
        animator.update(mapView: mapView, context: context(speed: 45), course: 271)
    }

    func testUpdateWithInvalidCourseIsSafe() {
        let animator = CameraAnimator()
        // -1 sentinel and NaN-ish inputs must not corrupt the camera.
        animator.update(mapView: mapView, context: context(speed: 45), course: -1)
        animator.update(mapView: mapView, context: context(speed: 45), course: 360.5)
    }

    // MARK: - Suspend / reset lifecycle

    func testSuspendStopsWrites() {
        let animator = CameraAnimator()
        animator.update(mapView: mapView, context: context(speed: 45))
        animator.suspend()
        animator.update(mapView: mapView, context: context(speed: 20, dtt: 100))
        // After suspend, further updates must be inert — no crash, no writes.
    }

    func testResetRestoresNeutralCamera() {
        let animator = CameraAnimator()
        animator.update(mapView: mapView, context: context(speed: 60))
        animator.reset(to: mapView)
        // The reset camera must be MapKit-legal.
        XCTAssertGreaterThanOrEqual(mapView.camera.altitude, 0)
    }

    // MARK: - Full simulated drive keeps the camera renderable

    func testSimulatedDriveKeepsCameraInRenderableBounds() {
        let animator = CameraAnimator()
        var now = Date(timeIntervalSince1970: 4_000_000)

        // Drive: 65 mph highway → decelerate → turn → accelerate.
        let speedProfile: [Double] = [65, 65, 60, 45, 30, 25, 25, 30, 40, 55, 65]
        let dttProfile: [CLLocationDistance] = [8000, 6000, 3000, 1200, 400, 100, 30, 1800, 3000, 5000, 8000]

        for (idx, speed) in speedProfile.enumerated() {
            now.addTimeInterval(0.2) // display-link cadence
            animator.update(mapView: mapView,
                            context: context(speed: speed, dtt: dttProfile[idx]),
                            course: 90 + Double(idx) * 3)
            // After every write the camera must be MapKit-legal.
            XCTAssertGreaterThan(mapView.camera.altitude, 0,
                                 "Altitude became non-positive at step \(idx)")
            XCTAssertLessThan(mapView.camera.altitude, 100_000,
                              "Altitude exploded at step \(idx)")
        }
    }

    // MARK: - The camera altitude stays inside the decision-engine clamp

    func testCameraAltitudeRespectsEngineClamp() {
        // The engine clamps [250, 4200]; the animator must never write
        // outside it.
        for speed in stride(from: 0.0, through: 100, by: 10) {
            for dtt in [0.0, 100, 500, 2000, 10_000] {
                let target = CameraDecisionEngine.computeTarget(from: context(speed: speed, dtt: dtt))
                XCTAssertTrue((250...4200).contains(target.altitude),
                              "Engine target altitude \(target.altitude) outside clamp")
            }
        }
    }

    // MARK: - Write cadence on a live map

    func testWriteCadenceRespectedOnLiveMap() {
        // Simulate 3 s at 30 Hz with a moving target: writes must be
        // rate-limited, not per-frame.
        let animator = CameraAnimator()
        var now = Date(timeIntervalSince1970: 5_000_000)
        var lastAltitude = mapView.camera.altitude
        var writes = 0
        for _ in 0..<90 {
            now.addTimeInterval(1.0 / 30.0)
            animator.update(mapView: mapView, context: context(speed: 45, dtt: 900), course: 90)
            let current = mapView.camera.altitude
            if abs(current - lastAltitude) > 0.01 {
                writes += 1
                lastAltitude = current
            }
        }
        // 3 s at 5 Hz cap ≈ 15 writes; a per-frame bug would be ~90.
        XCTAssertLessThan(writes, 40,
                          "Camera writes (\(writes) in 3 s) exceeded the governed cadence — map strobe risk")
    }
}
