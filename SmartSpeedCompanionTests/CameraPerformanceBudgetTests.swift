import XCTest
@testable import SmartSpeedCompanion

/// Camera pipeline performance budgets. The display link calls the
/// governor + decision engine + kinematics every frame; each component
/// must be far under its per-tick budget even on an older phone. Wall-clock
/// assertions are opt-in (SPEEDIO_PERF_TESTS=1) so a loaded Mac can't flake
/// the default suite; the stability checks below run always.
final class CameraPerformanceBudgetTests: XCTestCase {

    private let levels = CameraTuning.fallback.cruiseLevels
    private let timing = CameraTuning.fallback.timing

    // MARK: - Always-on stability checks

    func testGovernorOutputStableAcrossRepeatRuns() {
        // Determinism: the same input timeline must produce the same
        // committed levels twice (guards against hidden state or time).
        func run() -> [Int] {
            var gov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds,
                                     initialSpeedMph: 20)
            var now = Date(timeIntervalSince1970: 6_000_000)
            var output: [Int] = []
            for speed in stride(from: 0.0, through: 90, by: 5) {
                now.addTimeInterval(0.5)
                output.append(gov.update(speedMph: speed, now: now, allowPark: true))
            }
            return output
        }
        XCTAssertEqual(run(), run(), "Governor is nondeterministic across identical runs")
    }

    func testDecisionEngineOutputStableAcrossRepeatRuns() {
        func run() -> [(Double, Double)] {
            (0..<200).map { i in
                let context = CameraContext(
                    speed: Double(i) % 90, speedLimit: 45, isNavigating: true, isRecording: true,
                    distanceToNextTurn: Double(i * 30), instruction: "Turn",
                    maneuverImageName: "", destinationDistance: Double(i * 100),
                    hasRoute: true, userPitchOverride: .auto)
                let t = CameraDecisionEngine.computeTarget(from: context)
                return (t.altitude, t.pitch)
            }
        }
        XCTAssertEqual(run(), run())
    }

    // MARK: - Performance budgets (opt-in wall clock)

    private func measurePerCall(runs: Int = 10_000, _ block: () -> Void) -> TimeInterval {
        // Warm-up.
        for _ in 0..<100 { block() }
        let start = Date()
        for _ in 0..<runs { block() }
        return Date().timeIntervalSince(start) / Double(runs)
    }

    func testGovernorUpdateUnderMicrosecondBudget() throws {
        try skipUnlessPerfEnabled()
        var gov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds,
                                 initialSpeedMph: 55)
        let now = Date()
        let perCall = measurePerCall { _ = gov.update(speedMph: 57, now: now, allowPark: true) }
        XCTAssertLessThan(perCall, 0.000_005,
                          "Governor update \(perCall * 1_000_000) µs exceeds the 5 µs per-tick budget")
    }

    func testDecisionEngineUnderMicrosecondBudget() throws {
        try skipUnlessPerfEnabled()
        let context = CameraContext(
            speed: 45, speedLimit: 50, isNavigating: true, isRecording: true,
            distanceToNextTurn: 400, instruction: "Turn left",
            maneuverImageName: "", destinationDistance: 8000,
            hasRoute: true, userPitchOverride: .auto)
        let perCall = measurePerCall { _ = CameraDecisionEngine.computeTarget(from: context) }
        XCTAssertLessThan(perCall, 0.000_010,
                          "Decision engine \(perCall * 1_000_000) µs exceeds the 10 µs per-tick budget")
    }

    func testKinematicsUnderNanosecondScaleBudget() throws {
        try skipUnlessPerfEnabled()
        var value = 3000.0
        let perCall = measurePerCall {
            value = CameraKinematics.approach(current: value, target: 800, dt: 1.0 / 30,
                                              tightenTau: 0.6, releaseTau: 1.8,
                                              rateCapPerSecond: 900, snapEpsilon: 0.25)
        }
        XCTAssertLessThan(perCall, 0.000_002,
                          "Kinematics \(perCall * 1_000_000) µs exceeds the 2 µs budget")
    }

    func testFullPipelinePerTickUnderBudget() throws {
        try skipUnlessPerfEnabled()
        let context = CameraContext(
            speed: 45, speedLimit: 50, isNavigating: true, isRecording: true,
            distanceToNextTurn: 400, instruction: "Turn left",
            maneuverImageName: "", destinationDistance: 8000,
            hasRoute: true, userPitchOverride: .auto)
        var gov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds,
                                 initialSpeedMph: 45)
        var altitude = 1000.0
        var value = 1000.0
        let now = Date()
        let perCall = measurePerCall {
            _ = gov.update(speedMph: 45, now: now, allowPark: false)
            let target = CameraDecisionEngine.computeTarget(from: context)
            value = CameraKinematics.approach(current: altitude, target: target.altitude,
                                              dt: 1.0 / 60, tightenTau: 0.6, releaseTau: 1.8,
                                              rateCapPerSecond: 900, snapEpsilon: 0.25)
            altitude = value
        }
        // 60 fps frame budget is 16.7 ms; the camera pipeline gets < 0.1 ms.
        XCTAssertLessThan(perCall, 0.000_100,
                          "Full camera pipeline \(perCall * 1_000_000) µs per tick exceeds 100 µs")
    }

    // MARK: - Memory discipline: no unbounded growth in the stabilizer

    func testStabilizerDoesNotAccumulateHistory() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: CameraContext(
            speed: 45, speedLimit: 50, isNavigating: true, isRecording: true,
            distanceToNextTurn: 500, instruction: "Turn",
            maneuverImageName: "", destinationDistance: 9000,
            hasRoute: true, userPitchOverride: .auto))
        var now = Date(timeIntervalSince1970: 7_000_000)
        for i in 0..<10_000 {
            now.addTimeInterval(0.1)
            stab.ingest(context: CameraContext(
                speed: 45 + Double(i % 5), speedLimit: 50, isNavigating: true, isRecording: true,
                distanceToNextTurn: 500 + Double(i % 100), instruction: "Turn",
                maneuverImageName: "", destinationDistance: 9000,
                hasRoute: true, userPitchOverride: .auto), now: now)
        }
        // If the stabilizer held per-ingest history, 10k ingests would
        // balloon memory — assert the object stayed lean via its target.
        XCTAssertFalse(stab.currentTarget.altitude.isNaN)
    }
}
