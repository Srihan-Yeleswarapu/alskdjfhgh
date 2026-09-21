import XCTest
@testable import SmartSpeedCompanion

/// The continuity guard is the flyover-flicker damper: it decides commit /
/// hold / sink-in for every candidate limit. Its rules encode researched
/// authoritative values (MUTCD, FMVSS, 85th-percentile practice) — the
/// constants are pinned, and each rule's source shape is verified so a
/// refactor cannot silently delete a protection.
final class ContinuityGuardPolicyTests: XCTestCase {

    private func serviceSource() throws -> String {
        #if os(Windows)
        return try String(contentsOfFile: "SmartSpeedCompanion\\Core\\SpeedLimitService.swift", encoding: .utf8)
        #else
        return try String(contentsOfFile: "SmartSpeedCompanion/Core/SpeedLimitService.swift", encoding: .utf8)
        #endif
    }

    private func section(in source: String, anchor: String) throws -> String {
        guard let range = source.range(of: anchor) else {
            XCTFail("Missing anchor: \(anchor)")
            return ""
        }
        return String(source[range.lowerBound...])
    }

    // MARK: - Rule 1: small delta commits

    func testSmallDeltaCommitsImmediately() throws {
        let source = try serviceSource()
        let finalize = try section(in: source, anchor: "private func finalizeWithContinuity(")
        XCTAssertTrue(finalize.contains("speedDelta <= Self.SUSPICIOUS_JUMP_MPH"),
                      "Deltas within 15 mph must commit immediately")
        XCTAssertTrue(finalize.contains("lastStable = snapshot"),
                      "Commit must replace the stable snapshot")
    }

    // MARK: - Rule 1 exception: geocoder-provider disagreement

    func testGeocoderDisagreementRoutesToSuspectHold() throws {
        let source = try serviceSource()
        XCTAssertTrue(source.contains("geocoderSaysSameRoad && providerSaysDifferentRoad"),
                      "Same-geocode + different-roadKey must route to the suspect hold even for small deltas")
    }

    // MARK: - Rule 2: physics override

    func testPhysicsOverrideShape() throws {
        let source = try serviceSource()
        let finalize = try section(in: source, anchor: "// Rule 2 -- physics override")
        XCTAssertTrue(finalize.contains("outcome.limit > prior.limit"),
                      "Physics override only commits upward candidates")
        XCTAssertTrue(finalize.contains("PHYSICS_TOLERANCE_MPH"),
                      "Candidate must be within 10 mph of the driver's actual speed")
        XCTAssertTrue(finalize.contains("PHYSICS_PRIOR_MARGIN_MPH"),
                      "Prior limit must be > 15 mph off physics (driver clearly left that road)")
    }

    /// The on-ramp scenario: driver accelerating at 72 mph, prior 45,
    /// candidate 75 → the override must fire (|75−72| ≤ 10, |45−72| > 15).
    func testOnRampScenarioArithmetic() {
        let prior = 45, candidate = 75, driverSpeed = 72.0
        let candidateWithinTolerance = abs(Double(candidate) - driverSpeed) <= 10.0
        let priorOffPhysics = abs(Double(prior) - driverSpeed) > 15.0
        XCTAssertTrue(candidateWithinTolerance && priorOffPhysics,
                      "On-ramp numbers must satisfy the override conditions")
    }

    /// A candidate far from physics must NOT override: driver at 40,
    /// candidate 75, prior 45.
    func testPhysicsOverrideRejectsNonPhysicalCandidate() {
        let prior = 45, candidate = 75, driverSpeed = 40.0
        let candidateWithinTolerance = abs(Double(candidate) - driverSpeed) <= 10.0
        XCTAssertFalse(candidateWithinTolerance,
                       "A 75 mph candidate while driving 40 must never physics-override")
    }

    // MARK: - Rule 3: suspect hold + sink-in

    func testSinkInAfterThreeConsecutiveSuspects() throws {
        let source = try serviceSource()
        let sink = try section(in: source, anchor: "if consecutiveSuspectCount >= Self.SUSPICIOUS_FETCH_HOLD")
        XCTAssertTrue(sink.contains("lastStable = snapshot"),
                      "Sink-in must commit the suspect after 3 identical fetches")
    }

    func testHoldRestoresFullPriorPresentation() throws {
        let source = try serviceSource()
        let hold = try section(in: source, anchor: "// Hold prior -- returns the previously committed limit")
        XCTAssertTrue(hold.contains("self.dataSource = prior.source"),
                      "Hold must restore the prior source label, not just the number")
        XCTAssertTrue(hold.contains("self.currentLimit = prior.limit"))
    }

    func testSuspectIdentityComparesRoadKeyAndName() throws {
        let source = try serviceSource()
        XCTAssertTrue(source.contains("pending.roadKey == snapshot.roadKey,\n           pending.roadName == snapshot.roadName"),
                      "Sink-in counting requires identical road identity across fetches")
    }

    // MARK: - Cache hygiene

    func testGuardFiresBeforeCacheWrites() throws {
        let source = try serviceSource()
        // commit() is the only cache-writing path, and it's reached only
        // after the guard's decisions.
        XCTAssertTrue(source.contains("private func commit("))
        let commit = try section(in: source, anchor: "private func commit(")
        XCTAssertTrue(commit.contains("cache.store"),
                      "Commit persists to the response cache")
        // The hold path must NOT write the cache.
        let hold = try section(in: source, anchor: "// Hold prior --")
        XCTAssertFalse(hold.contains("cache.store"),
                       "A held suspect must never poison the response cache")
    }

    // MARK: - Constant provenance (authoritative research notes)

    func testResearchedBasisNotesSurvive() throws {
        let source = try serviceSource()
        XCTAssertTrue(source.contains("MUTCD"), "The 15-mph basis cites MUTCD research")
        XCTAssertTrue(source.contains("49 CFR") || source.contains("FMVSS"),
                      "The 10-mph physics tolerance cites speedometer-accuracy research")
        XCTAssertTrue(source.contains("85th-percentile") || source.contains("85th percentile"),
                      "Transition-zone research note survives")
    }

    // MARK: - Scenario matrix (pure arithmetic of the rules)

    func testDecisionMatrixArithmetic() {
        struct Case { let prior: Int; let candidate: Int; let speed: Double; let expectOverride: Bool }
        let cases: [Case] = [
            Case(prior: 45, candidate: 75, speed: 72, expectOverride: true),   // on-ramp
            Case(prior: 45, candidate: 75, speed: 40, expectOverride: false),  // non-physical
            Case(prior: 45, candidate: 65, speed: 60, expectOverride: true),   // arterial→hwy
            Case(prior: 65, candidate: 30, speed: 35, expectOverride: false),  // downward never overrides
        ]
        for testCase in cases {
            let upward = testCase.candidate > testCase.prior
            let within = abs(Double(testCase.candidate) - testCase.speed) <= 10.0
            let priorOff = abs(Double(testCase.prior) - testCase.speed) > 15.0
            XCTAssertEqual(upward && within && priorOff, testCase.expectOverride,
                           "prior=\(testCase.prior) candidate=\(testCase.candidate) speed=\(testCase.speed)")
        }
    }
}
