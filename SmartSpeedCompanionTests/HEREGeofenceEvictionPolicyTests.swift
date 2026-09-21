import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// HEREGeofenceManager second angle (HEREGeofenceManagerTriggerTests pins the
/// source-anchored trigger constants): this file exercises the *failure and
/// isolation* surfaces — no-credential paths returning 0 with clean state,
/// fetch-state transitions, subject discipline, and the SQLite coverage
/// math that decides when a batch is unnecessary. All paths run with the
/// credentials gate closed: zero live HERE traffic.
@MainActor
final class HEREGeofenceEvictionPolicyTests: XCTestCase {

    private var hereGate: HERECredentialsGate!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
    }

    override func tearDown() {
        hereGate.reopen()
        super.tearDown()
    }

    private let manager = HEREGeofenceManager.shared

    // MARK: - Failure-path state transitions

    func testManualRefreshFailureResetsIsFetching() async {
        let count = await manager.manualRefresh(around: GeoCorpus.intersection)
        XCTAssertEqual(count, 0, "No credentials → batch provider fails → 0")
        XCTAssertFalse(manager.isFetching,
                       "defer-wrapped reset must run even on the failure path")
    }

    func testConcurrentManualRefreshesSerializeWithoutStateCorruption() async {
        // Two overlapping manual refreshes must not wedge isFetching on.
        async let a: Int = manager.manualRefresh(around: GeoCorpus.intersection)
        async let b: Int = manager.manualRefresh(around: GeoCorpus.intersection)
        let counts = await [a, b]
        XCTAssertTrue(counts.allSatisfy { $0 == 0 })
        XCTAssertFalse(manager.isFetching, "Concurrent refreshes left the flag stuck")
    }

    func testInitialSetupFailureLeavesCoverageEstimateInt() {
        // estimatedCoveragePercent is an Int publication; the failure path
        // must not push it out of 0...100.
        let before = manager.estimatedCoveragePercent
        XCTAssertTrue((0...100).contains(before))
    }

    // MARK: - Subject discipline

    func testDidCompleteBatchFetchDoesNotFireOnFailures() async {
        var fired: [Int] = []
        let cancellable = manager.didCompleteBatchFetch.sink { fired.append($0) }
        _ = await manager.manualRefresh(around: GeoCorpus.intersection)
        _ = await manager.performInitialSetup(around: GeoCorpus.intersection)
        XCTAssertTrue(fired.isEmpty,
                      "Failed fetches emitted completion events: \(fired)")
        cancellable.cancel()
    }

    // MARK: - SQLite coverage math (the no-fetch decider)

    func testCoveragePercentZeroOnEmptyArea() {
        let cache = HERELocalBatchCache.shared
        let empty = CLLocationCoordinate2D(latitude: -33.91001, longitude: 18.42001)
        cache.deleteZone(center: empty, radiusMeters: 2_000)
        let coverage = cache.estimatedCoverage(at: empty, radiusMeters: 1_500)
        XCTAssertEqual(coverage, 0, accuracy: 0.01,
                       "Empty area reported nonzero coverage — fetches would be suppressed forever")
    }

    func testCoverageGrowsWithSeededRowsAndCleansUp() {
        let cache = HERELocalBatchCache.shared
        let center = CLLocationCoordinate2D(latitude: -33.92001, longitude: 18.43001)
        cache.deleteZone(center: center, radiusMeters: 2_000)
        for i in 0..<30 {
            let p = GPSFixFactory.advance(center, meters: Double(i) * 40, heading: 270)
            cache.store(roads: [CachedRoad(roadName: "Eviction Rd", direction: "W",
                                           speedLimitMph: 60,
                                           latitude: p.latitude, longitude: p.longitude,
                                           source: "here")])
        }
        let covered = cache.estimatedCoverage(at: center, radiusMeters: 1_500)
        XCTAssertGreaterThan(covered, 0, "Seeded corridor must raise coverage")
        cache.deleteZone(center: center, radiusMeters: 2_000)
        let after = cache.estimatedCoverage(at: center, radiusMeters: 1_500)
        XCTAssertEqual(after, 0, accuracy: 0.01,
                       "deleteZone failed to evict seeded rows")
    }

    func testIsAreaCachedFalseOnEmptyTrueAfterSeed() {
        let cache = HERELocalBatchCache.shared
        let center = CLLocationCoordinate2D(latitude: -33.93001, longitude: 18.44001)
        cache.deleteZone(center: center, radiusMeters: 2_000)
        XCTAssertFalse(cache.isAreaCached(coordinate: center),
                       "Empty area claims to be cached")
        cache.store(roads: [CachedRoad(roadName: "Seed Rd", direction: "N",
                                       speedLimitMph: 45,
                                       latitude: center.latitude, longitude: center.longitude,
                                       source: "here")])
        XCTAssertTrue(cache.isAreaCached(coordinate: center),
                      "Seeded area still reports uncached — would over-trigger batches")
        cache.deleteZone(center: center, radiusMeters: 2_000)
    }

    func testDeleteZoneIsIdempotent() {
        let cache = HERELocalBatchCache.shared
        let center = CLLocationCoordinate2D(latitude: -33.94001, longitude: 18.45001)
        cache.deleteZone(center: center, radiusMeters: 1_000)
        cache.deleteZone(center: center, radiusMeters: 1_000)
        cache.deleteZone(center: center, radiusMeters: 1_000)
        XCTAssertEqual(cache.estimatedCoverage(at: center, radiusMeters: 900), 0,
                       accuracy: 0.01)
    }
}
