import XCTest
import MapKit
@testable import SmartSpeedCompanion

/// MapPitchMode (the 2D/3D pill) and MapStyleChoice (the Settings picker):
/// small UI-adjacent enums, but the pitch sentinel (−1 = "auto decides")
/// silently clamps the camera to a phantom angle if mishandled, and the
/// style catalog drives MKMapConfiguration selection on every map.
@MainActor
final class MapPitchModeAndStyleTests: XCTestCase {

    // MARK: - Pitch targets

    func testPitchTargetValues() {
        XCTAssertEqual(DriveViewModel.MapPitchMode.auto.targetPitch, -1, "auto uses the −1 sentinel")
        XCTAssertEqual(DriveViewModel.MapPitchMode.forced2D.targetPitch, 0)
        XCTAssertEqual(DriveViewModel.MapPitchMode.forced3D.targetPitch, 45)
    }

    func testAutoSentinelMustBeTreatedAsNoOp() {
        // Consumers MUST branch on targetPitch < 0 — a clamp would produce
        // pitch −1° which MapKit rejects or renders flat.
        let auto = DriveViewModel.MapPitchMode.auto
        XCTAssertLessThan(auto.targetPitch, 0, "Callers branch on this")
        // The other two are real angles.
        XCTAssertGreaterThanOrEqual(DriveViewModel.MapPitchMode.forced2D.targetPitch, 0)
        XCTAssertGreaterThanOrEqual(DriveViewModel.MapPitchMode.forced3D.targetPitch, 0)
    }

    func testShortLabels() {
        XCTAssertEqual(DriveViewModel.MapPitchMode.auto.shortLabel, "AUTO")
        XCTAssertEqual(DriveViewModel.MapPitchMode.forced2D.shortLabel, "2D")
        XCTAssertEqual(DriveViewModel.MapPitchMode.forced3D.shortLabel, "3D")
    }

    func testPitchModeCyclesThroughAllCases() {
        // The pill toggle cycles auto → 2D → 3D → auto.
        let all = DriveViewModel.MapPitchMode.allCases
        XCTAssertEqual(all, [.auto, .forced2D, .forced3D])
        XCTAssertEqual(all.count, 3)
    }

    func testPitchModeIdentifiableStability() {
        for mode in DriveViewModel.MapPitchMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    // MARK: - Map style catalog

    func testMapStyleCatalog() {
        let all = DriveViewModel.MapStyleChoice.allCases
        XCTAssertEqual(all, [.mutedDark, .standard, .satellite, .hybridFlyover])
    }

    func testMapStyleDisplayNames() {
        XCTAssertEqual(DriveViewModel.MapStyleChoice.mutedDark.displayName, "Muted (Dark)")
        XCTAssertEqual(DriveViewModel.MapStyleChoice.standard.displayName, "Standard")
        XCTAssertEqual(DriveViewModel.MapStyleChoice.satellite.displayName, "Satellite")
        XCTAssertEqual(DriveViewModel.MapStyleChoice.hybridFlyover.displayName, "Hybrid 3D")
    }

    func testMapStyleRawValuesPersistRoundTrip() {
        for style in DriveViewModel.MapStyleChoice.allCases {
            XCTAssertEqual(DriveViewModel.MapStyleChoice(rawValue: style.rawValue), style)
        }
    }

    // MARK: - Decision-engine integration with pitch overrides

    func testForced2DZeroesPitchButKeepsAltitudeLogic() {
        let context = CameraContext(
            speed: 60, speedLimit: 65, isNavigating: true, isRecording: true,
            distanceToNextTurn: 100, instruction: "Turn left",
            maneuverImageName: "arrow.turn.up.left", destinationDistance: 2000,
            hasRoute: true, userPitchOverride: .forced2D
        )
        let target = CameraDecisionEngine.computeTarget(from: context)
        XCTAssertEqual(target.pitch, 0, "Forced 2D must hard-zero pitch")
        // Altitude still runs its maneuver logic.
        XCTAssertGreaterThan(target.altitude, 250, "Altitude must stay above the hard floor")
    }

    func testForced3DPinsPitchFortyFive() {
        let context = CameraContext(
            speed: 15, speedLimit: 30, isNavigating: false, isRecording: true,
            distanceToNextTurn: 0, instruction: "", maneuverImageName: "",
            destinationDistance: 0, hasRoute: false, userPitchOverride: .forced3D
        )
        let target = CameraDecisionEngine.computeTarget(from: context)
        XCTAssertEqual(target.pitch, 45, "Forced 3D pins 45° over every other logic")
    }

    func testAutoModeFadesStationaryPitch() {
        // At 0 mph with auto pitch, the Hermite fade drives pitch to 0.
        let stopped = CameraContext(
            speed: 0, speedLimit: 45, isNavigating: false, isRecording: true,
            distanceToNextTurn: 0, instruction: "", maneuverImageName: "",
            destinationDistance: 0, hasRoute: false, userPitchOverride: .auto
        )
        let target = CameraDecisionEngine.computeTarget(from: stopped)
        XCTAssertEqual(target.pitch, 0, accuracy: 0.001, "Stationary fade must flatten pitch")
    }

    func testAutoModeKeepsPitchWhileMoving() {
        let moving = CameraContext(
            speed: 40, speedLimit: 45, isNavigating: false, isRecording: true,
            distanceToNextTurn: 0, instruction: "", maneuverImageName: "",
            destinationDistance: 0, hasRoute: false, userPitchOverride: .auto
        )
        let target = CameraDecisionEngine.computeTarget(from: moving)
        XCTAssertGreaterThan(target.pitch, 20, "Cruise pitch for 40 mph must stay 3D-ish")
    }
}
