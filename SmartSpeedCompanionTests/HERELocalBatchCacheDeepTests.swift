import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// HERELocalBatchCache (SQLite): the primary O(log n) name+direction
/// lookup, the spatial nearest-neighbor fallback, the RoadNameMatcher
/// validation that stops a nearby-but-different road from being served,
/// zone operations behind the Downloaded Limits feature, and coverage
/// estimation. Uses the shared singleton's real disk store with
/// deterministic cleanup.
final class HERELocalBatchCacheDeepTests: XCTestCase {

    private let cache = HERELocalBatchCache.shared
    private var insertedKeys: [(Double, Double, String)] = []

    override func setUp() {
        super.setUp()
        insertedKeys = []
    }

    override func tearDown() {
        // Remove everything this test inserted (zone delete by exact coords).
        for (lat, lon, name) in insertedKeys {
            cache.deleteZone(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                             radiusMeters: 30)
            _ = name
        }
        super.tearDown()
    }

    private func storeSegment(name: String, direction: String = "", limit: Int,
                              at coord: CLLocationCoordinate2D, pinned: Bool = false) {
        cache.store(roads: [
            CachedRoad(roadName: name, direction: direction, speedLimitMph: limit,
                       latitude: coord.latitude, longitude: coord.longitude,
                       source: "here", pinned: pinned)
        ])
        insertedKeys.append((coord.latitude, coord.longitude, name))
    }

    // MARK: - Name-first lookup

    func testNameLookupCaseAndWhitespaceInsensitive() {
        let coord = CLLocationCoordinate2D(latitude: 33.40001, longitude: -111.90001)
        storeSegment(name: "W Frye Rd", direction: "E", limit: 45, at: coord)

        XCTAssertEqual(cache.lookup(roadName: "w frye   RD", near: coord)?.speedLimitMph, 45)
    }

    func testNameLookupPrefersDriverDirection() {
        let base = CLLocationCoordinate2D(latitude: 33.41001, longitude: -111.91001)
        // Two segments of the same road: eastbound 45, westbound 65.
        storeSegment(name: "Directional Ave", direction: "E", limit: 45,
                     at: GPSFixFactory.advance(base, meters: 10, heading: 90))
        storeSegment(name: "Directional Ave", direction: "W", limit: 65,
                     at: GPSFixFactory.advance(base, meters: 10, heading: 270))

        let eastbound = cache.lookup(roadName: "Directional Ave", bearing: 90, near: base)
        XCTAssertEqual(eastbound?.speedLimitMph, 45, "Easting driver must get the E segment")
        let westbound = cache.lookup(roadName: "Directional Ave", bearing: 270, near: base)
        XCTAssertEqual(westbound?.speedLimitMph, 65, "Westing driver must get the W segment")
    }

    func testNameLookupFallsBackToUndirected() {
        let base = CLLocationCoordinate2D(latitude: 33.42001, longitude: -111.92001)
        storeSegment(name: "Quiet Ln", direction: "", limit: 30, at: base)
        let hit = cache.lookup(roadName: "Quiet Ln", bearing: 45, near: base)
        XCTAssertEqual(hit?.speedLimitMph, 30,
                       "An undirected row must serve any bearing")
    }

    func testNameLookupRejectsDifferentRoad() {
        let coord = CLLocationCoordinate2D(latitude: 33.43001, longitude: -111.93001)
        storeSegment(name: "Alpha Rd", limit: 40, at: coord)
        XCTAssertNil(cache.lookup(roadName: "Beta Rd", near: coord))
    }

    // MARK: - Spatial fallback

    func testNearestWithinRadius() {
        let base = CLLocationCoordinate2D(latitude: 33.44001, longitude: -111.94001)
        storeSegment(name: "Spatial Rd", direction: "E", limit: 50,
                     at: GPSFixFactory.advance(base, meters: 20, heading: 0))

        let hit = cache.lookupNearest(to: base, radiusMeters: 50, bearing: 90)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.speedLimitMph, 50)
    }

    func testNearestOutsideRadiusIsNil() {
        let base = CLLocationCoordinate2D(latitude: 33.45001, longitude: -111.95001)
        storeSegment(name: "Far Rd", limit: 50, at: GPSFixFactory.advance(base, meters: 120, heading: 0))
        XCTAssertNil(cache.lookupNearest(to: base, radiusMeters: 50),
                     "120 m away must fall outside the 50 m default radius")
    }

    /// The combined lookup validates spatial hits against the requested
    /// road name — this is the anti-bbox-engulfment guard.
    func testCombinedLookupValidatesSpatialHitAgainstName() {
        let base = CLLocationCoordinate2D(latitude: 33.46001, longitude: -111.96001)
        // A different road 20 m away.
        storeSegment(name: "Highway 202", direction: "", limit: 65,
                     at: GPSFixFactory.advance(base, meters: 20, heading: 0))

        // Asking for "Local Rd" with spatial fallback must NOT serve
        // Highway 202's answer.
        let hit = cache.lookup(coordinate: base, roadName: "Local Rd", bearing: 90)
        XCTAssertNil(hit, "A spatial hit on a different road must be rejected by name validation")
    }

    func testCombinedLookupServesMatchingName() {
        let base = CLLocationCoordinate2D(latitude: 33.47001, longitude: -111.97001)
        storeSegment(name: "Valid Rd", direction: "E", limit: 40,
                     at: GPSFixFactory.advance(base, meters: 15, heading: 0))
        let hit = cache.lookup(coordinate: base, roadName: "Valid Rd", bearing: 90)
        XCTAssertEqual(hit?.speedLimitMph, 40)
    }

    // MARK: - Zone operations

    func testCountInZoneAndDeleteZone() {
        let center = CLLocationCoordinate2D(latitude: 33.48001, longitude: -111.98001)
        for i in 0..<5 {
            storeSegment(name: "Zone Rd \(i)", limit: 35,
                         at: GPSFixFactory.advance(center, meters: Double(i) * 10, heading: 90))
        }
        let count = cache.countInZone(center: center, radiusMeters: 100)
        XCTAssertGreaterThanOrEqual(count, 5, "All five seeded rows must be inside the zone")

        cache.deleteZone(center: center, radiusMeters: 100)
        let after = cache.countInZone(center: center, radiusMeters: 100)
        XCTAssertEqual(after, 0, "Zone delete must remove every seeded row")
        insertedKeys.removeAll()
    }

    func testPinnedFlagPersistsThroughSetPinned() {
        let center = CLLocationCoordinate2D(latitude: 33.49001, longitude: -111.99001)
        storeSegment(name: "Pin Rd", limit: 45, at: center)
        cache.setPinned(true, center: center, radiusMeters: 50)
        let hit = cache.lookup(roadName: "Pin Rd", near: center)
        XCTAssertEqual(hit?.pinned, true, "Pinned rows must report pinned=true (TTL exempt)")
        cache.setPinned(false, center: center, radiusMeters: 50)
    }

    // MARK: - Area caching + coverage (geofence decision inputs)

    func testIsAreaCachedFalseForEmptyArea() {
        let empty = CLLocationCoordinate2D(latitude: 36.10001, longitude: -115.10001)
        XCTAssertFalse(cache.isAreaCached(coordinate: empty, radiusMeters: 100),
                       "An area we never cached must report uncached (geofence triggers a batch fetch)")
    }

    func testEstimatedCoverageGrowsWithSeededRows() {
        let center = CLLocationCoordinate2D(latitude: 33.50001, longitude: -112.00001)
        let before = cache.estimatedCoverage(at: center, radiusMeters: 1500)
        for i in 0..<10 {
            storeSegment(name: "Cover Rd \(i)", limit: 40,
                         at: GPSFixFactory.advance(center, meters: Double(i) * 40, heading: 90))
        }
        let after = cache.estimatedCoverage(at: center, radiusMeters: 1500)
        XCTAssertGreaterThanOrEqual(after, before, "Seeding rows must not reduce coverage")
        XCTAssertTrue((0.0...1.0).contains(after))
    }

    // MARK: - HERE-only rows

    func testNonHEREsourceRowsAreNeverServed() {
        let coord = CLLocationCoordinate2D(latitude: 33.51001, longitude: -112.01001)
        cache.store(roads: [
            CachedRoad(roadName: "OSM Rd", speedLimitMph: 35,
                       latitude: coord.latitude, longitude: coord.longitude,
                       source: "osm")
        ])
        XCTAssertNil(cache.lookup(roadName: "OSM Rd", near: coord),
                     "Non-HERE rows must be invisible to lookups")
        XCTAssertNil(cache.lookupNearest(to: coord, radiusMeters: 200))
        cache.deleteZone(center: coord, radiusMeters: 50)
    }
}
