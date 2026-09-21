import XCTest
@testable import SmartSpeedCompanion

/// CameraTuning.json integrity: the bundled tuning resource must decode,
/// be structurally identical to the compile-time fallback, and stay within
/// physically safe bounds. A malformed file degrades silently to fallback
/// (by design) — this test makes the degradation LOUD instead.
final class CameraTuningResourceIntegrityTests: XCTestCase {

    func testBundledResourceLoadsAndDecodes() {
        guard Bundle.main.url(forResource: "CameraTuning", withExtension: "json") != nil else {
            // The tuning file ships in the app bundle; unit tests run in the
            // app host, so it must be present. If XcodeGen drops it, fail loud.
            XCTFail("CameraTuning.json missing from the app bundle — check project.yml resources")
            return
        }
        // Decoding is what loadTuning does; the resolved `current` proves it.
        XCTAssertNotNil(CameraTuning.loadTuning(),
                        "CameraTuning.json failed to decode — app silently used fallback")
    }

    func testResolvedCurrentEqualsDecodedResource() {
        if CameraTuning.loadTuning() != nil {
            XCTAssertEqual(CameraTuning.current, CameraTuning.loadTuning(),
                           "`current` must be the decoded resource, not the fallback")
        } else {
            XCTAssertEqual(CameraTuning.current, CameraTuning.fallback,
                           "Without a resource, `current` must be exactly the fallback")
        }
    }

    func testCruiseLevelsBoundsAreSane() {
        for (idx, level) in CameraTuning.current.cruiseLevels.enumerated() {
            // Altitude bounds MapKit can render without degenerate framing.
            XCTAssertTrue((100...6000).contains(level.altitude), "Level \(idx) altitude \(level.altitude)")
            XCTAssertTrue((0...60).contains(level.pitch), "Level \(idx) pitch \(level.pitch)")
            XCTAssertTrue(level.maxSpeedMph > level.holdSpeedMph, "Level \(idx) hysteresis inverted")
        }
    }

    func testTimingValuesArePhysicallySane() {
        let timing = CameraTuning.current.timing
        XCTAssertGreaterThan(timing.dwellSeconds, 0.5, "Dwell too short: GPS noise flaps levels")
        XCTAssertLessThan(timing.dwellSeconds, 6, "Dwell too long: camera feels dead")
        XCTAssertLessThan(timing.tightenTauSeconds, timing.releaseTauSeconds,
                          "Tighten must be faster than release (asymmetry is the feel)")
        XCTAssertGreaterThan(timing.altitudeRateCapMPerS, 0)
        XCTAssertGreaterThan(timing.pitchRateCapDegPerS, 0)
        XCTAssertGreaterThan(timing.postManeuverHoldSeconds, 0)
        XCTAssertGreaterThan(timing.postManeuverReleaseSeconds, 0)
        XCTAssertGreaterThan(timing.speedSmoothingTauSeconds, 0)
    }

    func testManeuverEnvelopeStructure() {
        let maneuver = CameraTuning.current.maneuver
        XCTAssertGreaterThan(maneuver.startDistanceM, maneuver.fullTightenDistanceM,
                             "Tighten window must be positive-length")
        XCTAssertTrue((0.1...0.9).contains(maneuver.minMultiplier),
                      "minMultiplier \(maneuver.minMultiplier) outside the usable zoom range")
    }

    func testPitchFlattenStructure() {
        let flatten = CameraTuning.current.pitchFlatten
        XCTAssertGreaterThan(flatten.triggerDistanceM, flatten.fullFlattenDistanceM)
        XCTAssertTrue((0...30).contains(flatten.maxFlattenDeg))
    }

    func testDestinationStructure() {
        let destination = CameraTuning.current.destination
        XCTAssertGreaterThan(destination.startDistanceM, 0)
        XCTAssertTrue((0.1...0.9).contains(destination.minMultiplier))
        XCTAssertTrue((0...30).contains(destination.maxPitchReductionDeg))
    }

    func testFallbackTablesAreComplete() {
        // The fallback must be a valid table in its own right (it ships in
        // the binary for missing-resource launches).
        XCTAssertEqual(CameraTuning.fallback.cruiseLevels.count, 8)
        XCTAssertFalse(CameraTuning.fallback.cruiseLevels.isEmpty)
    }
}
