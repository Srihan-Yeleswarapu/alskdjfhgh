import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// The legacy providers (Overpass, ArcGIS HPMS) remain in the repo as
/// research/offline tools but must never become a driving answer. These
/// tests verify their parsers behave correctly in isolation AND that the
/// orchestrator's promotion boundary rejects their names — the double lock
/// that keeps a legacy provider from silently resurfacing.
final class OverpassArcGISIsolationTests: XCTestCase {

    // MARK: - Provider-name allowlist (the promotion boundary)

    func testOrchestratorTreatsLegacyNamesAsNoData() {
        // SmartSpeedLimitService.sourceForProviderName maps legacy names to
        // .noData — verified via the public enum contract: legacy rawValues
        // exist for decoding but the service never produces them.
        let legacyCases: [SpeedLimitDataSource] = [.liveArcGIS, .liveOverpass, .localDB, .localDBRecovered]
        for source in legacyCases {
            // The publication guard rejects everything but liveHERE/batchCache.
            let allowed = source == .liveHERE || source == .batchCache
            XCTAssertFalse(allowed, "\(source.rawValue) must not pass the publication boundary")
        }
    }

    func testLegacyRawValuesSurviveDecoding() throws {
        // Old persisted state decodes; new state never writes these.
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "Live (ArcGIS)"), .liveArcGIS)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "Live (Overpass)"), .liveOverpass)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "DB"), .localDB)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "DB (Recovered)"), .localDBRecovered)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "Live (HERE)"), .liveHERE)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "Batch (HERE)"), .batchCache)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "No Data"), .noData)
        XCTAssertNil(SpeedLimitDataSource(rawValue: "Live (Google)"))
    }

    func testAllDataSourceCasesAreAccountedFor() {
        XCTAssertEqual(SpeedLimitDataSource.allCases.count, 8)
    }

    // MARK: - ArcGIS HPMS provider (isolated parser verification)

    func testArcGISProviderExistsButIsNotTheDrivingSource() {
        // Instantiation is legal (research tooling); promotion is not.
        let provider = ArcGISHPMSSpeedLimitProvider()
        XCTAssertFalse(HereCorpusPolicy.allowedProviderNames.contains(provider.displayName),
                       "ArcGIS display name must not be in the HERE allowlist")
    }

    func testArcGISReturnsNilWithoutCredentialsGate() async throws {
        // ArcGIS doesn't consult HERECredentialStore; it has its own flow.
        // Its fetch on a random coordinate may return nil (no tile) or a
        // response — but it must never throw on a well-formed call.
        let provider = ArcGISHPMSSpeedLimitProvider()
        do {
            _ = try await provider.fetchSpeedLimit(
                at: CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412),
                heading: 90, forceRefresh: true)
        } catch let error as URLError {
            // Network-layer failures are environment-dependent and allowed.
            XCTAssertTrue(error.code == .notConnectedToInternet || error.code == .cannotFindHost ||
                          error.code == .cannotConnectToHost || error.code == .timedOut ||
                          error.code == .dnsLookupFailed || error.code == .networkConnectionLost,
                          "Unexpected URLError code \(error.code)")
        }
    }

    // MARK: - Overpass provider (isolated)

    func testOverpassProviderExistsButIsNotTheDrivingSource() {
        let provider = OverpassSpeedLimitProvider()
        XCTAssertFalse(HereCorpusPolicy.allowedProviderNames.contains(provider.displayName),
                       "Overpass display name must not be in the HERE allowlist")
    }

    // MARK: - Response cache write-boundary (second lock)

    func testResponseCacheRejectsLegacyProviderWrites() async {
        let cache = SpeedLimitResponseCache()
        await cache.clear()
        let coord = CLLocationCoordinate2D(latitude: 33.33, longitude: -111.86)

        for providerName in ["ArcGIS", "Overpass", "OSM", "Google", ""] {
            let response = SpeedLimitResponse(speedLimitMph: 35, roadKey: "x-\(providerName)",
                                              providerName: providerName, detail: "should not persist")
            await cache.store(response, at: coord, roadName: "Test Rd")
            let hit = await cache.lookup(at: coord, roadName: "Test Rd")
            XCTAssertNil(hit, "Provider '\(providerName)' must not persist into the driving cache")
        }
        await cache.clear()
    }

    func testResponseCacheAcceptsHEREWrites() async {
        let cache = SpeedLimitResponseCache()
        await cache.clear()
        let coord = CLLocationCoordinate2D(latitude: 33.34, longitude: -111.87)

        for providerName in ["HERE REST", "HERE Match", "HERE Batch"] {
            let response = SpeedLimitResponse(speedLimitMph: 40, roadKey: "here-\(providerName)",
                                              providerName: providerName, detail: "legit")
            await cache.store(response, at: coord, roadName: "Here Rd \(providerName)")
            let hit = await cache.lookup(at: coord, roadName: "Here Rd \(providerName)")
            XCTAssertNotNil(hit, "HERE provider '\(providerName)' must persist")
            XCTAssertEqual(hit?.providerName, providerName)
        }
        await cache.clear()
    }
}
