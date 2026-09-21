import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// The corpus→parser seam: every seed record's Routing v8 section must parse
/// through the REAL `speedLimitMilesPerHour(in:)` into exactly the mph the
/// record advertises. If the boxing (`AnyJSON` → `Any`), the parser's unit
/// dispatch, or the corpus wire values ever drift, every downstream hermetic
/// test would silently reason about wrong data — this file catches that at
/// the source. Second half: adversarial `Any` payloads that hostile or
/// degraded wire data can produce. Zero network: the corpus is in-repo.
final class HEREParserCorpusAndEdgeCaseTests: XCTestCase {

    private let provider = HERERestSpeedLimitProvider()

    private func parse(_ section: [String: Any]) -> Double? {
        provider.speedLimitMilesPerHour(in: section)
    }

    // MARK: - Corpus → real parser (the seam)

    func testEverySeedRecordParsesToItsAdvertisedLimit() throws {
        let records = try HERECorpus.load()
        XCTAssertGreaterThanOrEqual(records.count, 4)
        for record in records {
            guard let section = HERECorpus.routingSection(for: record) else {
                return XCTFail("\(record.id): routingSection missing — corpus record malformed")
            }
            let parsed = parse(section)
            XCTAssertNotNil(parsed, "\(record.id): parser returned nil for corpus section")
            XCTAssertEqual(parsed!, Double(record.speedLimitMph), accuracy: 0.15,
                           "\(record.id): corpus wire value must parse to \(record.speedLimitMph) mph")
        }
    }

    func testCorpusRouteMatchLinksCarryParseableKphValues() throws {
        // The Route Matching format feeds the batch cache. The corpus links
        // must stay wire-shaped: array of dicts with a numeric-string kph.
        let records = try HERECorpus.load()
        for record in records {
            guard let link = HERECorpus.routeMatchLink(for: record) else {
                return XCTFail("\(record.id): routeMatchLink missing")
            }
            let fcRows = link["SPEED_LIMITS_FCn"] as? [[String: Any]]
            XCTAssertNotNil(fcRows, "\(record.id): SPEED_LIMITS_FCn must be an array of dicts")
            let row = fcRows?.first
            let kphString = row?["FROM_REF_SPEED_LIMIT"] as? String
            XCTAssertNotNil(kphString, "\(record.id): FROM_REF_SPEED_LIMIT must be a string (HERE wire shape)")
            XCTAssertNotNil(Double(kphString ?? ""), "\(record.id): kph string must parse as a number")
            // And it must convert to the record's advertised mph via the
            // app's kph→mph factor.
            let kph = Double(kphString!)!
            XCTAssertEqual(kph * 0.621371, Double(record.speedLimitMph), accuracy: 0.15,
                           "\(record.id): link kph is inconsistent with advertised mph")
        }
    }

    func testCorpusGeographyIsDenseEnoughForNearestRecordQueries() throws {
        // nearestRecord is the "which answer would this fix have used" query.
        // Two corpus points ~1° apart would make cache tests meaningless.
        let records = try HERECorpus.load()
        let probe = CLLocationCoordinate2D(latitude: 33.3065, longitude: -111.8410)
        let nearest = HERECorpus.nearestRecord(to: probe, in: records)
        XCTAssertNotNil(nearest)
        // The probe sits near the arterial record: nearest must be within
        // ~0.01° (~1 km) of it.
        let dLat = abs(nearest!.latitude - probe.latitude)
        let dLon = abs(nearest!.longitude - probe.longitude)
        XCTAssertLessThan(max(dLat, dLon), 0.01, "nearest-record query resolved to a distant corpus point")
    }

    // MARK: - Adversarial Any payloads (degraded/hostile wire data)

    func testBoolMaxSpeedDoesNotCrashOrProduceGarbage() {
        // `true as? NSNumber` == 1 in Foundation. A hostile payload with a
        // boolean maxSpeed must not crash, produce NaN, or a huge limit.
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": true, "unit": "m/s"]]]
        if let mph = parse(section) {
            XCTAssertLessThanOrEqual(mph, 90, "bool payload escalated to a real-looking limit")
            XCTAssertGreaterThan(mph, 0)
            XCTAssertTrue(mph.isFinite)
        }
        // nil-return is equally acceptable; both beat a garbage number.
    }

    func testNSNullMaxSpeedIsRejected() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": NSNull()]]]
        XCTAssertNil(parse(section), "NSNull must not become a limit")
    }

    func testNaNAndInfinityMaxSpeedAreRejected() {
        let nan: [String: Any] = ["spans": [["offset": 0, "maxSpeed": Double.nan]]]
        let inf: [String: Any] = ["spans": [["offset": 0, "maxSpeed": Double.infinity]]]
        XCTAssertNil(parse(nan), "NaN must be rejected by the isFinite guard")
        XCTAssertNil(parse(inf), "infinity must be rejected by the isFinite guard")
    }

    func testWhitespacePaddedStringAndUnitParse() {
        // Degrading gateways occasionally pad wire strings; the parser trims
        // both the numeric string and the unit token.
        let section: [String: Any] = [
            "spans": [["offset": 0, "maxSpeed": " 20.1168 ", "unit": " m/s "]]
        ]
        let mph = parse(section)
        XCTAssertNotNil(mph)
        XCTAssertEqual(mph!, 45.0, accuracy: 0.2, "padded wire strings must still convert exactly")
    }

    func testUnitAliasesAllConvertToSameAnswer() {
        let aliases = ["m/s", "mps", "meterpersecond", "meterspersecond",
                       "M/S", "Meters Per Second"]
        for alias in aliases {
            let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": 20.1168, "unit": alias]]]
            XCTAssertEqual(parse(section) ?? -1, 45.0, accuracy: 0.2,
                           "unit alias '\(alias)' drifted from 45 mph")
        }
    }

    func testKphAliasesConvertToSameAnswer() {
        let aliases = ["kph", "kmh", "km/h", "kilometersperhour", "KMH"]
        for alias in aliases {
            let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": 72.4204, "unit": alias]]]
            XCTAssertEqual(parse(section) ?? -1, 45.0, accuracy: 0.2,
                           "kph alias '\(alias)' drifted from 45 mph")
        }
    }

    func testUnknownUnitFallsBackToMetersPerSecondContract() {
        // HERE v8 numeric maxSpeed is m/s when no unit metadata is supplied.
        // An unrecognized unit string must NOT silently change that contract.
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": 20.1168, "unit": "furlongs"]]]
        XCTAssertEqual(parse(section) ?? -1, 45.0, accuracy: 0.2,
                       "unknown units must fall back to the m/s wire contract")
    }

    func testEmptyUnitStringBehavesAsNoUnit() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": 20.1168, "unit": ""]]]
        XCTAssertEqual(parse(section) ?? -1, 45.0, accuracy: 0.2, "empty unit must behave like no unit")
    }

    func testHugeButFiniteSpeedIsParsedAndLeftToUpstreamValidation() {
        // 1000 m/s is physical nonsense but finite: the parser's job is
        // conversion, upstream range checks decide display. Pin that the
        // conversion stays finite and monotone, not nil.
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": 1000.0]]]
        let mph = parse(section)
        XCTAssertNotNil(mph)
        XCTAssertEqual(mph!, 1000.0 * 2.23694, accuracy: 0.5)
    }

    func testNegativeZeroSpeedIsRejectedLikeZero() {
        let section: [String: Any] = ["spans": [["offset": 0, "maxSpeed": -0.0]]]
        XCTAssertNil(parse(section), "-0.0 must not become a posted limit")
    }

    func testMixedValidAndInvalidSpansStillResolveToValidOne() {
        // A partially degraded response: first span garbage, second span a
        // valid school-zone 20 mph. The parser must find the valid reading.
        let section: [String: Any] = [
            "spans": [
                ["offset": 0, "maxSpeed": NSNull()],
                ["offset": 100, "maxSpeed": 8.9408, "unit": "m/s"],
                ["offset": 200, "maxSpeed": "not-a-number"]
            ]
        ]
        XCTAssertEqual(parse(section) ?? -1, 20.0, accuracy: 0.15,
                       "degraded spans must not poison the valid reading")
    }

    func testOffsetOrderingPrefersEarliestEvenAgainstStringOffsets() {
        // Offsets may arrive as strings on some gateways. Ordering must use
        // numeric comparison, not string comparison (else "10" < "9").
        let section: [String: Any] = [
            "spans": [
                ["offset": "100", "maxSpeed": 26.8224, "unit": "m/s"],  // 60 mph
                ["offset": "0", "maxSpeed": 8.9408, "unit": "m/s"]      // 20 mph
            ]
        ]
        XCTAssertEqual(parse(section) ?? -1, 20.0, accuracy: 0.15,
                       "string offsets must order numerically: offset 0 wins")
    }
}
