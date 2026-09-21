import XCTest
@testable import SmartSpeedCompanion

/// RoadNameMatcher is the bridge between Apple's geocoded road names and
/// Esri/HERE route-id strings. Its score hierarchy decides whether a cached
/// answer belongs to the road the driver is actually on — the S-202-bbox
/// bug class lives or dies here. The tables must mirror
/// `website/server.py` (`_route_numeric_part`, `_tier2_numeric_match_allowed`)
/// 1:1.
final class RoadNameMatcherScoringTests: XCTestCase {

    // MARK: - Tier 1: canonical equality (1.0)

    func testExactCanonicalMatch() {
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "FRYE RD", sqliteRouteId: "FRYE RD"), 1.0)
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "West Frye Road", sqliteRouteId: "W FRYE RD"), 1.0,
                       "Direction + suffix normalization must canonicalize both sides")
    }

    func testCaseAndWhitespaceInsensitivity() {
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "  frye   rd ", sqliteRouteId: "FRYE RD"), 1.0)
    }

    // MARK: - Tier 2: token subset (0.85)

    func testTokenSubsetMatch() {
        // City-prefixed route id contains the geocoded name's tokens.
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "FRYE RD", sqliteRouteId: "FRYE RD 07"), 0.85)
    }

    func testSubsetRequiresAllTokens() {
        // Geocoded name has a token the route id lacks → not a subset.
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "FRYE RD EAST", sqliteRouteId: "FRYE RD"), 0.0)
    }

    // MARK: - Tier 3: numeric + family gates (0.7 / 0.5 / 0.0)

    func testInterstateNumericMatchWithFamilyGate() {
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "Interstate 17", sqliteRouteId: "I-17"), 0.7,
                       "Same strict family (I) must score 0.7 on the numeric match")
    }

    func testStrictFamilyMismatchRejects() {
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "US Highway 60", sqliteRouteId: "SR-60"), 0.0,
                       "US vs SR families must never pair on the number alone")
    }

    func testGenericTypeKeywordScoresHalf() {
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "State Route 17", sqliteRouteId: "SR-17"), 0.5)
    }

    func testNumericMismatchRejects() {
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "Interstate 10", sqliteRouteId: "I-17"), 0.0)
    }

    // MARK: - The bug class: bbox engulfment must lose to name matching

    func testS202BboxScenarioLosesToFrye() {
        // Driving on West Frye Rd near the SR-202 bbox: the name score
        // against Frye must beat the spatial-adjacency answer from S 202.
        let frye = RoadNameMatcher.score(geocodedName: "West Frye Road", sqliteRouteId: "07 FRYE RD")
        let s202 = RoadNameMatcher.score(geocodedName: "West Frye Road", sqliteRouteId: "S 202")
        XCTAssertGreaterThan(frye, s202, "Name match must decisively beat an unrelated bbox road")
        XCTAssertGreaterThan(frye, 0.5)
        XCTAssertEqual(s202, 0.0)
    }

    // MARK: - Normalization table

    func testSuffixAliasesExpand() {
        XCTAssertEqual(RoadNameMatcher.normalize("Frye ROAD"), RoadNameMatcher.normalize("Frye RD"))
        XCTAssertEqual(RoadNameMatcher.normalize("Main STREET"), RoadNameMatcher.normalize("Main ST"))
        XCTAssertEqual(RoadNameMatcher.normalize(" Camel BACK PKWY "), RoadNameMatcher.normalize("Camelback PARKWAY"))
    }

    func testDirectionPrefixesStrip() {
        XCTAssertEqual(RoadNameMatcher.normalize("West Frye Rd"), "FRYE RD")
        XCTAssertEqual(RoadNameMatcher.normalize("N 7TH ST"), "7TH ST")
        XCTAssertEqual(RoadNameMatcher.normalize("SOUTHWEST 5th Ave"), "5TH AVE")
    }

    func testNumericLeadingPrefixStrips() {
        XCTAssertEqual(RoadNameMatcher.normalize("07 FRYE RD"), "FRYE RD",
                       "AZ HPMS numeric prefixes must strip")
    }

    func testTrailingTerminusZeroStrips() {
        XCTAssertEqual(RoadNameMatcher.normalize("S 202 0"), "S 202",
                       "HPMS trailing ' 0' terminus marker must strip")
    }

    func testCompoundHighwayIds() {
        XCTAssertEqual(RoadNameMatcher.normalize("I 010"), RoadNameMatcher.normalize("I-10"))
        XCTAssertEqual(RoadNameMatcher.normalize("I-10 W"), RoadNameMatcher.normalize("I-10"),
                       "Trailing direction suffix must strip")
    }

    func testAliasTableContents() {
        // The tables are mirrored in Python — pin their shape.
        XCTAssertEqual(RoadNameMatcher.SUFFIX_ALIASES["ROAD"], "RD")
        XCTAssertEqual(RoadNameMatcher.SUFFIX_ALIASES["BOULEVARD"], "BLVD")
        XCTAssertEqual(RoadNameMatcher.SUFFIX_ALIASES["EXPRESSWAY"], "EXPY")
        XCTAssertEqual(RoadNameMatcher.STRICT_FAMILY_KEYWORDS["INTERSTATE"], "I")
        XCTAssertEqual(RoadNameMatcher.STRICT_FAMILY_KEYWORDS["US HIGHWAY"], "US")
        XCTAssertTrue(RoadNameMatcher.DIRECTION_PREFIXES.contains("NW"))
        XCTAssertTrue(RoadNameMatcher.DIRECTION_PREFIXES.contains("SOUTHEAST"))
    }

    // MARK: - Nil/empty safety

    func testNilAndEmptyInputsScoreZero() {
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: nil, sqliteRouteId: "FRYE RD"), 0.0)
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "FRYE RD", sqliteRouteId: nil), 0.0)
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: "", sqliteRouteId: "FRYE RD"), 0.0)
        XCTAssertEqual(RoadNameMatcher.score(geocodedName: nil, sqliteRouteId: nil), 0.0)
    }

    // MARK: - Score monotonicity property

    func testScoresStayInUnitRange() {
        let pairs: [(String, String)] = [
            ("A", "A"), ("A", "B"), ("Interstate 10", "I-10"), ("US 60", "SR-60"),
            ("W Frye Rd", "07 FRYE RD"), ("Rd", "RD"), ("1", "1"), ("I-10 W", "I 010"),
        ]
        for (a, b) in pairs {
            let score = RoadNameMatcher.score(geocodedName: a, sqliteRouteId: b)
            XCTAssertTrue((0.0...1.0).contains(score), "Score out of range for \(a)/\(b)")
        }
    }
}
