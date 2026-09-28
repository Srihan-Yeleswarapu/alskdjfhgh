import XCTest
@testable import SmartSpeedCompanion

final class ReroutePolicyTests: XCTestCase {
    func testAlertAcknowledgementStopsActiveAudioAndHaptics() throws {
        let source = try RepoSource.read(alertEngineSourcePath())
        XCTAssertTrue(source.contains("audioAlertActive = false"))
        XCTAssertTrue(source.contains("stopCurrentToneImmediately()"))
        XCTAssertTrue(source.contains("stopSpeedingPulse()"))
    }

    private func alertEngineSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\AlertEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/AlertEngine.swift"
        #endif
    }

    func testNavigationCoordinatorUsesForwardRouteMatching() throws {
        let source = try RepoSource.read(sourcePath())
        XCTAssertTrue(source.contains("private func matchRoute"))
        XCTAssertTrue(source.contains("lastMatchedDistanceAlongRoute"))
    }

    func testStepProgressionRequiresConsecutiveFixes() throws {
        let source = try RepoSource.read(sourcePath())
        XCTAssertTrue(source.contains("pendingStepAdvanceCount >= 2"))
    }

    func testRerouteUsesFastSingleRouteAndTrafficDepartureTime() throws {
        let source = try RepoSource.read(sourcePath())
        XCTAssertTrue(source.contains("request.requestsAlternateRoutes = false"))
        XCTAssertTrue(source.contains("request.departureDate = .now"))
    }

    func testRerouteUsesTheLatestVehicleFixAsOrigin() throws {
        let source = try RepoSource.read(sourcePath())
        XCTAssertTrue(source.contains("latestRerouteLocation?.coordinate"))
    }

    // MARK: - Off-route announcement loop regression (FB: looping voice)

    /// The 2026-09-27 bug: `onRerouteRequest` branched on `isRerouting`, but
    /// the route calculation clears that latch on every completing path — so
    /// it read `false` exactly when the reroute SUCCEEDED, navigation never
    /// started, and the detectors re-fired + re-announced forever.
    func testRerouteStartBranchesOnPublishedRoutesNotTheClearedLatch() throws {
        let vmSource = try RepoSource.read(viewModelPath())
        // The closure must consume the calculation's own result…
        XCTAssertTrue(vmSource.contains("let published = await self.selectDestinationAndCalculateRoutes(to: dest, isRerouting: true)"))
        XCTAssertTrue(vmSource.contains("guard published, let first = self.availableRoutes.first else { return }"))
        // …and the inverted-latch gate must be gone.
        XCTAssertFalse(vmSource.contains("guard self.navigationCoordinator.isRerouting else { return }"))
    }

    /// Both off-route detectors must share one attempt clock: the coarse
    /// detector stays silent while a fine-detector attempt is in flight or
    /// backing off, and the fine detector waits out the cooldown instead of
    /// re-firing every 0.75 s. Without this, a failed reroute loops the
    /// "off route, recalculating" cue on every GPS tick.
    func testBothOffRouteDetectorsShareOneAttemptClock() throws {
        let source = try RepoSource.read(sourcePath())
        XCTAssertTrue(source.contains("private let rerouteAttemptCooldown: TimeInterval = 5.0"))
        // Coarse detector: attempt-clock gate + never fires under an in-flight fine attempt.
        XCTAssertTrue(source.contains("guard Date().timeIntervalSince(lastRerouteTime) >= rerouteAttemptCooldown else { return }"))
        XCTAssertTrue(source.contains("if !self.isRerouting && !isCalculatingReroute {"))
        // Fine detector: the 0.75 s re-fire window is gone.
        XCTAssertTrue(source.contains("if timeSinceLastReroute >= rerouteAttemptCooldown {"))
        XCTAssertFalse(source.contains("timeSinceLastReroute >= 0.75"))
    }

    /// A reroute that completes WITHOUT a replacement route must not silently
    /// re-arm itself — the driver gets one explicit status cue per attempt.
    func testFailedRerouteAnnouncesOncePerAttempt() throws {
        let source = try RepoSource.read(sourcePath())
        let fineDetector = try section(in: source, anchor: "public func checkOffRouteStatus")
        XCTAssertTrue(fineDetector.contains("Still off route."))
        XCTAssertTrue(fineDetector.contains("active === routeBeforeAttempt"))
    }

    private func sourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\ViewModels\\NavigationCoordinator.swift"
        #else
        return "SmartSpeedCompanion/ViewModels/NavigationCoordinator.swift"
        #endif
    }

    private func viewModelPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\ViewModels\\DriveViewModel.swift"
        #else
        return "SmartSpeedCompanion/ViewModels/DriveViewModel.swift"
        #endif
    }

    private func section(in source: String, anchor: String) throws -> Substring {
        guard let range = source.range(of: anchor) else {
            XCTFail("Missing anchor: \(anchor)")
            return source[...]
        }
        return source[range.lowerBound...]
    }
}
