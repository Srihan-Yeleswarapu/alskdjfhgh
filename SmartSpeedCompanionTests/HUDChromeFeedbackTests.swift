import XCTest
@testable import SmartSpeedCompanion

/// Regression tests for TestFlight 2.3.0 (b643) feedback
/// (srihan.yeleswarapu@gmail.com): "I typed something into the search bar,
/// but then backspaced all of it, when I did that, then the speed, start
/// button, and speed limit button all came up. Don't do that."
///
/// The bottom HUD (speed readout, START pill, limit sign) and the 2D/3D pill
/// are gated on `driveViewModel.isSearchingLocally` inside `MapWithHUDView`,
/// so emptying the search field must not clear that flag: search mode is only
/// left via a deliberate dismissal (X button, destination selection).
final class HUDChromeFeedbackTests: XCTestCase {

    func testEmptySearchQueryKeepsSearchModeActive() throws {
        let source = try String(contentsOfFile: driveViewModelSourcePath(), encoding: .utf8)
        let updateSearchBody = try sourceSection(in: source, anchor: "public func updateSearchQuery(_ query: String)")
        // `updateSearchQuery` clears completions/results for an empty query
        // but must NOT drop the local-search lock that keeps the HUD hidden.
        XCTAssertFalse(
            updateSearchBody.contains("isSearchingLocally = false"),
            "Emptying the search field must not exit search mode; the bottom HUD (speed, START, limit sign) would snap back over the map while the keyboard is still up."
        )
        XCTAssertTrue(
            updateSearchBody.contains("searchCompletions = []") && updateSearchBody.contains("searchResults = []"),
            "An empty query should still clear the stale completions and results."
        )
    }

    func testEmptySearchSubmitKeepsSearchModeActive() throws {
        let source = try String(contentsOfFile: hudSourcePath(), encoding: .utf8)
        let submitBody = try sourceSection(in: source, anchor: "private func dismissKeyboardForResults")
        // Pressing the keyboard Search button with an empty field collapses
        // the keyboard but must not end the search interaction either.
        XCTAssertFalse(
            submitBody.contains("isSearchingLocally = false"),
            "An empty Search submit only collapses the keyboard; it must not bring the bottom HUD back."
        )
    }

    func testDeliberateSearchExitsRemainInPlace() throws {
        let source = try String(contentsOfFile: hudSourcePath(), encoding: .utf8)
        // The only in-view exits from search mode are the X button and the
        // destination-selection path (`finishSearchSelection`).
        XCTAssertTrue(source.contains("func finishSearchSelection()"))
        XCTAssertTrue(source.contains("accessibilityLabel(\"Cancel search\")"))
        let finishBody = try sourceSection(in: source, anchor: "private func finishSearchSelection")
        XCTAssertTrue(
            finishBody.contains("isSearchingLocally = false"),
            "Destination selection is a deliberate exit and must still clear the search lock."
        )
    }

    func testAddStopsShortcutRowHasNoHorizontalScrolling() throws {
        let source = try String(contentsOfFile: hudSourcePath(), encoding: .utf8)
        let rowBody = try sourceSection(in: source, anchor: "struct NavigationShortcutsRow: View")
        // TestFlight 2.3.0 (b653): swiping the Add Stops pill rubber-banded
        // it side to side. The row must not be a horizontal ScrollView.
        XCTAssertFalse(
            rowBody.contains("ScrollView"),
            "The Add Stops shortcut row must not be wrapped in a horizontal ScrollView — with a single pill the pan gesture just rubber-bands the button."
        )
        XCTAssertTrue(rowBody.contains("showRouteStopsSheet = true"), "The Add Stops entry point must remain wired to the RouteStopsSheet.")
    }

    func testCompassDropsBelowMeasuredTopChromeNotHardcodedEstimate() throws {
        let liveMap = try String(contentsOfFile: liveMapSourcePath(), encoding: .utf8)
        let hud = try String(contentsOfFile: hudSourcePath(), encoding: .utf8)
        // TestFlight 2.3.0 (b653): the hardcoded 155+35+40 drop went stale
        // whenever the card stack gained/lost a row and the compass ended up
        // under the chrome again. The drop must now come from the measured
        // top-chrome bottom (TopChromeBottomKey → driveViewModel.topChromeBottom)
        // converted from global space by the map's own safe-area inset, with
        // the legacy estimate retained only as a pre-first-layout fallback.
        XCTAssertTrue(hud.contains("TopChromeBottomKey"), "MapWithHUDView must measure the top chrome bottom via TopChromeBottomKey.")
        XCTAssertTrue(hud.contains("onPreferenceChange(TopChromeBottomKey.self)"), "The measurement must be published through onPreferenceChange.")
        XCTAssertTrue(liveMap.contains("viewModel.topChromeBottom"), "LiveMapView must consume the measured top-chrome bottom.")
        XCTAssertTrue(liveMap.contains("max(measured - uiView.safeAreaInsets.top, 72)"), "The measured value must be converted from global space and never sit above the search-row rest offset.")
    }

    func testCarPlaySearchLeadsWithPointsOfInterest() throws {
        let source = try String(contentsOfFile: carPlayManagerSourcePath(), encoding: .utf8)
        let rankBody = try sourceSection(in: source, anchor: "nonisolated private static func poiFirstOrderingKey")
        // TestFlight 2.3.0 (b653): CarPlay search for "Tumbleweed" showed the
        // street the car was parked on while the phone's Apple Maps showed
        // Tumbleweed Park & friends. POIs must outrank plain addresses.
        XCTAssertTrue(rankBody.contains("pointOfInterestCategory"), "POI detection must key on the MapKit point-of-interest category.")
        let completionSearch = try sourceSection(in: source, anchor: "public func searchDestination(query: String, completion: @escaping ([MKMapItem]) -> Void)")
        XCTAssertTrue(completionSearch.contains("Self.poiFirst"), "The keystroke search used by CarPlay must apply POI-first ranking before truncating to 10 rows.")
        let asyncSearch = try sourceSection(in: source, anchor: "public func searchDestination(query: String, near coordinate: CLLocationCoordinate2D) async -> [MKMapItem]")
        XCTAssertTrue(asyncSearch.contains("Self.poiFirst"), "The async search variant must apply POI-first ranking before truncating to 5 rows.")
    }

    func testCarPlayShowsNoStopAddedOrNavigationStartedModals() throws {
        let root = try String(contentsOfFile: carPlayRootTemplateSourcePath(), encoding: .utf8)
        // TestFlight 2.3.0 (b653): "NEVER SHOW THIS SCREEN!!" — the stop-added
        // confirmation alert must never come back, and a successful add must
        // still unwind the template stack to the map.
        XCTAssertFalse(
            root.contains("Tap + again to add more stops"),
            "The stop-added confirmation alert must never be presented again; the recalculated route is the acknowledgment."
        )
        XCTAssertFalse(root.contains("showStopAddedConfirmation"), "The removed confirmation path must not be reintroduced.")
        XCTAssertTrue(root.contains("unwindAfterStopAdded"), "A successful stop add must still pop back to the map template.")
        XCTAssertTrue(root.contains("showStopAddFailure"), "Failures must still surface the stop-not-added alert.")
        let named = try String(contentsOfFile: carPlayNamedLocationsSourcePath(), encoding: .utf8)
        // Same noise class: the "Route calculated" interstitial on every
        // navigation start, also with a dead-OK pattern.
        XCTAssertFalse(
            named.contains("Route calculated"),
            "The navigation-started confirmation alert must not come back; the trip preview and maneuver banner are the acknowledgment."
        )
        XCTAssertTrue(named.contains("unwindToMapAfterNavigationStart"), "Navigation start must still pop back to the map template.")
    }

    // MARK: - Helpers

    /// Returns the function body following `anchor` up to its closing brace
    /// at the member indentation level.
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

    private func carPlayManagerSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayNavigationManager.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayNavigationManager.swift"
        #endif
    }

    private func carPlayRootTemplateSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayNavigationRootTemplate.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayNavigationRootTemplate.swift"
        #endif
    }

    private func carPlayNamedLocationsSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayNamedLocationsController.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayNamedLocationsController.swift"
        #endif
    }

    private func liveMapSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Views\\Drive\\LiveMapView.swift"
        #else
        return "SmartSpeedCompanion/Views/Drive/LiveMapView.swift"
        #endif
    }

    private func driveViewModelSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\ViewModels\\DriveViewModel.swift"
        #else
        return "SmartSpeedCompanion/ViewModels/DriveViewModel.swift"
        #endif
    }

    private func hudSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Views\\Drive\\MapWithHUDView.swift"
        #else
        return "SmartSpeedCompanion/Views/Drive/MapWithHUDView.swift"
        #endif
    }
}
