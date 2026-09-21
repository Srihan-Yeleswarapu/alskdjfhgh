import XCTest
@testable import SmartSpeedCompanion

/// Settings/UserDefaults corruption tolerance: @AppStorage-backed settings
/// must behave sanely when unset, corrupted, or out of range — a crash or
/// garbage default here bricks first launch. Uses an ephemeral suite so the
/// host app's real defaults are never touched.
final class SettingsStorageCorruptionToleranceTests: XCTestCase {

    private var domainName: String!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        domainName = "test.settings.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: domainName)
        XCTAssertNotNil(suite)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: domainName)
        super.tearDown()
    }

    // MARK: - Unset-key behavior

    func testUnsetIntegerKeyReturnsZero() {
        XCTAssertEqual(suite.integer(forKey: "userBuffer"), 0,
                       "integer(forKey:) on unset keys must return 0 — callers guard on 0 to apply the spec default")
    }

    func testUnsetBoolKeyReturnsFalse() {
        XCTAssertFalse(suite.bool(forKey: "audioAlertsEnabled"))
    }

    func testUnsetDoubleAndStringAreSane() {
        XCTAssertEqual(suite.double(forKey: "never.set"), 0, accuracy: 1e-12)
        XCTAssertNil(suite.string(forKey: "never.set"))
    }

    func testWriteOnFirstReadConvention() {
        // AlertEngine's convention: alert toggles default true by writing on
        // first read. Verify the convention yields true on a clean domain.
        if suite.object(forKey: "audioAlertsEnabled") == nil {
            suite.set(true, forKey: "audioAlertsEnabled")
        }
        XCTAssertTrue(suite.bool(forKey: "audioAlertsEnabled"))
    }

    // MARK: - Corrupted-value tolerance

    func testStringWhereBoolExpectedDoesNotCrash() {
        suite.set("yes", forKey: "audioAlertsEnabled")
        _ = suite.bool(forKey: "audioAlertsEnabled") // coerces or false; must not crash
    }

    func testDoubleWhereIntegerExpected() {
        suite.set(7.9, forKey: "userBuffer")
        // integer(forKey:) truncates; the buffer slider reads ints.
        XCTAssertEqual(suite.integer(forKey: "userBuffer"), 7)
    }

    // MARK: - Range extremes

    func testHugeIntegerForBufferStaysStorable() {
        suite.set(Int.max / 2, forKey: "userBuffer")
        XCTAssertEqual(suite.integer(forKey: "userBuffer"), Int.max / 2)
    }

    func testNegativeBufferIsStorable() {
        // Negative buffers are nonsense but storage must round-trip exactly;
        // clamping is the app layer's job, not storage's.
        suite.set(-30, forKey: "userBuffer")
        XCTAssertEqual(suite.integer(forKey: "userBuffer"), -30)
    }

    // MARK: - VehicleProfile mirror-key integrity

    func testVehicleProfileMirrorKeysRoundTrip() {
        // VehicleProfile persists per-vehicle copies of @AppStorage keys.
        let p = VehicleProfile(name: "Mirror")
        p.userBuffer = 7
        p.audioAlertsEnabled = false
        p.hapticAlertsEnabled = false
        p.avoidHighways = true
        p.measurementSystem = "Metric"
        p.hapticAlertStyle = "subtle"

        suite.set(p.userBuffer, forKey: "mirror.userBuffer")
        suite.set(p.audioAlertsEnabled, forKey: "mirror.audio")
        suite.set(p.hapticAlertsEnabled, forKey: "mirror.haptic")
        suite.set(p.avoidHighways, forKey: "mirror.avoidHighways")
        suite.set(p.measurementSystem, forKey: "mirror.units")
        suite.set(p.hapticAlertStyle, forKey: "mirror.style")

        XCTAssertEqual(suite.integer(forKey: "mirror.userBuffer"), 7)
        XCTAssertFalse(suite.bool(forKey: "mirror.audio"))
        XCTAssertFalse(suite.bool(forKey: "mirror.haptic"))
        XCTAssertTrue(suite.bool(forKey: "mirror.avoidHighways"))
        XCTAssertEqual(suite.string(forKey: "mirror.units"), "Metric")
        XCTAssertEqual(suite.string(forKey: "mirror.style"), "subtle")
    }

    func testMeasurementSystemVocabularyOnlyTwoValues() {
        for (stored, expectImperial) in [("Imperial", true), ("Metric", false)] {
            suite.set(stored, forKey: "units")
            let v = suite.string(forKey: "units") ?? "Imperial"
            XCTAssertEqual(v == "Imperial", expectImperial)
        }
        // Nonsense stays storable but is detectable by the read site.
        suite.set("nonsense", forKey: "units")
        let v = suite.string(forKey: "units") ?? "Imperial"
        XCTAssertFalse(["Imperial", "Metric"].contains(v))
    }

    // MARK: - Bulk writes

    func testManyKeysWriteReadSymmetric() {
        for i in 0..<1_000 {
            suite.set(Double(i), forKey: "bulk.\(i)")
        }
        for i in stride(from: 0, to: 1_000, by: 97) {
            XCTAssertEqual(suite.double(forKey: "bulk.\(i)"), Double(i))
        }
    }

    func testVolatileDomainIsolationBetweenTests() {
        // Two fresh domains must not share values (suite leakage across
        // tests silently breaks "first launch" assumptions).
        let otherDomain = "test.settings.\(UUID().uuidString)"
        let other = UserDefaults(suiteName: otherDomain)!
        defer { other.removePersistentDomain(forName: otherDomain) }
        suite.set(99, forKey: "shared.key")
        XCTAssertEqual(other.integer(forKey: "shared.key"), 0,
                       "Values leaked across domains")
    }
}
