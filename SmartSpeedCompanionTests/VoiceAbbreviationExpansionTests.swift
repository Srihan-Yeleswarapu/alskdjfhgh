import XCTest
import AVFoundation
@testable import SmartSpeedCompanion

/// The TTS pipeline expands MapKit's abbreviated road names before speaking
/// them ("N SR-101" → "North State Route-101"). Every mapping is a word-
/// boundary regex; the classic failure modes are over-matching inside words
/// ("W" inside "Way", "Dr" inside "Drive") and under-matching trailing
/// periods ("Main St."). These tests pin the full table and its boundary
/// semantics — the user hears every one of these strings on the road.
///
/// DefaultVoiceAnnouncer is exercised only for its non-audio surface
/// (disabled-flag guard, idle state, deactivation safety) so the suite never
/// depends on synthesizer timing.
final class VoiceAbbreviationExpansionTests: XCTestCase {

    private func expand(_ s: String) -> String {
        NavigationCoordinator.expandAbbreviations(s)
    }

    // MARK: - Street-suffix table

    func testStreetSuffixesExpand() {
        XCTAssertEqual(expand("Turn onto Main St"), "Turn onto Main Street")
        XCTAssertEqual(expand("Turn onto Main St."), "Turn onto Main Street")
        XCTAssertEqual(expand("Continue on Oak Ave"), "Continue on Oak Avenue")
        XCTAssertEqual(expand("Merge onto Cedar Rd"), "Merge onto Cedar Road")
        XCTAssertEqual(expand("Bear left onto Birch Dr"), "Bear left onto Birch Drive")
        XCTAssertEqual(expand("Continue on Elm Blvd"), "Continue on Elm Boulevard")
        XCTAssertEqual(expand("Turn right on 3rd Pl"), "Turn right on 3rd Place")
        XCTAssertEqual(expand("Continue along Willow Ln"), "Continue along Willow Lane")
        XCTAssertEqual(expand("Arrive at Juniper Cir"), "Arrive at Juniper Circle")
        XCTAssertEqual(expand("Turn onto Aspen Ct"), "Turn onto Aspen Court")
        XCTAssertEqual(expand("Continue on Summit Ter"), "Continue on Summit Terrace")
        XCTAssertEqual(expand("Follow Desert Pkwy"), "Follow Desert Parkway")
        XCTAssertEqual(expand("Merge onto Loop Fwy"), "Merge onto Loop Freeway")
        XCTAssertEqual(expand("Take the Capitol Expy"), "Take the Capitol Expressway")
        XCTAssertEqual(expand("Continue on Route 66 Hwy"), "Continue on Route 66 Highway")
    }

    // MARK: - Compass prefixes

    func testCompassPointsExpand() {
        XCTAssertEqual(expand("N Central Ave"), "North Central Avenue")
        XCTAssertEqual(expand("S Central Ave"), "South Central Avenue")
        XCTAssertEqual(expand("E Washington St"), "East Washington Street")
        XCTAssertEqual(expand("W Washington St"), "West Washington Street")
        XCTAssertEqual(expand("NE 5th St"), "Northeast 5th Street")
        XCTAssertEqual(expand("NW 5th St"), "Northwest 5th Street")
        XCTAssertEqual(expand("SE 5th St"), "Southeast 5th Street")
        XCTAssertEqual(expand("SW 5th St"), "Southwest 5th Street")
    }

    // MARK: - Route designators

    func testInterstateAndRouteDesignatorsExpand() {
        XCTAssertEqual(expand("I-10 W"), "Interstate 10 West")
        XCTAssertEqual(expand("Take I-17 N"), "Take Interstate 17 North")
        XCTAssertEqual(expand("SR-101"), "State Route-101")
        XCTAssertEqual(expand("CR 42"), "County Route 42")
        XCTAssertEqual(expand("US 60 E"), "U.S. 60 East")
    }

    // MARK: - Boundary safety (the regex over-match class)

    func testWordBoundaryPreventsInsideWordMatches() {
        // W inside "Way", "Westbrook"; Dr inside "Drive"/"Downtown";
        // St inside "Stop"/"1st"; Ave inside "Avenue"; E inside "East".
        XCTAssertEqual(expand("Turn onto Mesa Way"), "Turn onto Mesa Way")
        XCTAssertEqual(expand("Cross Westbrook Pkwy"), "Cross Westbrook Parkway")
        XCTAssertEqual(expand("Drive carefully"), "Drive carefully")
        XCTAssertEqual(expand("Downtown exits 1A and 1B"), "Downtown exits 1A and 1B")
        XCTAssertEqual(expand("Take the 1st exit"), "Take the 1st exit")
        XCTAssertEqual(expand("Stop at the light on 22nd St"), "Stop at the light on 22nd Street")
        XCTAssertEqual(expand("Continue on E Avenue"), "Continue on East Avenue")
        XCTAssertEqual(expand("Follow the signs for Sky Harbor Blvd"), "Follow the signs for Sky Harbor Boulevard")
    }

    func testCompoundNamesExpandEachTokenIndependently() {
        XCTAssertEqual(expand("N W Ave"), "North West Avenue")
        XCTAssertEqual(expand("S Main St to E US 60"), "South Main Street to East U.S. 60")
        XCTAssertEqual(expand("I-10 E to SR-51 N"), "Interstate 10 East to State Route-51 North")
    }

    func testCaseInsensitiveExpansionNormalizesToCanonicalForm() {
        // The regex is case-insensitive; the template is always the canonical
        // capitalized expansion. Pin that so TTS never reads "NORTH" vs
        // "North" inconsistently mid-sentence.
        XCTAssertEqual(expand("n main st"), "North main Street")
        XCTAssertEqual(expand("take i-10 w"), "take Interstate 10 West")
        XCTAssertEqual(expand("SR-101 S"), "State Route-101 South")
    }

    func testExpansionIsIdempotent() {
        let once = expand("Take I-10 E to N Main St")
        XCTAssertEqual(expand(once), once, "re-expanding an expanded string must be a no-op")
    }

    func testPunctuationAndNumbersSurvive() {
        XCTAssertEqual(expand("Exit 27B: W Camelback Rd, 0.5 mi"), "Exit 27B: West Camelback Road, 0.5 mi")
        XCTAssertEqual(expand("In 300 ft, turn left onto 5th Ave"), "In 300 ft, turn left onto 5th Avenue")
        XCTAssertEqual(expand(""), "", "empty instruction must stay empty")
    }

    func testTrailingPeriodFormsExpand() {
        XCTAssertEqual(expand("Head N on Central Ave."), "Head North on Central Avenue.")
        XCTAssertEqual(expand("Merge onto I-10 W."), "Merge onto Interstate 10 West.")
    }

    // MARK: - DefaultVoiceAnnouncer guard rails (no synthesizer dependency)

    func testAnnouncerIdleBeforeAnyCue() {
        let announcer = DefaultVoiceAnnouncer()
        XCTAssertFalse(announcer.isSpeaking, "a fresh announcer must not report speaking")
    }

    func testAnnouncerRespectsVoiceNavDisabledWithoutAudio() {
        let guard_ = UserDefaultsTestGuard(keys: ["voiceNavEnabled"])
        guard_.snapshotNow()
        defer { guard_.restore() }
        UserDefaults.standard.set(false, forKey: "voiceNavEnabled")

        let announcer = DefaultVoiceAnnouncer()
        announcer.announce("Turn onto North Central Avenue")
        // The disabled guard returns before the synthesizer is touched.
        XCTAssertFalse(announcer.isSpeaking)
    }

    func testDeactivateSessionBeforeAnyCueIsSafe() {
        let announcer = DefaultVoiceAnnouncer()
        announcer.deactivateSession()
        XCTAssertFalse(announcer.isSpeaking)
    }
}
