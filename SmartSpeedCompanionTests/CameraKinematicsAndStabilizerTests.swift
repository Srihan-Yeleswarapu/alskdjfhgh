import XCTest
@testable import SmartSpeedCompanion

/// CameraKinematics (frame-rate-independent approach) and CameraStabilizer
/// (the state owner feeding the animator). The display-link runs at 60–120
/// Hz on ProMotion; dt varies — the kinematics must be frame-rate invariant.
final class CameraKinematicsAndStabilizerTests: XCTestCase {

    private let timing = CameraTuning.fallback.timing

    // MARK: - Frame-rate invariance

    func testApproachIsFrameRateInvariant() {
        // 1 second of tightening at 30 fps vs 120 fps must travel the same
        // total distance (within integration error).
        func integrate(fps: Double) -> Double {
            var altitude = 3000.0
            let dt = 1.0 / fps
            for _ in 0..<Int(fps) {
                altitude = CameraKinematics.approach(
                    current: altitude, target: 1000, dt: dt,
                    tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
                    rateCapPerSecond: 100_000, snapEpsilon: 0.001)
            }
            return altitude
        }
        let at30 = integrate(fps: 30)
        let at120 = integrate(fps: 120)
        XCTAssertEqual(at30, at120, accuracy: 5.0,
                       "Kinematics must be frame-rate invariant (30 vs 120 fps)")
    }

    func testAsymmetricTauTightensFasterThanReleases() {
        let dt = 1.0 / 30.0
        let tightenStep = abs(CameraKinematics.approach(
            current: 2000, target: 1000, dt: dt,
            tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
            rateCapPerSecond: 100_000, snapEpsilon: 0.001) - 2000)
        let releaseStep = abs(CameraKinematics.approach(
            current: 1000, target: 2000, dt: dt,
            tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
            rateCapPerSecond: 100_000, snapEpsilon: 0.001) - 1000)
        XCTAssertGreaterThan(tightenStep, releaseStep,
                             "Tightening (tau 0.6) must move faster than releasing (tau 1.8)")
    }

    func testRateCapBoundsHugeJumps() {
        let dt: TimeInterval = 1.0 / 30.0
        let next = CameraKinematics.approach(
            current: 4200, target: 250, dt: dt,
            tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
            rateCapPerSecond: timing.altitudeRateCapMPerS, snapEpsilon: 0.25)
        let step = abs(next - 4200)
        XCTAssertEqual(step, timing.altitudeRateCapMPerS * dt, accuracy: 1e-6,
                       "A huge jump must ride exactly at the rate cap")
    }

    func testSnapEpsilonSettlesExactly() {
        var value = 1001.0
        for _ in 0..<200 {
            value = CameraKinematics.approach(
                current: value, target: 1000, dt: 1.0 / 30.0,
                tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
                rateCapPerSecond: 100_000, snapEpsilon: 0.25)
        }
        XCTAssertEqual(value, 1000.0, accuracy: 1e-9,
                       "Residual error must be snappable to zero, never accumulate")
    }

    func testZeroDtIsNoOp() {
        XCTAssertEqual(CameraKinematics.approach(current: 500, target: 1000, dt: 0,
                                                 tightenTau: 0.6, releaseTau: 1.8,
                                                 rateCapPerSecond: 900, snapEpsilon: 0.25),
                       500)
    }

    // MARK: - Stabilizer lifecycle

    private func context(speed: Double, dtt: CLLocationDistance = 5000,
                         instruction: String = "Continue straight") -> CameraContext {
        CameraContext(
            speed: speed, speedLimit: 40, isNavigating: true, isRecording: true,
            distanceToNextTurn: dtt, instruction: instruction,
            maneuverImageName: "arrow.turn.up.left", destinationDistance: 50_000,
            hasRoute: true, userPitchOverride: .auto
        )
    }

    private var t0: Date { Date(timeIntervalSince1970: 2_000_000) }

    func testStabilizerPrimesWithoutGliding() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 55, dtt: 4000))
        // The first target must already reflect the cruise level — no
        // slow glide from the default 320 m altitude.
        XCTAssertEqual(stab.currentTarget.altitude,
                       Double(CameraTuning.fallback.cruiseLevels[6].altitude), accuracy: 1.0)
    }

    func testStabilizerEMASmoothsSpeed() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 30))
        stab.ingest(context: context(speed: 30), now: t0)
        let baseline = stab.currentTarget.altitude

        // One noisy 45 mph sample must not teleport the camera.
        stab.ingest(context: context(speed: 45), now: t0.addingTimeInterval(0.5))
        let afterNoise = stab.currentTarget.altitude
        XCTAssertEqual(afterNoise, baseline, accuracy: 60,
                       "A single noisy sample must barely move the governed target")
    }

    func testStabilizerHoldsLevelAcrossGPSNoise() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 55))
        stab.ingest(context: context(speed: 55), now: t0)
        let level = stab.currentLevelIndex
        var now = t0
        for step in 0..<40 {
            now.addTimeInterval(0.4)
            let noisy = step.isMultiple(of: 2) ? 53.0 : 57.0
            stab.ingest(context: context(speed: noisy), now: now)
        }
        XCTAssertEqual(stab.currentLevelIndex, level, "Noise storm moved the governed level")
    }

    func testStabilizerIgnoresBackwardsTime() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 40))
        stab.ingest(context: context(speed: 40), now: t0.addingTimeInterval(10))
        // A fix timestamped before the last one must not produce a
        // negative-dt integration blowup.
        stab.ingest(context: context(speed: 40), now: t0)
        XCTAssertFalse(stab.currentTarget.altitude.isNaN)
        XCTAssertFalse(stab.currentTarget.altitude.isInfinite)
    }
}
