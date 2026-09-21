import XCTest
@testable import SmartSpeedCompanion

/// Post-maneuver camera dynamics: the hold-then-release envelope that
/// replaced v1's whiplash. Timing windows, monotone blend, cancellation
/// when the next maneuver approaches, and compound-maneuver coalescing.
final class CameraPostManeuverReleaseTests: XCTestCase {

    private let timing = CameraTuning.fallback.timing

    private func context(speed: Double, dtt: CLLocationDistance,
                         instruction: String) -> CameraContext {
        CameraContext(
            speed: speed, speedLimit: 40, isNavigating: true, isRecording: true,
            distanceToNextTurn: dtt, instruction: instruction,
            maneuverImageName: "arrow.turn.up.left", destinationDistance: 30_000,
            hasRoute: true, userPitchOverride: .auto
        )
    }

    private var t0: Date { Date(timeIntervalSince1970: 3_000_000) }

    private func cruiseAltitude(for speed: Double) -> Double {
        let idx = CameraMath.quantizeLevel(speedMph: speed, levels: CameraTuning.fallback.cruiseLevels)
        return Double(CameraTuning.fallback.cruiseLevels[idx].altitude)
    }

    // MARK: - Hold window

    func testHoldKeepsTightFramingImmediatelyAfterPassing() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 30, dtt: 50, instruction: "Turn left onto Main St"))
        stab.ingest(context: context(speed: 30, dtt: 50, instruction: "Turn left onto Main St"), now: t0)

        // Pass: instruction advances, DTT jumps far.
        stab.ingest(context: context(speed: 30, dtt: 1800, instruction: "Continue straight"),
                    now: t0.addingTimeInterval(0.3))
        let held = stab.currentTarget.altitude
        XCTAssertLessThan(held, cruiseAltitude(for: 30) * 0.7,
                          "The tight framing must hold right after the turn — no instant snap-out")
    }

    // MARK: - Release blend

    func testReleaseIsMonotoneTowardCruise() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 30, dtt: 50, instruction: "Turn left"))
        stab.ingest(context: context(speed: 30, dtt: 50, instruction: "Turn left"), now: t0)
        stab.ingest(context: context(speed: 30, dtt: 1800, instruction: "Continue"),
                    now: t0.addingTimeInterval(0.2))
        let held = stab.currentTarget.altitude

        var previous = held
        var step = 0.3
        while step < timing.postManeuverHoldSeconds + timing.postManeuverReleaseSeconds + 0.5 {
            stab.ingest(context: context(speed: 30, dtt: 1800, instruction: "Continue"),
                        now: t0.addingTimeInterval(0.2 + step))
            let current = stab.currentTarget.altitude
            XCTAssertGreaterThanOrEqual(current, previous - 0.5,
                                       "Release regressed (zoomed back IN) at t=\(step)")
            previous = current
            step += 0.3
        }
        // Converges to cruise.
        XCTAssertEqual(previous, cruiseAltitude(for: 30), accuracy: 5,
                       "Release must land exactly on cruise altitude")
    }

    // MARK: - Cancellation

    func testApproachingNextManeuverCancelsRelease() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 30, dtt: 50, instruction: "Turn left"))
        stab.ingest(context: context(speed: 30, dtt: 50, instruction: "Turn left"), now: t0)
        stab.ingest(context: context(speed: 30, dtt: 900, instruction: "Turn right"),
                    now: t0.addingTimeInterval(0.4))
        let held = stab.currentTarget.altitude

        // Before release can progress, the next maneuver closes in.
        stab.ingest(context: context(speed: 30, dtt: 100, instruction: "Turn right"),
                    now: t0.addingTimeInterval(3.8))
        let retightened = stab.currentTarget.altitude
        XCTAssertLessThanOrEqual(retightened, held * 1.1,
                                 "A closely-following maneuver must cancel the release and re-tighten")
    }

    func testDistantNextManeuverLetsReleaseFinish() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 30, dtt: 50, instruction: "Turn left"))
        stab.ingest(context: context(speed: 30, dtt: 50, instruction: "Turn left"), now: t0)
        stab.ingest(context: context(speed: 30, dtt: 5000, instruction: "Next turn in 3 miles"),
                    now: t0.addingTimeInterval(0.4))

        let end = timing.postManeuverHoldSeconds + timing.postManeuverReleaseSeconds + 1
        stab.ingest(context: context(speed: 30, dtt: 5000, instruction: "Next turn in 3 miles"),
                    now: t0.addingTimeInterval(0.4 + end))
        XCTAssertEqual(stab.currentTarget.altitude, cruiseAltitude(for: 30), accuracy: 5,
                       "With no follow-up maneuver the release must complete")
    }

    // MARK: - Compound maneuver coalescing

    func testCompoundManeuversNeverPingPong() {
        // Two maneuvers 150 m apart, passed 2 s apart: the camera must
        // tighten → tighten → release, never tighten → release → tighten
        // whiplash.
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 35, dtt: 100, instruction: "Turn left"))
        stab.ingest(context: context(speed: 35, dtt: 100, instruction: "Turn left"), now: t0)

        // Approach second maneuver while releasing from the first.
        stab.ingest(context: context(speed: 35, dtt: 400, instruction: "Then turn right"),
                    now: t0.addingTimeInterval(1.0))
        stab.ingest(context: context(speed: 35, dtt: 150, instruction: "Turn right"),
                    now: t0.addingTimeInterval(2.0))
        let tight2 = stab.currentTarget.altitude

        // Pass the second.
        stab.ingest(context: context(speed: 35, dtt: 2000, instruction: "Continue"),
                    now: t0.addingTimeInterval(2.5))
        let held2 = stab.currentTarget.altitude
        XCTAssertLessThanOrEqual(held2, tight2 * 1.05 + 10,
                                 "Second pass must hold tight framing (no whiplash between compounds)")
    }

    // MARK: - Speed changes during release

    func testReleaseSurvivesSpeedLevelChange() {
        // Driver accelerates during the release: cruise target changes —
        // release must blend to the NEW cruise, not the stale one.
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 30, dtt: 50, instruction: "Turn left"))
        stab.ingest(context: context(speed: 30, dtt: 50, instruction: "Turn left"), now: t0)
        stab.ingest(context: context(speed: 30, dtt: 3000, instruction: "Continue"),
                    now: t0.addingTimeInterval(0.3))

        let end = timing.postManeuverHoldSeconds + timing.postManeuverReleaseSeconds + 1
        stab.ingest(context: context(speed: 55, dtt: 3000, instruction: "Continue"),
                    now: t0.addingTimeInterval(0.3 + end))
        let newCruise = cruiseAltitude(for: 55)
        XCTAssertEqual(stab.currentTarget.altitude, newCruise, accuracy: 15,
                       "Release must converge to the governor's NEW level after acceleration")
    }
}
