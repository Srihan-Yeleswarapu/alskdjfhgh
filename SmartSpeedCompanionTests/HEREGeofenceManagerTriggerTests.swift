import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// HEREGeofenceManager: the just-in-time prefetcher that keeps the driver
/// from ever waiting on a live HERE call. Its triggers are rate-limit
/// critical — the 100 m recheck gate, the isAreaCached short-circuit, and
/// the in-flight guard that prevents batch pile-ups — plus the coverage
/// estimate the Developer UI displays.
@MainActor
final class HEREGeofenceManagerTriggerTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var manager: HEREGeofenceManager!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        manager = HEREGeofenceManager()
    }

    override func tearDown() {
        manager = nil
        hereGate.reopen()
        super.tearDown()
    }

    // MARK: - Constants (source-pinned; they govern batch volume)

    func testRecheckDistanceIs100MetersInSource() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("recheckDistanceMeters: Double = 100"),
                      "Recheck gate must stay 100 m — halving it doubles batch-check frequency")
    }

    func testCacheCheckRadiusIs100MetersInSource() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("cacheCheckRadiusMeters: Double = 100"))
    }

    func testInitialSetupUsesWiderRadiusThanManualRefresh() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("radiusMeters: 2500"),
                      "Initial setup: 2.5 km grid")
        // manualRefresh and the background fetch use the 1500 m default.
        XCTAssertTrue(source.contains("func manualRefresh(around coordinate: CLLocationCoordinate2D) async -> Int"))
    }

    // MARK: - In-flight guard (source contract)

    func testBackgroundFetchGuardPreventsPileUp() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("guard !isFetching else { return }"),
                      "A second batch fetch must not start while one is in flight")
    }

    func testCoverageUpdatesOnFetchCompletion() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("updateCoverage(at: coordinate)"),
                      "Coverage must refresh after every fetch attempt (success or failure)")
    }

    // MARK: - Published state machine

    func testPublishedStateDefaults() {
        XCTAssertFalse(manager.isFetching, "Idle manager must not claim a fetch is running")
        XCTAssertEqual(manager.estimatedCoveragePercent, 0,
                       "Fresh manager has no coverage estimate")
    }

    func testDidCompleteBatchFetchSubjectExists() {
        // Subscribing must not crash and must not fire spuriously.
        var fired = 0
        let cancellable = manager.didCompleteBatchFetch.sink { _ in fired += 1 }
        XCTAssertEqual(fired, 0, "No batch has run; no events may fire")
        cancellable.cancel()
    }

    // MARK: - Manual refresh behavior (no credentials → failure path)

    func testManualRefreshWithoutCredentialsReturnsZero() async {
        let count = await manager.manualRefresh(around: GeoCorpus.intersection)
        XCTAssertEqual(count, 0,
                       "Without credentials the batch provider fails → 0 cached, isFetching must return to false")
        XCTAssertFalse(manager.isFetching,
                       "The defer-wrapped isFetching reset must run even on failure")
    }

    func testPerformInitialSetupWithoutCredentialsReturnsZero() async {
        let count = await manager.performInitialSetup(around: GeoCorpus.intersection)
        XCTAssertEqual(count, 0)
        XCTAssertFalse(manager.isFetching)
    }

    // MARK: - Coverage math via the SQLite cache

    func testCoveragePercentReflectsSeededRows() {
        let cache = HERELocalBatchCache.shared
        let center = CLLocationCoordinate2D(latitude: 33.53001, longitude: -112.03001)
        for i in 0..<20 {
            cache.store(roads: [
                CachedRoad(roadName: "Geofence St \(i)", direction: i.isMultiple(of: 2) ? "E" : "W",
                           speedLimitMph: 40,
                           latitude: GPSFixFactory.advance(center, meters: Double(i) * 30, heading: 90).latitude,
                           longitude: GPSFixFactory.advance(center, meters: Double(i) * 30, heading: 90).longitude,
                           source: "here")
            ])
        }
        let coverage = cache.estimatedCoverage(at: center, radiusMeters: 1500)
        let percent = Int(coverage * 100)
        XCTAssertTrue((0...100).contains(percent))
        // Seeded corridor east of center: coverage must be nonzero.
        XCTAssertGreaterThan(percent, 0, "Seeded rows must raise estimated coverage")
        cache.deleteZone(center: center, radiusMeters: 1500)
    }

    func testIsAreaCachedTrueAfterSeeding() {
        let cache = HERELocalBatchCache.shared
        let center = CLLocationCoordinate2D(latitude: 33.54001, longitude: -112.04001)
        cache.store(roads: [
            CachedRoad(roadName: "Cached Way", speedLimitMph: 45,
                       latitude: center.latitude, longitude: center.longitude, source: "here")
        ])
        XCTAssertTrue(cache.isAreaCached(coordinate: center, radiusMeters: 100),
                      "A seeded area must report cached — the geofence must NOT re-batch here")
        cache.deleteZone(center: center, radiusMeters: 100)
    }

    private func sourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\HEREGeofenceManager.swift"
        #else
        return "SmartSpeedCompanion/Core/HEREGeofenceManager.swift"
        #endif
    }
}
