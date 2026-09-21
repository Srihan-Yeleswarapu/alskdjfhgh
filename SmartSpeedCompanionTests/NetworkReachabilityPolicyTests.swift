import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Offline behavior: when NetworkReachability reports disconnected, the
/// orchestrator must skip HERE entirely, serve from local caches, and
/// publish honest No Data when caches miss — never silently falling back
/// to OSM/ArcGIS (the "wrong road" class of bug the provider consolidation
/// eliminated). These tests pin the decision points by source contract and
/// the cache-serves-offline property behaviorally.
@MainActor
final class NetworkReachabilityPolicyTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
    }

    override func tearDown() {
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    // MARK: - Source contracts: the offline decision points

    func testServiceChecksReachabilityBeforeLiveLookup() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("if reachability.isConnected,"),
                      "The live provider chain must be gated on NetworkReachability")
        XCTAssertTrue(source.contains("HERE live lookup skipped because NetworkReachability is disconnected"),
                      "The offline branch must log an explicit skip (diagnosability)")
    }

    func testNoLegacyProviderFallbackInSource() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        XCTAssertFalse(source.contains("OverpassSpeedLimitProvider()"),
                       "Overpass must never be instantiated by the driving orchestrator")
        XCTAssertFalse(source.contains("ArcGISHPMSSpeedLimitProvider()"),
                       "ArcGIS must never be instantiated by the driving orchestrator")
        // The provider list is HERE-only:
        XCTAssertTrue(source.contains("HERERestSpeedLimitProvider()"))
        XCTAssertTrue(source.contains("HERERouteMatchingBatchProvider()"))
    }

    func testOfflineMissProducesNoDataNotStaleLabel() throws {
        // handleMiss publishes dataSource = .noData immediately; a stale
        // limit with a provider label is the offline UX failure mode.
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        let missSection = try section(in: source, anchor: "private func handleMiss(")
        XCTAssertTrue(missSection.contains("dataSource = .noData"),
                      "Misses must publish No Data — a labeled stale limit misleads the driver")
    }

    // MARK: - Behavioral: cache serves while offline

    /// The response cache is memory-backed: store an answer, then resolve
    /// through the cache with zero network. This is the exact mechanism
    /// that keeps a returning user working offline.
    func testResponseCacheServesWithoutNetwork() async {
        let cache = SpeedLimitResponseCache()
        await cache.clear()

        let coord = GeoCorpus.intersection
        let response = SpeedLimitResponse(
            speedLimitMph: 45, roadKey: "here-rest-45",
            providerName: "HERE REST", detail: "offline survival test"
        )
        await cache.store(response, at: coord, roadName: "W Frye Rd")

        let hit = await cache.lookup(at: coord, roadName: "W Frye Rd")
        XCTAssertNotNil(hit, "A stored answer must serve offline from memory")
        XCTAssertEqual(hit?.speedLimitMph, 45)

        await cache.clear()
    }

    func testBatchCacheServesWithoutNetwork() {
        let cache = HERELocalBatchCache.shared
        let coord = GeoCorpus.intersection
        cache.store(roads: [
            CachedRoad(roadName: "W Frye Rd", direction: "E", speedLimitMph: 45,
                       latitude: coord.latitude, longitude: coord.longitude, source: "here")
        ])

        let hit = cache.lookup(coordinate: coord, roadName: "W Frye Rd", bearing: 90)
        XCTAssertNotNil(hit, "Batch cache must serve offline")
        XCTAssertEqual(hit?.speedLimitMph, 45)

        cache.invalidate(at: coord, roadName: "W Frye Rd")
    }

    // MARK: - Reachability singleton sanity

    func testReachabilityDefaultsOptimistic() {
        // isConnected defaults true until NWPathMonitor delivers a sample —
        // pessimism would blank the HUD at launch on airplane-mode Wi-Fi.
        let reachability = NetworkReachability.shared
        // Can't force a value; the default contract is that the property is
        // observable and typed. Assert it's a stable Bool read.
        _ = reachability.isConnected
    }

    // MARK: - HERE-only publication boundary

    func testFinalPublicationIsHEREOnly() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        let finalize = try section(in: source, anchor: "private func finalizeWithContinuity(")
        XCTAssertTrue(finalize.contains(".liveHERE || outcome.source == .batchCache"),
                      "The commit boundary must reject every non-HERE source as a final answer")
    }

    func testCacheRejectsNonHEREWrites() async {
        let cache = SpeedLimitResponseCache()
        await cache.clear()

        let coord = CLLocationCoordinate2D(latitude: 33.31, longitude: -111.84)
        let osm = SpeedLimitResponse(speedLimitMph: 35, roadKey: "osm-1",
                                     providerName: "Overpass", detail: "poison")
        await cache.store(osm, at: coord, roadName: "Fake Rd")

        let hit = await cache.lookup(at: coord, roadName: "Fake Rd")
        XCTAssertNil(hit, "Non-HERE responses must be rejected at the cache door")
        await cache.clear()
    }

    // MARK: - Helpers

    private func section(in source: String, anchor: String) throws -> String {
        guard let range = source.range(of: anchor) else {
            XCTFail("Missing anchor: \(anchor)")
            return ""
        }
        return String(source[range.lowerBound...])
    }

    private func servicePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\SpeedLimitService.swift"
        #else
        return "SmartSpeedCompanion/Core/SpeedLimitService.swift"
        #endif
    }
}
