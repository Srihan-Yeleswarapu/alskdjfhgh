import XCTest
@testable import SmartSpeedCompanion

/// Regression tests for the Siri destination commands:
/// "Hey Siri, set destination to <place> in/through/from Speedio" must run
/// in Speedio instead of falling through to Apple Maps, and the natural
/// preposition variants ("in / through / from / using / with / via Speedio")
/// must all be donatable phrases.
///
/// Root cause context: NavigateToDestinationIntent used a plain-String
/// parameter, which cannot appear in App Shortcut phrases, so the intent was
/// never donated and Siri handed navigation to Apple Maps. The fix uses an
/// AppEntity parameter (resolvable in phrases) inside the 10-shortcut limit.
final class SiriDestinationCommandsTests: XCTestCase {

    // MARK: - The Apple Maps fallthrough fix

    func testNavigateIntentUsesEntityParameterResolvableInPhrases() throws {
        let source = try String(contentsOfFile: intentsSourcePath(), encoding: .utf8)
        // Entity parameter (not a plain String) — the thing that makes the
        // phrase donatable at all.
        XCTAssertTrue(
            source.contains("var destination: DestinationEntity?"),
            "The navigate intent must take a DestinationEntity so 'set destination to <place>' resolves in Speedio."
        )
        XCTAssertFalse(
            source.contains("var destinationName: String"),
            "The old plain-String parameter must be gone; Strings cannot be used in App Shortcut phrases."
        )
        XCTAssertTrue(
            source.contains("static var parameterSummary"),
            "A parameter summary is required for Siri to phrase the destination slot."
        )
        // Spoken-place resolution must land on Speedio's navigation pipeline.
        XCTAssertTrue(
            source.contains("startNavigation(to:"),
            "The intent must start navigation through the app's own pipeline."
        )
        // No request to the system maps app anywhere in the intent.
        let performBody = try sourceSection(in: source, anchor: "struct NavigateToDestinationIntent")
        XCTAssertFalse(
            performBody.contains("MKMapItem.forCurrentLocation().openInMaps"),
            "Navigation must never be handed to Apple Maps."
        )
        XCTAssertFalse(
            performBody.contains("openInMaps"),
            "Navigation must never be handed to Apple Maps."
        )
    }

    func testDestinationEntityResolvesSpokenPlacesAndRecents() throws {
        let source = try String(contentsOfFile: destinationEntitySourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("struct DestinationEntity: AppEntity"), "The destination parameter must be a real AppEntity.")
        XCTAssertTrue(source.contains("struct DestinationEntityQuery: EntityStringQuery"), "Siri resolves spoken places through an EntityStringQuery.")
        // Resolution pipeline: region-biased MapKit search without touching
        // the phone's published search state.
        XCTAssertTrue(source.contains("publishResults: false"), "Siri search must not disturb the phone-side published searchResults.")
        XCTAssertTrue(source.contains("recentSearches"), "Recent searches should back Siri's suggestions when no place is spoken.")
        // Coordinate round-trip so a resolved entity navigates offline.
        XCTAssertTrue(source.contains("static func coordinate(fromID"), "Searched entities must embed coordinates for offline re-resolution.")
    }

    func testAllTenShortcutSlotsUsedWithNavigationFirst() throws {
        let source = try String(contentsOfFile: intentsSourcePath(), encoding: .utf8)
        let count = source.components(separatedBy: "AppShortcut(").count - 1
        XCTAssertEqual(count, 10, "App Shortcuts are hard-capped at 10 per app; the provider must use exactly 10 slots.")
        // The previously-undonated navigation intent must now hold a slot.
        XCTAssertTrue(source.contains("intent: NavigateToDestinationIntent()"), "The navigation intent MUST be donated as an App Shortcut (this was the bug).")
        XCTAssertTrue(source.contains("intent: StopNavigationIntent()"), "Stop navigation should also be a first-class spoken command.")
        // The dropped slot's intent must still exist (name-invocable), just
        // without a phrase donation.
        let summary = try String(contentsOfFile: summaryIntentsSourcePath(), encoding: .utf8)
        XCTAssertTrue(summary.contains("struct GetTodayDriveSummaryIntent"), "The today-summary intent must remain invocable by name.")
    }

    // MARK: - Preposition variants ("in / through / from / using Speedio")

    func testDestinationPhrasesCoverPrepositionVariants() throws {
        let source = try String(contentsOfFile: intentsSourcePath(), encoding: .utf8)
        let providerBody = try sourceSection(in: source, anchor: "struct SpeedAppShortcutsProvider")
        for variant in ["in \\(.applicationName)", "through \\(.applicationName)", "from \\(.applicationName)", "using \\(.applicationName)", "with \\(.applicationName)", "via \\(.applicationName)"] {
            XCTAssertTrue(
                providerBody.contains(variant),
                "Destination phrases must cover the '\(variant)' preposition variant."
            )
        }
        // The exact command from the bug report, verbatim.
        XCTAssertTrue(
            providerBody.contains("Set destination to \\(\\.$destination) in \\(.applicationName)"),
            "The reported command 'set destination to <place> in Speedio' must be a donatable phrase."
        )
    }

    func testStopNavigationIntentEndsNavigationOnlyWhenActive() throws {
        let source = try String(contentsOfFile: intentsSourcePath(), encoding: .utf8)
        let body = try sourceSection(in: source, anchor: "struct StopNavigationIntent")
        XCTAssertTrue(body.contains("guard viewModel.isNavigating"), "Stop must no-op cleanly when not navigating.")
        XCTAssertTrue(body.contains("await viewModel.endNavigation()"), "Stop must end the app's own navigation.")
    }

    // MARK: - Provider metadata accuracy

    func testSiriUsageDescriptionCoversDestinationCommands() throws {
        let project = try String(contentsOfFile: projectYMLPath(), encoding: .utf8)
        XCTAssertTrue(
            project.contains("set a destination, stop navigation"),
            "The Siri usage description should reflect the new destination commands."
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

    private func intentsSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Features\\iOS26\\Siri\\SpeedAppIntents.swift"
        #else
        return "SmartSpeedCompanion/Features/iOS26/Siri/SpeedAppIntents.swift"
        #endif
    }

    private func destinationEntitySourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Features\\iOS26\\Siri\\DestinationEntity.swift"
        #else
        return "SmartSpeedCompanion/Features/iOS26/Siri/DestinationEntity.swift"
        #endif
    }

    private func summaryIntentsSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Features\\iOS26\\Siri\\GetDriveSessionSummaryIntent.swift"
        #else
        return "SmartSpeedCompanion/Features/iOS26/Siri/GetDriveSessionSummaryIntent.swift"
        #endif
    }

    private func projectYMLPath() -> String {
        return "project.yml"
    }
}
