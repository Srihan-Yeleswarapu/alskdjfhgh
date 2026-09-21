import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// SmartSpeedLimitService orchestration contracts: the begin/resolve
/// lifecycle, generation tokens, published source labels, the HERE-only
/// promotion boundary, and the cache-first ordering that protects the
/// freemium budget. The service is a shared singleton with private
/// internals, so orchestration is verified through its published surface
/// plus source-policy checks on the decision tree.
@MainActor
final class SpeedLimitServiceOrchestrationTests: XCTestCase {

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

    private var service: SmartSpeedLimitService { .shared }

    // MARK: - beginResolution

    func testBeginResolutionClearsPublishedAnswer() {
        service.beginResolution()
        XCTAssertEqual(service.currentLimit, 0)
        XCTAssertEqual(service.dataSource, .noData)
    }

    /// A fetch that resolves (even to a miss) publishes through
    /// currentLimit/dataSource. With no credentials + no caches, every
    /// lookup lands in the miss path → No Data.
    func testLookupWithNoCredentialsAndEmptyCachesPublishesNoData() async {
        await SpeedLimitResponseCache.shared.clear()
        service.beginResolution()

        let limit = await service.updateSpeedLimit(
            at: GeoCorpus.intersection,
            heading: 90,
            currentSpeedMph: 45,
            roadName: "Unresolved Rd"
        )
        XCTAssertEqual(limit, 0, "A full miss must publish 0")
        XCTAssertEqual(service.currentLimit, 0)
        XCTAssertEqual(service.dataSource, .noData)
    }

    func testLookupNeverThrowsOnEmptyPipeline() async {
        await SpeedLimitResponseCache.shared.clear()
        // Weird coordinates, negative heading, zero speed — the pipeline
        // must degrade to No Data, not trap.
        let limit = await service.updateSpeedLimit(
            at: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            heading: -1,
            currentSpeedMph: 0,
            roadName: nil
        )
        XCTAssertEqual(limit, 0)
    }

    // MARK: - Cache-first ordering (rate-limit-first)

    func testResponseCacheHitAvoidsProviderChain() async {
        await SpeedLimitResponseCache.shared.clear()
        let coord = GeoCorpus.intersection
        let road = "W Frye Rd"

        // Seed the response cache with a HERE answer.
        await SpeedLimitResponseCache.shared.store(
            SpeedLimitResponse(speedLimitMph: 45, roadKey: "here-rest-45",
                               providerName: "HERE REST", detail: "seeded"),
            at: coord, roadName: road
        )

        // Lookup must come back from the cache (credentials are gone, so a
        // live provider call would return nil — a 45 answer proves cache-first).
        let limit = await service.updateSpeedLimit(
            at: coord, heading: 90, currentSpeedMph: 45, roadName: road
        )
        XCTAssertEqual(limit, 45, "Cache hit must serve without any live provider")
        await SpeedLimitResponseCache.shared.clear()
    }

    func testBatchCacheHitServesWhenResponseCacheMisses() {
        let cache = HERELocalBatchCache.shared
        let coord = CLLocationCoordinate2D(latitude: 33.52001, longitude: -112.02001)
        cache.store(roads: [
            CachedRoad(roadName: "Batch Ave", direction: "E", speedLimitMph: 50,
                       latitude: coord.latitude, longitude: coord.longitude, source: "here")
        ])
        let hit = cache.lookup(coordinate: coord, roadName: "Batch Ave", bearing: 90)
        XCTAssertEqual(hit?.speedLimitMph, 50)
        cache.invalidate(at: coord, roadName: "Batch Ave")
    }

    // MARK: - Published label discipline

    func testPositiveLimitAlwaysCarriesHERELabel() async {
        await SpeedLimitResponseCache.shared.clear()
        let coord = GeoCorpus.intersection
        await SpeedLimitResponseCache.shared.store(
            SpeedLimitResponse(speedLimitMph: 65, roadKey: "here-rest-65",
                               providerName: "HERE REST", detail: "label test"),
            at: coord, roadName: "Label Rd"
        )
        _ = await service.updateSpeedLimit(at: coord, heading: 0,
                                           currentSpeedMph: 60, roadName: "Label Rd")
        if service.currentLimit > 0 {
            XCTAssertTrue(service.dataSource == .liveHERE || service.dataSource == .batchCache,
                          "A positive limit must carry a HERE provenance label, got \(service.dataSource.rawValue)")
        }
        await SpeedLimitResponseCache.shared.clear()
    }

    // MARK: - Manual refresh semantics (source policy)

    func testForceRefreshBypassesCachesInSource() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        // Both cache layers check !forceRefresh before serving.
        let matches = source.components(separatedBy: "if !forceRefresh")
        XCTAssertGreaterThanOrEqual(matches.count - 1, 2,
                                    "Response cache AND batch cache must both honor forceRefresh bypass")
    }

    func testForceRefreshMissInvalidatesPoisonedAnswer() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        let section = try section(in: source, anchor: "if outcome.isMiss")
        XCTAssertTrue(section.contains("if forceRefresh"),
                      "A forced refresh miss must invalidate rather than grace-hold the wrong answer")
        XCTAssertTrue(section.contains("cache.invalidate"),
                      "Forced-refresh miss must invalidate the response cache")
    }

    // MARK: - Miss grace window (source policy)

    func testMissThresholdIsTwenty() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("missThresholdBeforeClear: Int = 20"),
                      "The 20-miss cache-clear threshold is an authoritative researched value; retuning requires a new research note")
    }

    func testRoadChangeShrinksGraceWindow() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("roadChanged ? min(3, missThresholdBeforeClear) : missThresholdBeforeClear"),
                      "A geocoder-reported road change must shrink the grace window from 20 to 3")
    }

    // MARK: - Suspicious-jump constants

    func testContinuityGuardConstantsArePinned() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("SUSPICIOUS_JUMP_MPH: Int = 15"))
        XCTAssertTrue(source.contains("SUSPICIOUS_FETCH_HOLD: Int = 3"))
        XCTAssertTrue(source.contains("PHYSICS_TOLERANCE_MPH: Int = 10"))
        XCTAssertTrue(source.contains("PHYSICS_PRIOR_MARGIN_MPH: Int = 15"))
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
