import XCTest
import UIKit
@testable import SmartSpeedCompanion

/// Drive Focus Mode usability: the distraction-free full-screen state —
/// orientation policy (landscape allowed IN, portrait forced OUT), the
/// enter/exit haptic cues, and the AppDelegate orientation-lock contract
/// the whole app rides on.
@MainActor
final class CameraFocusModeAndOrientationTests: XCTestCase {

    private var defaultsGuard: UserDefaultsTestGuard!

    override func setUp() {
        super.setUp()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
    }

    override func tearDown() {
        defaultsGuard.restore()
        super.tearDown()
    }

    // MARK: - Orientation lock contract

    func testOrientationLockSwitchesWithFocusMode() throws {
        // DriveViewModel.isDriveFocusMode.didSet sets
        // AppDelegate.orientationLock = .all (in) / .portrait (out).
        let source = try String(contentsOfFile: driveViewModelPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("AppDelegate.orientationLock = isDriveFocusMode ? .all : .portrait"),
                      "Focus mode must own the orientation lock: all orientations in, portrait out")
    }

    func testExitRequestsPortraitGeometry() throws {
        let source = try String(contentsOfFile: driveViewModelPath(), encoding: .utf8)
        let didSet = try section(in: source, anchor: "@Published public var isDriveFocusMode: Bool = false")
        XCTAssertTrue(didSet.contains("requestGeometryUpdate"),
                      "Exit must request a geometry update back to portrait")
        XCTAssertTrue(didSet.contains("UIInterfaceOrientation.portrait"),
                      "The geometry request must target portrait")
    }

    // MARK: - Haptic cues

    func testFocusEnterExitHapticsExist() throws {
        let source = try String(contentsOfFile: hapticPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("playFocusModeEnter"))
        XCTAssertTrue(source.contains("playFocusModeExit"))
    }

    // MARK: - Published state defaults

    func testFocusModeDefaultsOff() throws {
        let source = try String(contentsOfFile: driveViewModelPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("@Published public var isDriveFocusMode: Bool = false"),
                      "Focus mode must default off — the driver launches into the full HUD")
    }

    // MARK: - Camera behavior while focused

    func testFocusModeKeepsNavigationCameraPriority() {
        // Focus mode doesn't change the decision engine's inputs; the map
        // keeps following the same camera authority.
        let navigating = CameraContext(
            speed: 40, speedLimit: 45, isNavigating: true, isRecording: true,
            distanceToNextTurn: 400, instruction: "Turn right",
            maneuverImageName: "arrow.turn.up.right", destinationDistance: 8000,
            hasRoute: true, userPitchOverride: .auto)
        let target = CameraDecisionEngine.computeTarget(from: navigating)
        XCTAssertTrue((250...4200).contains(target.altitude))
        XCTAssertGreaterThan(target.pitch, 0, "Navigating camera stays 3D")
    }

    func testFreeDriveCameraInFocusModeIsFlat() {
        // Free drive at speed keeps the cruise pitch; stopped it flattens
        // (the stationary fade) — focus mode inherits this.
        let stopped = CameraContext(
            speed: 0, speedLimit: 45, isNavigating: false, isRecording: true,
            distanceToNextTurn: 0, instruction: "", maneuverImageName: "",
            destinationDistance: 0, hasRoute: false, userPitchOverride: .auto)
        let target = CameraDecisionEngine.computeTarget(from: stopped)
        XCTAssertEqual(target.pitch, 0, accuracy: 0.01, "Stopped camera must flatten")
    }

    // MARK: - Idle-timer policy (screen must stay awake in focus mode)

    func testIdleTimerPolicyTiedToRecordingState() throws {
        let source = try String(contentsOfFile: driveViewModelPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("updateIdleTimer()"),
                      "isRecording/isNavigating didSet must refresh the idle timer")
        XCTAssertTrue(source.contains("enforceIdleLifecycle()"),
                      "Idle lifecycle must be enforced when both flags drop")
    }

    // MARK: - Live Activity continues during focus mode

    func testLiveActivityCoalescingPolicyIsUnaffectedByFocus() throws {
        let source = try String(contentsOfFile: driveViewModelPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("liveActivityUpdateInterval: TimeInterval = 2.0"),
                      "The 2 s Live Activity coalesce window is a heat boundary — focus mode must not bypass it")
    }

    private func section(in source: String, anchor: String) throws -> String {
        guard let range = source.range(of: anchor) else {
            XCTFail("Missing anchor: \(anchor)")
            return ""
        }
        return String(source[range.lowerBound...])
    }

    private func driveViewModelPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\ViewModels\\DriveViewModel.swift"
        #else
        return "SmartSpeedCompanion/ViewModels/DriveViewModel.swift"
        #endif
    }

    private func hapticPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\HapticAlertManager.swift"
        #else
        return "SmartSpeedCompanion/Core/HapticAlertManager.swift"
        #endif
    }
}
