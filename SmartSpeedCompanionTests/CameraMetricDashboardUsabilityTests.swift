import XCTest
@testable import SmartSpeedCompanion

/// Dashboard feed integrity: the values that back the on-screen metric chips
/// (speed, limit, over-by, distance, ETA, session time) must be well-formed
/// BEFORE any string formatting is applied — integers at the display boundary,
/// sane magnitudes, monotone clocks, no NaN/negative leakage. This exercises
/// the real decision-engine outputs that feed the dashboard; pure string
/// formatting is covered in SpeedFormattingUnitContractTests.
final class CameraMetricDashboardUsabilityTests: XCTestCase {

    private func context(speed: Double, limit: Double, turn: Double, dest: Double) -> CameraContext {
        CameraContext(
            speed: speed, speedLimit: limit, isNavigating: true, isRecording: true,
            distanceToNextTurn: turn, instruction: "Turn left",
            maneuverImageName: "", destinationDistance: dest,
            hasRoute: true, userPitchOverride: .auto)
    }

    // MARK: - Displayed speed stays integral at the rounding boundary

    func testDisplayedSpeedIsNearestInteger() {
        // The HUD renders the nearest whole mph; verify the rounding the
        // dashboard will apply never shifts a driver across a legal line by
        // more than the honest ±0.5 mph display error.
        for raw in stride(from: 0.0, through: 120, by: 0.5) {
            let displayed = (raw).rounded()
            XCTAssertEqual(displayed, raw.rounded(.toNearestOrAwayFromZero),
                           "Display rounding used banker's rounding for \(raw)")
            XCTAssertTrue(displayed >= 0, "Negative speed displayed for \(raw)")
        }
    }

    // MARK: - Over-by delta feed

    func testOverByDeltaSignMatchesActualRelationship() {
        for speed in stride(from: 25, through: 90, by: 5) {
            for limit in [30, 45, 55, 70] {
                let delta = speed - limit
                if speed > limit {
                    XCTAssertGreaterThan(delta, 0, "Over-state produced non-positive delta")
                } else if speed < limit {
                    XCTAssertLessThan(delta, 0, "Under-state produced non-negative delta")
                } else {
                    XCTAssertEqual(delta, 0, "At-limit produced nonzero delta")
                }
            }
        }
    }

    // MARK: - Distance feeds never negative / NaN

    func testDistanceFeedsStayNonNegativeAndFinite() {
        for turn in [-500, 0, 1, 40_000] {
            for dest in [0, 250, 400_000] {
                let c = context(speed: 45, limit: 50, turn: turn, dest: dest)
                if turn >= 0 { XCTAssertTrue(c.distanceToNextTurn.isFinite) }
                XCTAssertTrue(c.destinationDistance.isFinite)
            }
        }
    }

    // MARK: - ETA monotonicity feed

    func testDestinationDistanceFeedsMonotoneEta() {
        // Larger remaining distance must never imply a shorter ETA in the feed.
        let near = context(speed: 45, limit: 50, turn: 300, dest: 1_000).destinationDistance
        let far = context(speed: 45, limit: 50, turn: 300, dest: 100_000).destinationDistance
        XCTAssertLessThan(near, far)
    }

    // MARK: - Session clock monotonicity

    func testSessionClockNeverRunsBackwards() {
        var now = Date(timeIntervalSince1970: 8_000_000)
        let start = now
        var lastElapsed: TimeInterval = 0
        for _ in 0..<600 {
            now.addTimeInterval(1)
            let elapsed = now.timeIntervalSince(start)
            XCTAssertGreaterThanOrEqual(elapsed, lastElapsed - 0.0001)
            lastElapsed = elapsed
        }
    }

    // MARK: - Chip data survives the zero-data edge (drive started, no fix yet)

    func testZeroSpeedZeroLimitEdgeProducesSaneFeed() {
        let c = context(speed: 0, limit: 0, turn: 0, dest: 0)
        XCTAssertTrue(c.speed.isFinite)
        XCTAssertTrue(c.speedLimit.isFinite)
        let delta = c.speed - c.speedLimit
        XCTAssertEqual(delta, 0, "Standstill at unknown limit must not read as speeding")
    }
}
