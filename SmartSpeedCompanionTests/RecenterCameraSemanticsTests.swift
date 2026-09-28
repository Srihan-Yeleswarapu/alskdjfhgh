import XCTest
import MapKit
@testable import SmartSpeedCompanion

/// FB: "When I click Re-center, it doesn't mean zoom out. It means put my
/// location in the center."
///
/// `CameraAnimator.restoreCamera` used to compute the speed-based target
/// altitude and snap the map to it on every reattach/re-center — an
/// unrequested zoom the driver read as "re-center = zoom out". It also hopped
/// tracking `.follow → .none → .follow` around the write, letting MapKit's
/// tracking camera race and displace the just-written center.
///
/// The new contract: re-center changes the CENTER ONLY. The user's current
/// altitude/pitch are preserved as the animator's new baseline, and no
/// tracking-mode flip ever occurs.
@MainActor
final class RecenterCameraSemanticsTests: XCTestCase {

    private func makeContext(speed: Double = 30, navigating: Bool = false) -> CameraContext {
        CameraContext(
            speed: speed,
            speedLimit: 55,
            isNavigating: navigating,
            isRecording: false,
            distanceToNextTurn: 0,
            instruction: "",
            maneuverImageName: "",
            destinationDistance: 0,
            hasRoute: navigating,
            userPitchOverride: .auto
        )
    }

    private func makeMapView(center: CLLocationCoordinate2D, altitude: Double) -> MKMapView {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let camera = map.camera.copy() as! MKMapCamera
        camera.centerCoordinate = center
        camera.centerCoordinateDistance = altitude
        map.camera = camera
        return map
    }

    func testRecenterPreservesUserZoomInsteadOfSnappingToSpeedTarget() {
        // User zoomed out to a 4 km viewing altitude and taps Re-center.
        // The map must RE-CENTER at 4 km — the old code snapped to the
        // cruise target (~1 km at 30 mph), which was the zoom-out feel.
        let userCenter = CLLocationCoordinate2D(latitude: 33.44, longitude: -112.07)
        let farAway = CLLocationCoordinate2D(latitude: 33.50, longitude: -112.15)
        let map = makeMapView(center: farAway, altitude: 4000)
        map.userTrackingMode = .none
        let animator = CameraAnimator()

        animator.restoreCamera(on: map, context: makeContext(speed: 30), centerCoordinate: userCenter)

        XCTAssertEqual(map.camera.centerCoordinateDistance, 4000, accuracy: 1.0,
                       "Re-center must preserve the user's current zoom; the speed-based altitude is NOT the re-center target.")
        XCTAssertEqual(map.camera.centerCoordinate.latitude, userCenter.latitude, accuracy: 0.0005,
                       "Re-center must put the requested coordinate at the map center.")
        XCTAssertEqual(map.camera.centerCoordinate.longitude, userCenter.longitude, accuracy: 0.0005)
    }

    func testRecenterInNavigationAlsoPreservesZoom() {
        // Same contract during guidance: the animator's target applies
        // through its own gradual glide afterwards, never as a restore snap.
        let userCenter = CLLocationCoordinate2D(latitude: 33.44, longitude: -112.07)
        let map = makeMapView(center: CLLocationCoordinate2D(latitude: 33.50, longitude: -112.15), altitude: 2500)
        map.userTrackingMode = .none
        let animator = CameraAnimator()

        animator.restoreCamera(on: map, context: makeContext(speed: 60, navigating: true), centerCoordinate: userCenter)

        XCTAssertEqual(map.camera.centerCoordinateDistance, 2500, accuracy: 1.0,
                       "Re-center during navigation must also preserve the user's zoom.")
        XCTAssertEqual(map.camera.centerCoordinate.latitude, userCenter.latitude, accuracy: 0.0005)
    }

    func testRecenterNeverFlipsTrackingMode() {
        // The old follow → none → follow hop let MapKit's tracking camera
        // race the restore write and displace the center. Tracking must be
        // left exactly as found.
        let map = makeMapView(center: CLLocationCoordinate2D(latitude: 33.44, longitude: -112.07), altitude: 1000)
        map.userTrackingMode = .follow
        let animator = CameraAnimator()

        animator.restoreCamera(on: map, context: makeContext(), centerCoordinate: CLLocationCoordinate2D(latitude: 33.45, longitude: -112.08))

        XCTAssertEqual(map.userTrackingMode, .follow,
                       "restoreCamera must never flip the tracking mode around its write.")
    }

    func testBaselineResumesFromUserZoomAfterRecenter() {
        // After a re-center, the animator's smoothing baseline must equal the
        // preserved user altitude, so the next altitude glide starts FROM the
        // user's zoom rather than ramping from the old speed target.
        let userCenter = CLLocationCoordinate2D(latitude: 33.44, longitude: -112.07)
        let map = makeMapView(center: userCenter, altitude: 4000)
        map.userTrackingMode = .none
        let animator = CameraAnimator()

        animator.restoreCamera(on: map, context: makeContext(speed: 30), centerCoordinate: userCenter)

        // Seeding is internal; verify via observable behavior: a fresh
        // update() against a steady context must not produce a large first
        // write. Suppress window delays the first write by ~1/30 s, so drive
        // several ticks through the suspension window.
        var lastAltitude = map.camera.centerCoordinateDistance
        for _ in 0..<10 {
            let runloop = RunLoop.current
            let deadline = Date().addingTimeInterval(0.05)
            while Date() < deadline { runloop.run(until: deadline) }
            animator.update(mapView: map, context: makeContext(speed: 30))
            lastAltitude = map.camera.centerCoordinateDistance
        }
        XCTAssertEqual(lastAltitude, 4000, accuracy: 600,
                       "With a steady context the first ticks after re-center must stay near the user's zoom (no snap toward the cruise altitude).")
    }
}
