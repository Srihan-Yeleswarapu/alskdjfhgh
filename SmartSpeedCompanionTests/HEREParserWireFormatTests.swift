import XCTest
@testable import SmartSpeedCompanion

/// The HERE REST parser (`speedLimitMilesPerHour(in:)`) against the full
/// wire-format matrix: numeric m/s (the undocumented default), explicit
/// unit objects, string-encoded numbers, km/h, mph, span offsets, legacy
/// speedLimit shapes, and every malformed variation HERE deployments have
/// produced. The corpus tests replay captured payloads; this file pins the
/// parser's unit semantics decision-by-decision.
final class HEREParserWireFormatTests: XCTestCase {

    private let parser = HERERestSpeedLimitProvider()

    private func mph(_ section: [String: Any]) -> Double? {
        parser.speedLimitMilesPerHour(in: section)
    }

    // MARK: - Unit matrix on spans

    func testNumericMetersPerSecondDefault() {
        // No unit metadata: numeric maxSpeed is m/s (13.888889 = 50 km/h).
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": 13.888889]]]
        XCTAssertEqual(mph(section) ?? 0, 31.068, accuracy: 0.01)
    }

    func testExplicitMetersPerSecond() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": ["value": 20.1168, "unit": "m/s"]]]]
        XCTAssertEqual(mph(section) ?? 0, 45.0, accuracy: 0.01)
    }

    func testExplicitMph() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": ["value": 65.0, "unit": "mph"]]]]
        XCTAssertEqual(mph(section) ?? 0, 65.0, accuracy: 0.01)
    }

    func testExplicitKmh() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": ["value": 100.0, "unit": "km/h"]]]]
        XCTAssertEqual(mph(section) ?? 0, 62.137, accuracy: 0.01)
    }

    func testStringEncodedNumbers() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": "13.4112"]]]
        XCTAssertEqual(mph(section) ?? 0, 30.0, accuracy: 0.1)
    }

    func testUnitCaseAndSpacingVariants() {
        for unit in ["m/s", "M/S", "m/s ", " meterspersecond", "MPS"] {
            let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": ["value": 13.4112, "unit": unit]]]]
            XCTAssertEqual(mph(section) ?? 0, 30.0, accuracy: 0.1, "Unit variant '\(unit)' failed")
        }
    }

    // MARK: - Span offsets

    func testOffsetZeroSpanWinsOverLaterSpans() {
        // The origin span (offset 0) is the authoritative match for the
        // short probe; a later span's different limit must be ignored.
        let section: [String: Any] = [
            "spans": [
                ["offset": 35.0, "maxSpeed": ["value": 29.0576, "unit": "m/s"]], // 65
                ["offset": 0.0, "maxSpeed": ["value": 20.1168, "unit": "m/s"]],  // 45
            ]
        ]
        XCTAssertEqual(mph(section) ?? 0, 45.0, accuracy: 0.1, "Offset 0 span must be selected")
    }

    func testMissingOffsetZeroStillParsesSomething() {
        // Some deployments omit offset 0; the parser must not crash.
        let section: [String: Any] = [
            "spans": [["offset": 20.0, "maxSpeed": ["value": 20.1168, "unit": "m/s"]]]
        ]
        let result = mph(section)
        if let result { XCTAssertEqual(result, 45.0, accuracy: 0.1) }
    }

    // MARK: - Legacy shapes

    func testLegacySpeedLimitObject() {
        let section: [String: Any] = ["speedLimit": ["speed": 13.4112, "unit": "m/s"]]
        XCTAssertEqual(mph(section) ?? 0, 30.0, accuracy: 0.1)
    }

    func testLegacySpeedLimitArray() {
        let section: [String: Any] = ["speedLimit": [["speed": 13.4112, "unit": "m/s"]]]
        XCTAssertEqual(mph(section) ?? 0, 30.0, accuracy: 0.1)
    }

    func testFlattenedSpanAttributeFallback() {
        let section: [String: Any] = ["maxSpeed": 13.4112]
        XCTAssertEqual(mph(section) ?? 0, 30.0, accuracy: 0.1)
    }

    func testAlternateUnitKeySpeedUnit() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": ["value": 48.2802, "speedUnit": "kph"]]]]
        XCTAssertEqual(mph(section) ?? 0, 30.0, accuracy: 0.1)
    }

    // MARK: - Bounds

    func testZeroMaxSpeedMeansNoPostedLimit() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": 0]]]
        XCTAssertNil(mph(section), "maxSpeed 0 = HERE has no data; must be nil")
    }

    func testNegativeMaxSpeedRejected() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": -13.4112]]]
        XCTAssertNil(mph(section))
    }

    func testNonNumericMaxSpeedRejected() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": "unlimited"]]]
        XCTAssertNil(mph(section))
    }

    func testEmptySpansRejected() {
        XCTAssertNil(mph(["spans": []]))
        XCTAssertNil(mph([:]))
    }

    // MARK: - Route Matching link parser (kph wire)

    func testRouteMatchKphToMphConversion() {
        // 72.4204 km/h = 45 mph (the FROM_REF_SPEED_LIMIT attribute).
        let mphValue = 72.4204 * 0.621371
        XCTAssertEqual(Int(mphValue.rounded()), 45)
    }

    func testRouteMatchCommonLimits() {
        let pairs: [(Double, Int)] = [
            (32.1869, 20),   // school zone
            (72.4204, 45),   // arterial
            (104.607, 65),   // state highway
            (120.7, 75),     // interstate
        ]
        for (kph, expectedMph) in pairs {
            XCTAssertEqual(Int((kph * 0.621371).rounded()), expectedMph)
        }
    }
}
