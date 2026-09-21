import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// SpeedLimitResponseCache deep dive: the 0.0005° spatial grid, road-name
/// key folding, 50 m distance sanity, 30-min memory / 30-day disk TTLs,
/// LRU eviction at 500 entries, and the revision guards that keep a slow
/// prefetch from overwriting a fresh store.
final class SpeedLimitResponseCacheDeepTests: XCTestCase {

    private var cache: SpeedLimitResponseCache!

    override func setUp() {
        super.setUp()
        cache = SpeedLimitResponseCache()
    }

    override func tearDown() {
        Task { await cache.clear() }
        super.tearDown()
    }

    private func hereResponse(_ mph: Int, road: String = "Test Rd") -> SpeedLimitResponse {
        SpeedLimitResponse(speedLimitMph: mph, roadKey: "here-rest-\(mph)",
                           providerName: "HERE REST", detail: road)
    }

    // MARK: - Grid keys

    func testGridKeyDeterministicForSameInput() async {
        let coord = GeoCorpus.intersection
        let a = await cache.gridKey(for: coord, roadName: "W Frye Rd")
        let b = await cache.gridKey(for: coord, roadName: "W Frye Rd")
        XCTAssertEqual(a, b, "Same coord + name must hash identically across calls")
    }

    func testGridKeyFoldsRoadName() async {
        let coord = GeoCorpus.intersection
        let withName = await cache.gridKey(for: coord, roadName: "W Frye Rd")
        let otherName = await cache.gridKey(for: coord, roadName: "S Coronado Rd")
        let noName = await cache.gridKey(for: coord)
        XCTAssertNotEqual(withName, otherName, "A cross-street snap in one cell must invalidate")
        XCTAssertNotEqual(withName, noName)
    }

    func testGridKeyBucketsByHalfThousandthDegree() async {
        let base = CLLocationCoordinate2D(latitude: 33.30620, longitude: -111.84120)
        let tiny = CLLocationCoordinate2D(latitude: 33.30620001, longitude: -111.84120001)
        let far = CLLocationCoordinate2D(latitude: 33.30700, longitude: -111.84120)

        let a = await cache.gridKey(for: base)
        let b = await cache.gridKey(for: tiny)
        let c = await cache.gridKey(for: far)
        XCTAssertEqual(a, b, "Sub-millimeter jitter must land in the same cell")
        XCTAssertNotEqual(a, c, "A different cell must hash differently")
    }

    func testInvalidCoordinateProducesSentinelKey() async {
        let key = await cache.gridKey(for: CLLocationCoordinate2D(latitude: 999, longitude: 999))
        XCTAssertEqual(key, "invalid")
    }

    // MARK: - Store → lookup round trip

    func testStoreThenLookupHit() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd")
        let hit = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertEqual(hit?.speedLimitMph, 45)
        XCTAssertEqual(hit?.providerName, "HERE REST")
        await cache.clear()
    }

    func testLookupMissOnDifferentRoadName() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd")
        let hit = await cache.lookup(at: coord, roadName: "Arizona Ave")
        XCTAssertNil(hit, "Same cell, different road: key folding must miss")
        await cache.clear()
    }

    func testLookupMissBeyondFiftyMeters() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd")
        // 80 m east — same grid cell is possible at 0.0005°≈55 m, but the
        // recorded-vs-queried distance sanity (50 m) must reject it.
        let far = GPSFixFactory.advance(coord, meters: 80, heading: 90)
        let hit = await cache.lookup(at: far, roadName: "W Frye Rd")
        XCTAssertNil(hit, "80 m from the recorded point must fail the distance sanity check")
        await cache.clear()
    }

    func testLookupHitWithinFiftyMeters() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd")
        let near = GPSFixFactory.advance(coord, meters: 30, heading: 90)
        let hit = await cache.lookup(at: near, roadName: "W Frye Rd")
        XCTAssertNotNil(hit, "30 m from the recorded point is inside the sanity radius")
        await cache.clear()
    }

    // MARK: - HERE-only write gate

    func testNonHEREStoreIsSilentlyRejected() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        let response = SpeedLimitResponse(speedLimitMph: 35, roadKey: "x",
                                          providerName: "ArcGIS", detail: "legacy")
        await cache.store(response, at: coord, roadName: "W Frye Rd")
        let hit = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertNil(hit)
        await cache.clear()
    }

    // MARK: - Revisions

    func testLowerRevisionCannotOverwriteHigher() async {
        await cache.clear()
        let coord = GeoCorpus.intersection

        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd", revision: 10)
        // An old in-flight store (revision 5) arrives late.
        await cache.store(hereResponse(25), at: coord, roadName: "W Frye Rd", revision: 5)
        let hit = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertEqual(hit?.speedLimitMph, 45,
                       "A late lower-revision store must never clobber the newer answer")
        await cache.clear()
    }

    func testHigherRevisionOverwrites() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd", revision: 10)
        await cache.store(hereResponse(65), at: coord, roadName: "W Frye Rd", revision: 11)
        let hit = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertEqual(hit?.speedLimitMph, 65)
        await cache.clear()
    }

    // MARK: - Invalidation

    func testInvalidateRemovesSingleCell() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd")

        await cache.invalidate(at: coord, roadName: "W Frye Rd")
        let hit = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertNil(hit, "Manual refresh must be able to reject the cached value")
        await cache.clear()
    }

    func testInvalidateRespectsRoadName() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd")
        await cache.invalidate(at: coord, roadName: "Other Rd")
        let hit = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertNotNil(hit, "Invalidating a different road must not touch this cell")
        await cache.clear()
    }

    // MARK: - Clear with revision floor

    func testClearRejectsPreClearRevisions() async {
        await cache.clear()
        let coord = GeoCorpus.intersection
        await cache.store(hereResponse(45), at: coord, roadName: "W Frye Rd", revision: 3)

        await cache.clear(rejectingRevisionsThrough: 3)
        let hit = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertNil(hit, "Entries at or below the clear floor must be dropped")
        // A post-clear store with a higher revision still lands.
        await cache.store(hereResponse(65), at: coord, roadName: "W Frye Rd", revision: 4)
        let fresh = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertEqual(fresh?.speedLimitMph, 65)
        await cache.clear()
    }

    // MARK: - LRU eviction (stress-gated)

    func testLRUEvictionAtFiveHundredEntries() async throws {
        try skipUnlessStressEnabled()
        await cache.clear()
        let base = GeoCorpus.intersection

        // 600 distinct cells → 100 must be evicted.
        for i in 0..<600 {
            let coord = GPSFixFactory.advance(base, meters: Double(i) * 120, heading: 90)
            await cache.store(hereResponse(30 + (i % 40)), at: coord, roadName: "Evict Rd \(i)")
        }
        // The oldest cell (i=0) should be evicted; a recent one survives.
        let oldest = await cache.lookup(at: base, roadName: "Evict Rd 0")
        let recent = await cache.lookup(at: GPSFixFactory.advance(base, meters: 599 * 120, heading: 90),
                                        roadName: "Evict Rd 599")
        XCTAssertNil(oldest, "Oldest entry must be evicted past 500")
        XCTAssertNotNil(recent, "Newest entry must survive")
        await cache.clear()
    }
}
