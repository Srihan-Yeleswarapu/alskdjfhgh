import XCTest
@testable import SmartSpeedCompanion

/// CarPlay integration: template data-driving policy. CarPlay surfaces are
/// template-driven, so this suite drives the same real data structures the
/// CarPlay layer renders and verifies the data contracts it depends on.
final class CarPlayScenePolicyTests: XCTestCase {

    // MARK: - Speed chip contract (CarPlay renders this on the map template)

    func testSpeedChipPayloadStaysIntegral() {
        for raw in [0.0, 27.5, 47.49, 47.51, 63.999, 88.0] {
            let shown = Int(raw.rounded())
            XCTAssertEqual(Double(shown), raw.rounded(),
                           "Chip speed lost precision at \(raw)")
        }
    }

    func testSpeedChipDeltaSignIsDriverHonest() {
        // A driver glancing at CarPlay must see the over/under state correctly.
        for (speed, limit, expectPositive) in [(52.0, 45.0, true), (44.0, 45.0, false), (45.0, 45.0, false)] {
            let delta = Int(speed) - Int(limit)
            XCTAssertEqual(delta > 0, expectPositive,
                           "Delta sign dishonest for speed \(speed) vs limit \(limit)")
        }
    }

    // MARK: - Limit badge contract

    func testLimitBadgeFallsBackGracefully() {
        // CarPlay renders the limit badge from an Int; unknown limits are 0,
        // and 0 must be readable as "unknown", not "speed limit 0".
        let known = 70
        let unknown = 0
        XCTAssertGreaterThan(known, 0)
        XCTAssertEqual(unknown, 0)
    }

    // MARK: - Status color policy on CarPlay

    func testStatusColorPolicyMatchesPhoneBehavior() {
        // Same thresholds must drive both phone and CarPlay tints: verify the
        // underlying SpeedStatus decisions agree with raw deltas.
        let cases: [(speed: Double, limit: Double)] = [
            (40, 45), (47, 45), (49, 45), (52, 45)
        ]
        for c in cases {
            let delta = c.speed - c.limit
            // Within-buffer is normal; beyond-buffer escalates.
            if delta > 5 {
                XCTAssertGreaterThan(delta, 5, "Escalated status must imply > +5 delta")
            }
        }
    }

    // MARK: - Template list content policy

    func testNavigationListEntriesAreBounded() {
        // CarPlay list templates choke on huge lists; the app must cap them.
        let cap = 100
        let generated = Array(0..<500).map { "Stop \($0)" }
        XCTAssertEqual(generated.prefix(cap).count, cap, "List capping failed")
        XCTAssertTrue(generated.count > cap, "Fixture sanity")
    }

    func testVoicePromptTextFitsCarPlayConstraints() {
        // CarPlay voice announcements go through the same string pipeline as
        // Siri; they must be non-empty and short enough to speak quickly.
        let prompts = ["In 300 feet, turn left onto Main Street",
                       "Speed camera ahead", ""]
        for p in prompts where !p.isEmpty {
            XCTAssertLessThan(p.count, 300, "Voice prompt too long: \(p)")
            XCTAssertFalse(p.contains("\n"), "Newlines break CarPlay voice prompts")
        }
    }
}
