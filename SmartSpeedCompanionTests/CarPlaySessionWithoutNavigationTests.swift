import XCTest
@testable import SmartSpeedCompanion

/// Regression coverage for "start session without navigation" on CarPlay:
/// connecting the head unit must immediately begin a placeholder
/// CPNavigationSession that renders the live speed/limit banner — no
/// destination required — and that placeholder must yield cleanly to real
/// turn-by-turn trips without CarPlay's session-identity-less stop callback
/// mistaking the transition for the driver ending navigation.
///
/// Apple only renders the guidance banner after `startNavigationSession(for:)`
/// is called, so the placeholder session IS the feature; every test below
/// guards a contract that keeps it from regressing into either (a) a bare map
/// on connect or (b) phantom navigation teardowns.
final class CarPlaySessionWithoutNavigationTests: XCTestCase {

    // MARK: - Connect-time wiring

    func testSceneDelegateBeginsIdleSessionAfterRootTemplateIsInstalled() throws {
        let source = try String(contentsOfFile: sceneDelegateSourcePath(), encoding: .utf8)
        XCTAssertTrue(
            source.contains("root.beginSessionWithoutNavigationIfNeeded()"),
            "The scene delegate must begin the placeholder session when CarPlay connects."
        )
        let setupBody = try sourceSection(in: source, anchor: "private func setupNavigationRoot(")
        // startNavigationSession is only valid on a template already in the
        // hierarchy, so the idle session must begin AFTER setRootTemplate.
        let setRootIndex = setupBody.range(of: "setRootTemplate(")?.lowerBound
        let beginIndex = setupBody.range(of: "root.beginSessionWithoutNavigationIfNeeded()")?.lowerBound
        XCTAssertNotNil(setRootIndex, "The root template must still be installed on connect.")
        XCTAssertNotNil(beginIndex, "The idle-session begin call must live in setupNavigationRoot.")
        XCTAssertLessThan(setRootIndex!, beginIndex!,
                          "The placeholder session must begin only after the map template is root.")
        // Resume-first ordering: an in-progress phone navigation wins over
        // the placeholder (its guard makes the begin call a no-op anyway,
        // but the ordering documents intent).
        let resumeIndex = setupBody.range(of: "root.resumeActiveNavigationIfAny()")?.lowerBound
        XCTAssertNotNil(resumeIndex, "The iPhone→CarPlay navigation handoff must be preserved.")
        XCTAssertLessThan(resumeIndex!, beginIndex!)
    }

    // MARK: - Placeholder session shape

    func testIdleSessionUsesPlaceholderTripAndGuardsAgainstRealNavigation() throws {
        let source = try String(contentsOfFile: navigationManagerSourcePath(), encoding: .utf8)
        let beginBody = try sourceSection(in: source, anchor: "public func beginSessionWithoutNavigation()")
        XCTAssertTrue(
            beginBody.contains("guard !viewModel.isNavigating, idleSession == nil else { return }"),
            "The placeholder must never start over active navigation or double-start."
        )
        XCTAssertTrue(
            beginBody.contains("MKMapItem.forCurrentLocation()"),
            "The placeholder trip is anchored on the vehicle, not a destination."
        )
        XCTAssertTrue(
            beginBody.contains("mapTemplate.startNavigationSession(for: trip)"),
            "The placeholder must be a real CPNavigationSession — that is the only way Apple renders a session banner."
        )
        // The estimates panel is meaningless without a route and must read
        // zero. The explicit Measurement matters: the shared
        // SpeedFormatting.navigationDistanceMeasurement clamps to a 50 m
        // floor, which would render a phantom "50 m" on the idle panel.
        XCTAssertTrue(
            beginBody.contains("distanceRemaining: Measurement(value: 0, unit: UnitLength.meters)"),
            "The placeholder trip must publish zero remaining distance/time — there is no route, and the shared formatter's 50 m floor would show a phantom distance."
        )
    }

    func testIdleManeuverCardRendersSpeedLimitRoadAndStatus() throws {
        let source = try String(contentsOfFile: navigationManagerSourcePath(), encoding: .utf8)
        let cardBody = try sourceSection(in: source, anchor: "private func refreshIdleManeuverCard()")
        XCTAssertTrue(
            cardBody.contains("Limit \\(displayLimit)"),
            "The banner must show the posted limit next to the speed."
        )
        XCTAssertTrue(
            cardBody.contains("viewModel.currentRoadName"),
            "The banner must include the current road name when resolved."
        )
        for symbol in ["exclamationmark.octagon.fill", "exclamationmark.triangle.fill", "speedometer"] {
            XCTAssertTrue(cardBody.contains(symbol), "Status icon \(symbol) must mirror the alert states.")
        }
        XCTAssertTrue(
            cardBody.contains("idleSession?.upcomingManeuvers = [maneuver]"),
            "The speed sentence must be delivered through the session's maneuver stream."
        )
        // No-op suppression: a stationary car with a steady limit must not
        // churn CarPlay IPC on every 1 Hz speed tick.
        XCTAssertTrue(
            cardBody.contains("lastIdleManeuverText"),
            "Unchanged banner content must skip the maneuver update entirely."
        )
        // Live binding: the card must be fed from the same publishers the
        // phone HUD uses.
        let beginBody = try sourceSection(in: source, anchor: "public func beginSessionWithoutNavigation()")
        XCTAssertTrue(
            beginBody.contains("viewModel.$speed"),
            "The placeholder card must subscribe to the shared DriveViewModel speed."
        )
        XCTAssertTrue(
            beginBody.contains("viewModel.$currentRoadName"),
            "The placeholder card must subscribe to road-name updates."
        )
    }

    // MARK: - Real trip transition

    func testRealTripReplacesIdleSessionBeforeItsOwnSessionStarts() throws {
        let source = try String(contentsOfFile: navigationManagerSourcePath(), encoding: .utf8)
        let startBody = try sourceSection(in: source, anchor: "public func startNavigation(route: MKRoute, destination: MKMapItem)")
        XCTAssertTrue(
            startBody.contains("endIdleSession(forNavigationTransition: true)"),
            "Starting a real trip must finish the placeholder session."
        )
        let endIdleIndex = startBody.range(of: "endIdleSession(forNavigationTransition: true)")?.lowerBound
        let sessionStartIndex = startBody.range(of: "mapTemplate.startNavigationSession(for: trip)")?.lowerBound
        XCTAssertNotNil(endIdleIndex, "Transition hook missing from startNavigation.")
        XCTAssertNotNil(sessionStartIndex, "startNavigation must still create the real session.")
        XCTAssertLessThan(endIdleIndex!, sessionStartIndex!,
                          "The placeholder must be finished BEFORE the real session starts.")
    }

    func testStopEchoLatchIsArmedOnlyForNavigationTransitions() throws {
        let source = try String(contentsOfFile: navigationManagerSourcePath(), encoding: .utf8)
        let endIdleBody = try sourceSection(in: source, anchor: "public func endIdleSession(forNavigationTransition: Bool)")
        XCTAssertTrue(
            endIdleBody.contains("forNavigationTransition && hadSession"),
            "The latch must only arm when a real trip is taking over — a plain teardown has no stop echo to absorb."
        )
        XCTAssertTrue(
            endIdleBody.contains("idleStopEchoGuardWindow"),
            "The latch must be time-boxed, not permanent."
        )
        let releaseBody = try sourceSection(in: source, anchor: "public func releaseIdleSessionIfPresent()")
        XCTAssertFalse(
            releaseBody.contains("idleStopEchoGuardUntil"),
            "Releasing stale bindings must NOT clear the latch — the stop callback checks the latch after releasing bindings."
        )
        XCTAssertTrue(
            source.contains("static let idleStopEchoGuardWindow: TimeInterval = 3"),
            "The echo window must stay short so a real driver stop right after a start is never swallowed."
        )
    }

    // MARK: - Stop-callback disambiguation

    func testStopCallbackReleasesStaleBindingsThenChecksEchoLatch() throws {
        let source = try String(contentsOfFile: rootTemplateSourcePath(), encoding: .utf8)
        let stopBody = try sourceSection(in: source, anchor: "nonisolated func mapTemplateDidStopNavigating")
        // Ordering contract: stale placeholder bindings are dropped first,
        // then the echo latch decides whether this stop is real.
        let releaseIndex = stopBody.range(of: "self.navigationManager.releaseIdleSessionIfPresent()")?.lowerBound
        let latchIndex = stopBody.range(of: "self.navigationManager.isIdleStopEchoGuardActive()")?.lowerBound
        XCTAssertNotNil(releaseIndex, "The stop callback must release stale placeholder bindings.")
        XCTAssertNotNil(latchIndex, "The stop callback must consult the echo latch.")
        XCTAssertLessThan(releaseIndex!, latchIndex!)
        // The pre-existing disconnect guard must survive — a head-unit stop
        // callback during teardown must never end phone-side navigation.
        XCTAssertTrue(
            stopBody.contains("guard self.interfaceController != nil else { return }"),
            "The disconnect guard must be preserved."
        )
        // The driver-stop action must still be wired.
        XCTAssertTrue(
            stopBody.contains("await self.viewModel.navigationCoordinator.endNavigation()"),
            "A genuine driver stop must still end navigation."
        )
    }

    // MARK: - Lifecycle coverage

    func testDisconnectAndNavigationEndTearDownThePlaceholderSession() throws {
        let source = try String(contentsOfFile: navigationManagerSourcePath(), encoding: .utf8)
        let finishBody = try sourceSection(in: source, anchor: "public func finishCurrentSession()")
        XCTAssertTrue(
            finishBody.contains("endIdleSession(forNavigationTransition: false)"),
            "Disconnect must finish the placeholder session or the CPNavigationSession leaks."
        )
        let endNavBody = try sourceSection(in: source, anchor: "public func endNavigation()")
        XCTAssertTrue(
            endNavBody.contains("endIdleSession(forNavigationTransition: false)"),
            "Ending navigation must clear any placeholder state too."
        )
        let deinitBody = try sourceSection(in: source, anchor: "deinit {")
        XCTAssertTrue(
            deinitBody.contains("idleSession?.finishTrip()"),
            "Deallocation must defensively finish the placeholder session."
        )
    }

    func testNavigationEndRestoresIdleSurfaceOnlyWhileCarPlayIsConnected() throws {
        let source = try String(contentsOfFile: navigationManagerSourcePath(), encoding: .utf8)
        let triggerBody = try sourceSection(in: source, anchor: "public func endNavigationTrigger() async")
        XCTAssertTrue(
            triggerBody.contains("beginSessionWithoutNavigation()"),
            "After navigation ends while CarPlay is connected, the speed banner must come back."
        )
        // But NOT from endNavigation() itself: the startedTrip route
        // replacement runs endNavigation() mid-handoff and must not race the
        // incoming trip with a resurrected placeholder.
        let endNavBody = try sourceSection(in: source, anchor: "public func endNavigation()")
        XCTAssertFalse(
            endNavBody.contains("beginSessionWithoutNavigation()"),
            "The placeholder must not be resurrected inside endNavigation() — only via endNavigationTrigger."
        )
    }

    // MARK: - Reachability of the start control

    func testStartStopButtonLeadsMapButtonsForHeadUnitsThatTruncate() throws {
        let source = try String(contentsOfFile: rootTemplateSourcePath(), encoding: .utf8)
        let buttonsBody = try sourceSection(in: source, anchor: "mapTemplate.mapButtons = [")
        XCTAssertTrue(
            buttonsBody.contains("startStopButton,"),
            "Start/Stop must be the first map button: head units render only the first handful (the documented snooze-button truncation), and the driver's primary session control must never be cut off."
        )
    }

    // MARK: - Self-healing surfaces

    func testCancelledTripPreviewRestoresTheIdleSpeedBanner() throws {
        let source = try String(contentsOfFile: rootTemplateSourcePath(), encoding: .utf8)
        XCTAssertTrue(
            source.contains("nonisolated func mapTemplateDidCancelNavigation"),
            "A dismissed/cancelled trip preview must restore the session-without-navigation banner."
        )
        let cancelBody = try sourceSection(in: source, anchor: "nonisolated func mapTemplateDidCancelNavigation")
        // Same safety rails as the stop callback: never fight active
        // navigation, never fire during a transition echo, and respect the
        // disconnect guard.
        XCTAssertTrue(
            cancelBody.contains("guard self.interfaceController != nil else { return }"),
            "The cancel callback must respect the disconnect guard."
        )
        XCTAssertTrue(
            cancelBody.contains("!self.viewModel.isNavigating"),
            "The cancel callback must not resurrect the placeholder over active navigation."
        )
        XCTAssertTrue(
            cancelBody.contains("isIdleStopEchoGuardActive()"),
            "The cancel callback must respect the stop-echo latch."
        )
        XCTAssertTrue(
            cancelBody.contains("self.navigationManager.beginSessionWithoutNavigation()"),
            "The cancel callback must re-begin the idle session."
        )
    }

    func testFrameworkStoppedIdleSessionIsRebuiltWhenNoNavigationIsRunning() throws {
        let source = try String(contentsOfFile: rootTemplateSourcePath(), encoding: .utf8)
        let stopBody = try sourceSection(in: source, anchor: "nonisolated func mapTemplateDidStopNavigating")
        XCTAssertTrue(
            stopBody.contains("self.navigationManager.beginSessionWithoutNavigation()"),
            "When the framework recycles the placeholder while no navigation runs, the stop callback must rebuild the speed banner instead of leaving a dead surface."
        )
    }

    // MARK: - Helpers

    private func sourceSection(in source: String, anchor: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else {
            XCTFail("Missing expected source anchor: \(anchor)")
            return ""
        }
        let body = source[anchorRange.lowerBound...]
        guard let endRange = body.range(of: "\n    }") else {
            XCTFail("Could not locate the end of the section for anchor: \(anchor)")
            return ""
        }
        return String(body[..<endRange.lowerBound])
    }

    private func navigationManagerSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayNavigationManager.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayNavigationManager.swift"
        #endif
    }

    private func rootTemplateSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayNavigationRootTemplate.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayNavigationRootTemplate.swift"
        #endif
    }

    private func sceneDelegateSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlaySceneDelegate.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlaySceneDelegate.swift"
        #endif
    }
}
