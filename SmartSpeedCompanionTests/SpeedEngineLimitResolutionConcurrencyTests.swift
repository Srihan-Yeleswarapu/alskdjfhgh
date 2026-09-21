import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// The concurrency discipline of limit resolution: GPS fixes arrive faster
/// than network answers, so an older lookup finishing late must never
/// replace the limit for the road the driver is on now. Every rule here
/// maps to a real incident class (stale 25 mph resurrecting after a turn).
@MainActor
final class SpeedEngineLimitResolutionConcurrencyTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!
    private var engine: SpeedEngine!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        engine = SpeedEngine(locationManager: LocationManager())
    }

    override func tearDown() {
        engine = nil
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    // MARK: - Token discipline (the stale-guard surface)

    func testOutOfOrderCompletionsResolveByToken() {
        // Road A: resolution starts (token A).
        let tokenA = engine.beginLimitResolution()
        // Driver turns; road B: resolution starts (token B > A).
        let tokenB = engine.beginLimitResolution()

        // Road A's answer finally lands.
        engine.applyResolvedLimit(25, resolutionToken: tokenA)
        XCTAssertEqual(engine.limit, 0,
                       "A stale answer for road A must be discarded")

        // Road B's answer lands.
        engine.applyResolvedLimit(45, resolutionToken: tokenB)
        XCTAssertEqual(engine.limit, 45)
        XCTAssertTrue(engine.isLimitResolved)
    }

    func testRapidSuccessionKeepsNewestOnly() {
        var tokens: [UInt64] = []
        for _ in 0..<5 { tokens.append(engine.beginLimitResolution()) }
        // Every old token is now dead.
        for (idx, token) in tokens.dropLast().enumerated() {
            engine.applyResolvedLimit(20 + idx, resolutionToken: token)
            XCTAssertEqual(engine.limit, 0, "Token \(idx) is stale; must not publish")
        }
        engine.applyResolvedLimit(70, resolutionToken: tokens.last!)
        XCTAssertEqual(engine.limit, 70)
    }

    func testTokenIncreasesMonotonicallyAcrossReset() {
        let before = engine.beginLimitResolution()
        engine.resetForNewDrive()
        let after = engine.beginLimitResolution()
        XCTAssertGreaterThan(after, before, "Generation must never rewind")
    }

    // MARK: - Source: cancellation on new fixes

    func testNewEligibleFixCancelsPriorTask() throws {
        let source = try String(contentsOfFile: enginePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("speedLimitResolutionTask?.cancel()"),
                      "A newer fix must cancel the in-flight resolution task")
        XCTAssertTrue(source.contains("guard !Task.isCancelled"),
                      "The landing task must check cancellation before publishing")
    }

    func testGenerationCheckedBeforePublishing() throws {
        let source = try String(contentsOfFile: enginePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("self.speedLimitResolutionGeneration == generation"),
                      "Publishing must be generation-checked (belt to the token suspenders)")
    }

    func testResolutionClearsLimitBeforeAwait() throws {
        let source = try String(contentsOfFile: enginePath(), encoding: .utf8)
        let section = try section(in: source, anchor: "lastFetchLocation = location")
        XCTAssertTrue(section.contains("limit = 0"),
                      "The cleared-limit write must happen BEFORE the network await")
        XCTAssertTrue(section.contains("isLimitResolved = false"))
        XCTAssertTrue(section.contains("status = .safe"))
        XCTAssertTrue(section.contains("speedLimitService.beginResolution()"),
                      "The service's published answer must clear atomically with the engine's")
    }

    // MARK: - End-to-end: task-level racing

    /// Two lookups race; the later-started one wins even though the older
    /// one finishes first. Uses real Tasks with controlled ordering.
    func testConcurrentLookupsNewestWins() async {
        await SpeedLimitResponseCache.shared.clear()

        let service = SmartSpeedLimitService.shared
        service.beginResolution()

        // Seed both roads in the response cache with deterministic answers.
        let roadA = CLLocationCoordinate2D(latitude: 33.55001, longitude: -112.05001)
        let roadB = CLLocationCoordinate2D(latitude: 33.56001, longitude: -112.06001)
        await SpeedLimitResponseCache.shared.store(
            SpeedLimitResponse(speedLimitMph: 25, roadKey: "here-rest-25",
                               providerName: "HERE REST", detail: "road A"),
            at: roadA, roadName: "Old Rd"
        )
        await SpeedLimitResponseCache.shared.store(
            SpeedLimitResponse(speedLimitMph: 55, roadKey: "here-rest-55",
                               providerName: "HERE REST", detail: "road B"),
            at: roadB, roadName: "New Rd"
        )

        // Fire A then B concurrently; B must be the published answer.
        async let a = service.updateSpeedLimit(at: roadA, heading: 90,
                                               currentSpeedMph: 30, roadName: "Old Rd")
        async let b = service.updateSpeedLimit(at: roadB, heading: 90,
                                               currentSpeedMph: 50, roadName: "New Rd")
        _ = await a
        let bValue = await b
        XCTAssertEqual(bValue, 55, "The newest request's answer must win the publication race")
        XCTAssertEqual(service.currentLimit, 55)

        await SpeedLimitResponseCache.shared.clear()
    }

    private func section(in source: String, anchor: String) throws -> String {
        guard let range = source.range(of: anchor) else {
            XCTFail("Missing anchor: \(anchor)")
            return ""
        }
        return String(source[range.lowerBound...])
    }

    private func enginePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\SpeedEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/SpeedEngine.swift"
        #endif
    }
}
