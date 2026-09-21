import XCTest
@testable import SmartSpeedCompanion

/// CruiseGovernor deep verification: the discrete-level zoom authority.
/// Every boundary of the 8-level table, dwell-division behavior at each
/// jump size, hysteresis edges, and anchor determinism — the mechanics
/// that killed the v1 sawtooth zoom.
final class CameraCruiseGovernorDeepTests: XCTestCase {

    private let levels = CameraTuning.fallback.cruiseLevels
    private var t = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        t = Date(timeIntervalSince1970: 1_000_000)
    }

    // MARK: - Table structure

    func testLevelTableIsMonotoneAndComplete() {
        XCTAssertEqual(levels.count, 8)
        XCTAssertEqual(levels.first?.maxSpeedMph, 3, "Level 0 is the parked level")
        XCTAssertEqual(levels.last?.maxSpeedMph, 999, "Sentinel top level caps the table")
        for i in 1..<levels.count {
            XCTAssertGreaterThan(levels[i].maxSpeedMph, levels[i - 1].maxSpeedMph)
            XCTAssertGreaterThan(levels[i].altitude, levels[i - 1].altitude,
                                 "Higher speeds must mean higher (farther) cameras")
        }
        for level in levels {
            XCTAssertLessThan(level.holdSpeedMph, level.maxSpeedMph,
                              "Hysteresis band must be non-empty (hold < max)")
        }
    }

    // MARK: - Quantization

    func testQuantizeAcrossEveryBandEdge() {
        // Level boundaries: 3, 15, 25, 35, 45, 55, 65, 999.
        let edges: [(Double, Int)] = [
            (0, 0), (2.9, 0), (3.0, 0), (3.01, 1),
            (14.9, 1), (15.0, 1), (15.1, 2),
            (24.9, 2), (25.0, 2), (25.1, 3),
            (34.9, 3), (35.0, 3), (35.1, 4),
            (44.9, 4), (45.0, 4), (45.1, 5),
            (54.9, 5), (55.0, 5), (55.1, 6),
            (64.9, 6), (65.0, 6), (65.1, 7),
            (200, 7),
        ]
        for (speed, level) in edges {
            XCTAssertEqual(CameraMath.quantizeLevel(speedMph: speed, levels: levels), level,
                           "Speed \(speed) quantized wrong")
        }
    }

    // MARK: - Dwell behavior per jump size

    func testDwellDividesByJumpMagnitude() {
        // Single-band jump: full 3 s dwell. 3-band jump: 3/3 = 1 s (capped).
        var gov = CruiseGovernor(levels: levels, dwellSeconds: 3.0, initialSpeedMph: 20)
        var now = t
        _ = gov.update(speedMph: 26, now: now, allowPark: true) // 1-band desire
        now.addTimeInterval(2.9)
        XCTAssertEqual(gov.update(speedMph: 26, now: now, allowPark: true), 2,
                       "Single band must not commit before full dwell")
        now.addTimeInterval(0.2)
        XCTAssertEqual(gov.update(speedMph: 26, now: now, allowPark: true), 3,
                       "Single band commits after 3 s")

        // Fresh governor, 3-band jump: 20 → 45+.
        var gov2 = CruiseGovernor(levels: levels, dwellSeconds: 3.0, initialSpeedMph: 20)
        var now2 = t
        _ = gov2.update(speedMph: 50, now: now2, allowPark: true) // 3-band desire
        now2.addTimeInterval(1.1)
        XCTAssertEqual(gov2.update(speedMph: 50, now: now2, allowPark: true), 5,
                       "3-band jump commits at 1 s (dwell/3, capped)")
    }

    func testNoiseAroundEveryBandEdgeNeverFlaps() {
        // Sweep noise across each boundary: the committed level must stay
        // fixed through the entire noise storm.
        for boundary in [3.0, 15.0, 25.0, 35.0, 45.0, 55.0, 65.0] {
            var gov = CruiseGovernor(levels: levels, dwellSeconds: 2.5,
                                     initialSpeedMph: boundary + 5)
            var now = t
            let initialLevel = gov.currentIndex
            for step in 0..<60 {
                let noisy = step.isMultiple(of: 2) ? boundary - 1 : boundary + 1
                now.addTimeInterval(0.3)
                _ = gov.update(speedMph: noisy, now: now, allowPark: true)
            }
            XCTAssertEqual(gov.currentIndex, initialLevel,
                           "Noise at boundary \(boundary) flapped the level")
        }
    }

    // MARK: - Park policy

    func testParkAllowedOnlyInFreeDrive() {
        var gov = CruiseGovernor(levels: levels, dwellSeconds: 1.0, initialSpeedMph: 10)
        var now = t
        for _ in 0..<20 {
            now.addTimeInterval(0.5)
            _ = gov.update(speedMph: 0, now: now, allowPark: true)
        }
        XCTAssertEqual(gov.currentIndex, 0, "Free-drive stop must relax to parked level")

        var navGov = CruiseGovernor(levels: levels, dwellSeconds: 1.0, initialSpeedMph: 10)
        now = t
        let started = navGov.currentIndex
        for _ in 0..<20 {
            now.addTimeInterval(0.5)
            _ = navGov.update(speedMph: 0, now: now, allowPark: false)
        }
        XCTAssertEqual(navGov.currentIndex, started,
                       "Navigation stop must hold the cruise level (red-light scenario)")
    }

    // MARK: - Anchor determinism

    func testAnchorRoundTripAllLevels() {
        for i in levels.indices {
            let anchor = CameraMath.anchorSpeed(level: i, levels: levels)
            XCTAssertEqual(CameraMath.quantizeLevel(speedMph: anchor, levels: levels), i,
                           "Level \(i)'s anchor does not round-trip")
        }
    }

    func testAnchorsAreIntraLevel() {
        for i in levels.indices {
            let anchor = CameraMath.anchorSpeed(level: i, levels: levels)
            let level = levels[i]
            if i == 0 {
                XCTAssertLessThanOrEqual(anchor, level.maxSpeedMph)
            } else {
                XCTAssertGreaterThan(anchor, levels[i - 1].maxSpeedMph,
                                     "Anchor \(i) falls into the previous band")
                XCTAssertLessThanOrEqual(anchor, level.maxSpeedMph,
                                         "Anchor \(i) exceeds its own band")
            }
        }
    }

    // MARK: - Downshift hysteresis edges

    func testHysteresisBandIsNotCommittable() {
        var gov = CruiseGovernor(levels: levels, dwellSeconds: 0.5, initialSpeedMph: 57)
        var now = t
        // Speeds inside the band (51–55 for level 6) must not downshift,
        // no matter how long they persist.
        for _ in 0..<40 {
            now.addTimeInterval(0.5)
            _ = gov.update(speedMph: 53, now: now, allowPark: true)
        }
        XCTAssertEqual(gov.currentIndex, 6, "53 mph is inside level 6's hysteresis band")
    }
}
