import XCTest
@testable import SmartSpeedCompanion

/// Regression coverage for driver map panning on CarPlay: the CPMapTemplate
/// panning interface (crosshair + directional arrows + Done) must drive the
/// MKMapView installed in the CPWindow, ALL automatic camera work must stand
/// down while the driver pans, and dismissing the interface must recenter on
/// the vehicle (user tracking back on, navigation animator resumed).
final class CarPlayMapPanningTests: XCTestCase {

    // MARK: - Delegate wiring

    func testRootTemplateImplementsPanningDelegateCallbacks() throws {
        let source = try String(contentsOfFile: rootTemplateSourcePath(), encoding: .utf8)
        // Entry point gate + lifecycle (suspend/resume automatic camera).
        XCTAssertTrue(
            source.contains("mapTemplateShouldShowPanningInterface"),
            "The template must gate the panning interface (parked cars don't need panning chrome)."
        )
        XCTAssertTrue(
            source.contains("mapTemplateDidShowPanningInterface"),
            "Showing the interface must suspend automatic camera work."
        )
        XCTAssertTrue(
            source.contains("mapTemplateDidDismissPanningInterface"),
            "Dismissing the interface must recenter the map."
        )
        // The four movement channels: live drag, begin/end pan (head units
        // that deliver discrete gestures), directional arrows, pinch zoom.
        XCTAssertTrue(
            source.contains("didUpdatePanGestureWithTranslation"),
            "Live panning must translate the dragged camera."
        )
        XCTAssertTrue(
            source.contains("panBeganWith") && source.contains("panEndedWith"),
            "Begin/end pan callbacks must be handled for head units that deliver discrete gestures."
        )
        XCTAssertTrue(
            source.contains("panWith direction: CPMapTemplate.PanDirection"),
            "The panning chrome's directional arrows must pan the map."
        )
        XCTAssertTrue(
            source.contains("didUpdateZoomGestureWithCenter"),
            "Pinch zoom from newer head units must scale the camera."
        )
        // The callbacks reach the MKMapView through the handed-over controller.
        XCTAssertTrue(
            source.contains("weak var mapController: CarPlayMapController?"),
            "The root template must hold the scene's map controller (weak; legacy no-window path stays nil-safe)."
        )
        // Consistent with the file's established nonisolated + MainActor-hop
        // pattern for CPMapTemplateDelegate callbacks.
        XCTAssertTrue(
            source.contains("nonisolated func mapTemplateShouldShowPanningInterface"),
            "Pan callbacks follow the nonisolated delegate pattern."
        )
    }

    // MARK: - Camera suspension + movement

    func testMapControllerSuspendsCameraAndMovesOnlyWhilePanning() throws {
        let source = try String(contentsOfFile: mapControllerSourcePath(), encoding: .utf8)
        // Panning flag participates in the camera gate.
        let cameraBody = try sourceSection(in: source, anchor: "private func updateNavigationCamera()")
        XCTAssertTrue(
            cameraBody.contains("!isPanningInterfaceActive"),
            "The navigation camera animator must stand down while the panning interface is visible, or it would yank the map back mid-pan."
        )
        // Panning lifecycle flips MapKit user tracking (the free-drive follow
        // camera) off and back on.
        let panningBody = try sourceSection(in: source, anchor: "func setPanningInterfaceActive(")
        XCTAssertTrue(
            panningBody.contains(".none") && panningBody.contains(".follow"),
            "Panning must disable user tracking; dismissal must restore it (recenter)."
        )
        // Drag + arrows + zoom all gate on the active flag so no stray event
        // moves the map when the interface is down.
        for (anchor, marker) in [("func pan(by translation: CGPoint)", "guard isPanningInterfaceActive"),
                                 ("func pan(in direction: CPMapTemplatePanDirection)", "guard isPanningInterfaceActive"),
                                 ("func zoom(by factor: Double)", "guard isPanningInterfaceActive")] {
            let body = try sourceSection(in: source, anchor: anchor)
            XCTAssertTrue(body.contains(marker), "\(anchor) must no-op when the panning interface is down.")
        }
        // Zoom is clamped so mashing the buttons can't divide by zero or fly
        // the camera to orbital altitude.
        let zoomBody = try sourceSection(in: source, anchor: "func zoom(by factor: Double)")
        XCTAssertTrue(zoomBody.contains("min(max("), "Zoom must clamp camera distance to sane street/region scales.")
    }

    // MARK: - Scene wiring

    func testSceneDelegateHandsMapControllerToRootTemplate() throws {
        let source = try String(contentsOfFile: sceneDelegateSourcePath(), encoding: .utf8)
        XCTAssertTrue(
            source.contains("root.mapController = carPlayMapController"),
            "The scene delegate must hand the MKMapView controller to the root template so pan callbacks can drive it."
        )
    }

    // MARK: - Helpers

    private func sourceSection(in source: String, anchor: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else {
            XCTFail("Missing expected source anchor: \(anchor)")
            return ""
        }
        let body = source[anchorRange.lowerBound...]
        guard let endRange = body.range(of: "\n    }") else {
            XCTFail("Could not locate the end of the section for anchor: \(anchor)")
            return ""
        }
        return String(body[..<endRange.lowerBound])
    }

    private func rootTemplateSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayNavigationRootTemplate.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayNavigationRootTemplate.swift"
        #endif
    }

    private func mapControllerSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayMapController.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayMapController.swift"
        #endif
    }

    private func sceneDelegateSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlaySceneDelegate.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlaySceneDelegate.swift"
        #endif
    }
}
