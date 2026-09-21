import XCTest
@testable import SmartSpeedCompanion

/// CameraMath envelope functions: continuity proofs (no jumps a driver
/// could see), bound proofs, and the exact shapes at trigger distances.
/// The v1 sawtooth was caused by discontinuous multipliers — these tests
/// make a discontinuity impossible to reintroduce silently.
final class CameraEnvelopeMathTests: XCTestCase {

    private let maneuver = CameraTuning.fallback.maneuver
    private let pitchFlatten = CameraTuning.fallback.pitchFlatten
    private let destination = CameraTuning.fallback.destination

    // MARK: - Maneuver envelope

    func testManeuverEnvelopeFarIsExactlyOne() {
        XCTAssertEqual(CameraMath.maneuverEnvelope(distance: 10_000, maneuver), 1.0, accuracy: 1e-12)
        XCTAssertEqual(CameraMath.maneuverEnvelope(distance: maneuver.startDistanceM + 1, maneuver), 1.0, accuracy: 1e-12)
    }

    func testManeuverEnvelopeFullTightenHoldsFloor() {
        XCTAssertEqual(CameraMath.maneuverEnvelope(distance: maneuver.fullTightenDistanceM, maneuver),
                       maneuver.minMultiplier, accuracy: 1e-9)
        XCTAssertEqual(CameraMath.maneuverEnvelope(distance: 0, maneuver),
                       maneuver.minMultiplier, accuracy: 1e-9)
    }

    func testManeuverEnvelopeIsMonotoneDecreasing() {
        var previous = 1.0
        var d = maneuver.startDistanceM
        while d > maneuver.fullTightenDistanceM - 2 {
            let v = CameraMath.maneuverEnvelope(distance: d, maneuver)
            XCTAssertLessThanOrEqual(v, previous + 1e-12,
                                     "Envelope increased at d=\(d) — visible zoom discontinuity")
            previous = v
            d -= 2
        }
    }

    func testManeuverEnvelopeBounds() {
        for d in stride(from: 0.0, through: 1000.0, by: 10) {
            let v = CameraMath.maneuverEnvelope(distance: d, maneuver)
            XCTAssertGreaterThanOrEqual(v, maneuver.minMultiplier - 1e-9)
            XCTAssertLessThanOrEqual(v, 1.0 + 1e-9)
        }
    }

    // MARK: - Pitch flatten

    func testPitchFlattenBeyondTriggerIsZero() {
        XCTAssertEqual(CameraMath.pitchFlattenReduction(distance: pitchFlatten.triggerDistanceM + 100,
                                                        pitchFlatten), 0, accuracy: 1e-9)
    }

    func testPitchFlattenMaxAtFullFlatten() {
        XCTAssertEqual(CameraMath.pitchFlattenReduction(distance: 0, pitchFlatten),
                       pitchFlatten.maxFlattenDeg, accuracy: 1e-9)
        XCTAssertEqual(CameraMath.pitchFlattenReduction(distance: pitchFlatten.fullFlattenDistanceM, pitchFlatten),
                       pitchFlatten.maxFlattenDeg, accuracy: 1e-9)
    }

    func testPitchFlattenMonotoneInDistance() {
        var previous = pitchFlatten.maxFlattenDeg
        var d = 0.0
        while d <= pitchFlatten.triggerDistanceM {
            let v = CameraMath.pitchFlattenReduction(distance: d, pitchFlatten)
            XCTAssertLessThanOrEqual(v, previous + 1e-9, "Flatten must ease off with distance")
            previous = v
            d += 10
        }
    }

    // MARK: - Destination modifier

    func testDestinationModifierFarIsIdentity() {
        let mod = CameraMath.destinationModifier(distance: destination.startDistanceM + 500, destination)
        XCTAssertEqual(mod.multiplier, 1.0, accuracy: 1e-9)
        XCTAssertEqual(mod.pitchReduction, 0, accuracy: 1e-9)
    }

    func testDestinationModifierAtArrival() {
        let mod = CameraMath.destinationModifier(distance: 0, destination)
        XCTAssertEqual(mod.multiplier, destination.minMultiplier, accuracy: 1e-9)
        XCTAssertEqual(mod.pitchReduction, destination.maxPitchReductionDeg, accuracy: 1e-9)
    }

    func testDestinationModifierNeverOvershoots() {
        for d in stride(from: 0.0, through: 600.0, by: 25) {
            let mod = CameraMath.destinationModifier(distance: d, destination)
            XCTAssertGreaterThanOrEqual(mod.multiplier, destination.minMultiplier - 1e-9)
            XCTAssertLessThanOrEqual(mod.multiplier, 1.0 + 1e-9)
            XCTAssertGreaterThanOrEqual(mod.pitchReduction, -1e-9)
            XCTAssertLessThanOrEqual(mod.pitchReduction, destination.maxPitchReductionDeg + 1e-9)
        }
    }

    // MARK: - smoothstep

    func testSmoothstepEndpoints() {
        XCTAssertEqual(CameraMath.smoothstep(0), 0, accuracy: 1e-9)
        XCTAssertEqual(CameraMath.smoothstep(1), 1, accuracy: 1e-9)
    }

    func testSmoothstepIsMonotone() {
        var previous = -1.0
        for i in 0...100 {
            let v = CameraMath.smoothstep(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, previous - 1e-9)
            previous = v
        }
    }

    func testSmoothstepClampsOutsideUnitRange() {
        XCTAssertEqual(CameraMath.smoothstep(-1), 0, accuracy: 1e-9)
        XCTAssertEqual(CameraMath.smoothstep(2), 1, accuracy: 1e-9)
    }

    // MARK: - Compound scenario: the full approach glide

    func testFullApproachProducesContinuousAltitude() {
        // Simulate the decision engine across a full maneuver approach at
        // 2 m resolution: the target altitude must never jump.
        let tuning = CameraTuning.fallback
        var previousAltitude: Double?
        var d = 900.0
        while d >= 0 {
            let context = CameraContext(
                speed: 30, speedLimit: 40, isNavigating: true, isRecording: true,
                distanceToNextTurn: d, instruction: "Turn",
                maneuverImageName: "arrow.turn.up.left", destinationDistance: 50_000,
                hasRoute: true, userPitchOverride: .auto
            )
            let target = CameraDecisionEngine.computeTarget(from: context)
            if let previous = previousAltitude {
                let jump = abs(target.altitude - previous)
                XCTAssertLessThan(jump, 6.0,
                                  "Altitude jumped \(jump)m between d=\(d + 2) and d=\(d) — visible snap")
            }
            previousAltitude = target.altitude
            d -= 2
        }
    }
}
