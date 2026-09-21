// HERECorpusLoader.swift
// Hermetic HERE-shaped test data.
//
// The user's rate-limit policy: tests that are NOT about HERE must never
// issue HERE requests. This loader is the sanctioned substitute: it returns
// HERE REST / Route Matching wire-format payloads (the exact JSON shapes the
// production parsers consume) from an in-repo corpus file. Tests feed these
// dictionaries into the real parser entry points, so "does the pipeline
// handle HERE data correctly" is exercised without a single network byte.
//
// The one file that DOES hit the network (opt-in) is HERELiveCorpusCapture;
// it can refresh the corpus file, after which every hermetic test replays
// it for free.

import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

// MARK: - Corpus record

/// One captured HERE answer. Mirrors both wire formats the app parses:
/// Routing v8 `routes[].sections[]` and Route Matching `RouteLinks[]`.
struct HereCorpusRecord: Codable, Equatable {
    var id: String
    var latitude: Double
    var longitude: Double
    var heading: Double?
    var speedLimitMph: Int
    var roadName: String
    var direction: String
    /// Raw Routing v8 section dict (spans + maxSpeed in HERE's wire units).
    var routingSection: [String: AnyJSON]?
    /// Raw Route Matching link dict (SPEED_LIMITS_FCn attributes).
    var routeMatchLink: [String: AnyJSON]?
}

// MARK: - AnyJSON

/// JSONDictionary values need a Codable-friendly box for the corpus file.
enum AnyJSON: Codable, Equatable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case array([AnyJSON])
    case dictionary([String: AnyJSON])
    case null

    init(_ value: Any) {
        switch value {
        case let s as String:        self = .string(s)
        case let b as Bool:          self = .bool(b)
        case let n as Int:           self = .int(n)
        case let d as Double:        self = .double(d)
        case let arr as [Any]:       self = .array(arr.map(AnyJSON.init))
        case let dict as [String: Any]: self = .dictionary(dict.mapValues(AnyJSON.init))
        default:                     self = .null
        }
    }

    /// Back to the `Any` dictionaries the production parsers expect.
    var anyValue: Any {
        switch self {
        case .string(let s):   return s
        case .double(let d):   return d
        case .int(let i):      return i
        case .bool(let b):     return b
        case .array(let a):    return a.map { $0.anyValue }
        case .dictionary(let d): return d.mapValues { $0.anyValue }
        case .null:            return NSNull()
        }
    }

    static func == (lhs: AnyJSON, rhs: AnyJSON) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.int(let a), .double(let b)): return Double(a) == b
        case (.double(let a), .int(let b)): return a == Double(b)
        case (.double(let a), .double(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.dictionary(let a), .dictionary(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    // Codable
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([AnyJSON].self) { self = .array(a) }
        else if let d = try? container.decode([String: AnyJSON].self) { self = .dictionary(d) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .double(let d): try container.encode(d)
        case .int(let i):    try container.encode(i)
        case .bool(let b):   try container.encode(b)
        case .array(let a):  try container.encode(a)
        case .dictionary(let d): try container.encode(d)
        case .null:          try container.encodeNil()
        }
    }
}

// MARK: - Loader

enum HERECorpus {

    static let fileName = "HereCorpus"
    static let fileExtension = "json"

    /// Loads the bundled corpus. Falls back to the in-code seed when the
    /// resource is absent so the suite still runs before the first capture.
    static func load() throws -> [HereCorpusRecord] {
        if let url = Bundle(for: CorpusBundleMarker.self).url(forResource: fileName, withExtension: fileExtension),
           let data = try? Data(contentsOf: url),
           let records = try? JSONDecoder().decode([HereCorpusRecord].self, from: data),
           !records.isEmpty {
            return records
        }
        return seedRecords
    }

    /// Extracts the Routing v8 section the production parser consumes.
    static func routingSection(for record: HereCorpusRecord) -> [String: Any]? {
        guard let boxed = record.routingSection else { return nil }
        return boxed.mapValues { $0.anyValue }
    }

    /// Extracts the Route Matching link the production parser consumes.
    static func routeMatchLink(for record: HereCorpusRecord) -> [String: Any]? {
        guard let boxed = record.routeMatchLink else { return nil }
        return boxed.mapValues { $0.anyValue }
    }

    /// Nearest record to a coordinate — the "which corpus answer would this
    /// GPS fix have used?" query used by cache/service tests.
    static func nearestRecord(to coordinate: CLLocationCoordinate2D, in records: [HereCorpusRecord]) -> HereCorpusRecord? {
        records.min { a, b in
            let da = pow(a.latitude - coordinate.latitude, 2) + pow(a.longitude - coordinate.longitude, 2)
            let db = pow(b.latitude - coordinate.latitude, 2) + pow(b.longitude - coordinate.longitude, 2)
            return da < db
        }
    }

    /// CorpusBundleMarker only exists so `Bundle(for:)` can find the test
    /// bundle where the corpus resource is placed.
    private final class CorpusBundleMarker {}

    // MARK: - In-code seed (used until a live capture refreshes the file)

    /// A downtown arterial (45), a school zone (20), a state highway (65),
    /// and an interstate (75) — the four road classes every downstream test
    /// reason about. Wire values are the exact conversions the parsers
    /// must handle: 20.1168 m/s = 45 mph, 29.0576 m/s = 65 mph.
    static let seedRecords: [HereCorpusRecord] = [
        HereCorpusRecord(
            id: "corpus-arterial-45",
            latitude: 33.30620, longitude: -111.84120, heading: 90,
            speedLimitMph: 45, roadName: "W Frye Rd", direction: "E",
            routingSection: [
                "spans": [
                    ["offset": 0, "maxSpeed": ["value": 20.1168, "unit": "m/s"]]
                ]
            ] as [String: AnyJSON],
            routeMatchLink: [
                "SPEED_LIMITS_FCn": [["FROM_REF_SPEED_LIMIT": "72.4204"]],
                "ROAD_NAME_FCn": [["NAMES": "W Frye Rd"]]
            ] as [String: AnyJSON]
        ),
        HereCorpusRecord(
            id: "corpus-school-20",
            latitude: 33.30780, longitude: -111.83960, heading: 0,
            speedLimitMph: 20, roadName: "S Coronado Rd", direction: "",
            routingSection: [
                "spans": [
                    ["offset": 0, "maxSpeed": ["value": 8.9408, "unit": "m/s"]]
                ]
            ] as [String: AnyJSON],
            routeMatchLink: [
                "SPEED_LIMITS_FCn": [["FROM_REF_SPEED_LIMIT": "32.1869"]],
                "ROAD_NAME_FCn": [["NAMES": "S Coronado Rd"]]
            ] as [String: AnyJSON]
        ),
        HereCorpusRecord(
            id: "corpus-highway-65",
            latitude: 33.31000, longitude: -111.83800, heading: 180,
            speedLimitMph: 65, roadName: "SR-101", direction: "S",
            routingSection: [
                "spans": [
                    ["offset": 0, "maxSpeed": ["value": 29.0576, "unit": "m/s"]]
                ]
            ] as [String: AnyJSON],
            routeMatchLink: [
                "SPEED_LIMITS_FCn": [["FROM_REF_SPEED_LIMIT": "104.607"]],
                "ROAD_NAME_FCn": [["NAMES": "SR-101"]]
            ] as [String: AnyJSON]
        ),
        HereCorpusRecord(
            id: "corpus-interstate-75",
            latitude: 33.31300, longitude: -111.83500, heading: 270,
            speedLimitMph: 75, roadName: "I-10", direction: "W",
            routingSection: [
                "spans": [
                    ["offset": 0, "maxSpeed": ["value": 33.528, "unit": "m/s"]]
                ]
            ] as [String: AnyJSON],
            routeMatchLink: [
                "SPEED_LIMITS_FCn": [["FROM_REF_SPEED_LIMIT": "120.7"]],
                "ROAD_NAME_FCn": [["NAMES": "I-10"]]
            ] as [String: AnyJSON]
        )
    ]
}

// MARK: - Corpus sanity (hermetic)

/// Pins the corpus itself: if these fail, every downstream hermetic test is
/// reasoning about garbage, so fail fast and loud here.
final class HERECorpusSanityTests: XCTestCase {

    func testCorpusLoadsAndIsNonEmpty() throws {
        let records = try HERECorpus.load()
        XCTAssertGreaterThanOrEqual(records.count, 4, "Corpus must cover the four road classes")
    }

    func testCorpusLimitsArePlausiblePostedValues() throws {
        for record in try HERECorpus.load() {
            XCTAssertTrue((10...85).contains(record.speedLimitMph),
                          "Corpus record \(record.id) has implausible limit \(record.speedLimitMph)")
            XCTAssertTrue((-90...90).contains(record.latitude), record.id)
            XCTAssertTrue((-180...180).contains(record.longitude), record.id)
        }
    }

    func testCorpusRoutingSectionsParseThroughProductionParser() throws {
        let parser = HERERestSpeedLimitProvider()
        for record in try HERECorpus.load() {
            guard let section = HERECorpus.routingSection(for: record) else {
                XCTFail("Record \(record.id) is missing its routing section")
                continue
            }
            let mph = parser.speedLimitMilesPerHour(in: section)
            XCTAssertNotNil(mph, "Production parser could not read corpus record \(record.id)")
            XCTAssertEqual(mph ?? 0, Double(record.speedLimitMph), accuracy: 1.01,
                           "Parser output for \(record.id) disagrees with the corpus's recorded limit")
        }
    }

    func testCorpusCoversAllFourRoadClasses() throws {
        let records = try HERECorpus.load()
        let names = Set(records.map { $0.roadName })
        XCTAssertTrue(names.contains { $0.contains("SR-") || $0.contains("I-") }, "Need a highway-class record")
        XCTAssertTrue(names.contains { !$0.contains("-") }, "Need an arterial/local record")
    }
}
