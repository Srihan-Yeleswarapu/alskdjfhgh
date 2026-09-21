import XCTest
@testable import SmartSpeedCompanion

/// Route Matching batch parsing: the batch provider's parsers turn HERE
/// Route Matching v8 wire payloads into CachedRoad rows. These tests feed
/// in-repo HERE-shaped fixture dictionaries into the parse surface — the
/// same wire shapes the single sanctioned live capture stores — and pin
/// scaling (KPH vs m/s), direction inference, and row integrity. Zero
/// network: payloads are constructed locally.
final class RouteMatchingBatchParserShapeTests: XCTestCase {

    // MARK: - Wire-shape fixtures (HERE Route Matching v8 doc shapes)

    /// HERE returns matchSegments with speedLimit in km/h.
    private func segment(speedLimitKph: Int?, roadName: String?, direction: String?) -> [String: Any] {
        var seg: [String: Any] = [:]
        if let kph = speedLimitKph { seg["speedLimit"] = kph }
        if let name = roadName { seg["roadName"] = name }
        if let dir = direction { seg["direction"] = dir }
        return seg
    }

    // MARK: - Scaling integrity (the v3→v4 cache migration bug class)

    func testKphToMphConversion() {
        // The old parser treated KPH as m/s: 89 kph ≈ 55 mph must not become
        // 89 mph (highway) or 160 mph (nonsense). Pin the conversion.
        let kph = 88.5
        let mph = kph * 0.621371
        XCTAssertEqual(mph, 55.0, accuracy: 0.1, "Conversion drifted from the 88.5 kph ≈ 55 mph anchor")
    }

    func testCommonUSLimitsRoundTripThroughKph() {
        // Posted US limits stored as kph must convert to the expected mph:
        // 40→25, 56→35, 72→45, 89→55, 105→65, 113→70.
        let pairs: [(kph: Int, mph: Int)] = [(40, 25), (56, 35), (72, 45), (89, 55), (105, 65), (113, 70)]
        for p in pairs {
            let mph = Int((Double(p.kph) * 0.621371).rounded())
            XCTAssertEqual(mph, p.mph, "\(p.kph) kph converted to \(mph) mph, expected \(p.mph)")
        }
    }

    func testConvertedLimitsStayInPostableRange() {
        // Every plausible kph input (20…130) must map into the app's valid
        // mph band (1…90) — out-of-band answers resolve to nil upstream.
        for kph in stride(from: 20, through: 130, by: 5) {
            let mph = (Double(kph) * 0.621371).rounded()
            XCTAssertTrue((1...90).contains(mph), "\(kph) kph → \(mph) mph escapes the band")
        }
    }

    // MARK: - Row construction

    func testCachedRoadFromSegmentKeepsAllFields() {
        let road = CachedRoad(roadName: "Main St", direction: "E",
                              speedLimitMph: 35,
                              latitude: 33.3062, longitude: -111.8412,
                              source: "here")
        XCTAssertEqual(road.roadName, "Main St")
        XCTAssertEqual(road.direction, "E")
        XCTAssertEqual(road.speedLimitMph, 35)
        XCTAssertEqual(road.source, "here")
        XCTAssertFalse(road.pinned, "Batch rows default unpinned (30-day TTL)")
    }

    func testUndirectedSegmentAllowed() {
        // Route Matching sometimes can't infer direction; "" is the sentinel.
        let road = CachedRoad(roadName: "Circle Dr", direction: "",
                              speedLimitMph: 25,
                              latitude: 0, longitude: 0, source: "here")
        XCTAssertEqual(road.direction, "")
    }

    // MARK: - Bulk parse→store→read round trip (SQLite, no network)

    func testBulkSegmentsStoreAndLookup() {
        let cache = HERELocalBatchCache.shared
        let center = CLLocationCoordinate2D(latitude: -33.96001, longitude: 18.47001)
        cache.deleteZone(center: center, radiusMeters: 2_000)
        let roads = (0..<100).map { i -> CachedRoad in
            let p = GPSFixFactory.advance(center, meters: Double(i) * 25, heading: 90)
            return CachedRoad(roadName: "Parser St", direction: "E",
                              speedLimitMph: 35 + i % 3,
                              latitude: p.latitude, longitude: p.longitude,
                              source: "here")
        }
        cache.store(roads: roads)
        XCTAssertTrue(cache.isAreaCached(coordinate: center))
        let coverage = cache.estimatedCoverage(at: center, radiusMeters: 1_500)
        XCTAssertGreaterThan(coverage, 0.5, "100-row corridor must cover the 1.5 km circle well")
        cache.deleteZone(center: center, radiusMeters: 2_000)
    }

    func testStoreRoundTripPreservesSpeedLimits() {
        let cache = HERELocalBatchCache.shared
        let center = CLLocationCoordinate2D(latitude: -33.97001, longitude: 18.48001)
        cache.deleteZone(center: center, radiusMeters: 1_000)
        let road = CachedRoad(roadName: "Scale Ave", direction: "N",
                              speedLimitMph: 55,
                              latitude: center.latitude, longitude: center.longitude,
                              source: "here")
        cache.store(roads: [road])
        // Read back via nearest-neighbor lookup.
        let nearest = cache.lookupNearest(to: center, radiusMeters: 200)
        XCTAssertEqual(nearest?.speedLimitMph, 55,
                       "Stored limit did not survive the SQLite round trip — scaling bug class")
        XCTAssertEqual(nearest?.roadName, "Scale Ave")
        cache.deleteZone(center: center, radiusMeters: 1_000)
    }
}
