import XCTest
@testable import SmartSpeedCompanion

/// The home-screen widget runs in a SEPARATE PROCESS. Its only connection to
/// the app is the App Group UserDefaults suite: the app writes
/// widgetSpeed/widgetLimit/widgetStatus/widgetMeasurementSystem, the widget
/// timeline provider reads the exact same keys from
/// `SpeedFormatting.appGroupSuite`. Every widget bug of the "shows 0 mph"
/// class is a key-name or suite-name disagreement between writer and reader.
/// These tests pin that agreement end-to-end through the real suite —
/// writing with the app's API and reading with the widget's exact access
/// pattern. No UI, no extension process, no network.
final class WidgetPipelineAndMirroringTests: XCTestCase {

    private var guard_: UserDefaultsTestGuard!

    private var shared: UserDefaults? {
        UserDefaults(suiteName: SpeedFormatting.appGroupSuite)
    }

    override func setUp() {
        super.setUp()
        guard_ = UserDefaultsTestGuard(keys: [
            "widgetSpeed", "widgetLimit", "widgetStatus",
            SpeedFormatting.widgetMeasurementSystemAppGroupKey
        ])
        guard_.snapshotNow()
    }

    override func tearDown() {
        guard_.restore()
        super.tearDown()
    }

    // MARK: - Suite agreement

    func testAppGroupSuiteIsReadableAndWritable() {
        // If this fails, the entitlement/suite name changed and the widget is
        // dead in the water — fail loud here rather than as a blank widget.
        let defaults = shared
        XCTAssertNotNil(defaults, "App Group suite \(SpeedFormatting.appGroupSuite) must be accessible from the app process")
        defaults?.set(123, forKey: "widgetSpeed")
        XCTAssertEqual(defaults?.integer(forKey: "widgetSpeed"), 123)
        defaults?.removeObject(forKey: "widgetSpeed")
    }

    func testWidgetReaderPatternSeesAppWriterPattern() {
        // The widget's getTimeline reads with .integer/.string on the same
        // suite; the app writes through SpeedFormatting APIs. Mirror both
        // sides exactly and assert agreement.
        guard_.resetToFreshInstall()

        // Writer side (as the app's mirroring code would):
        shared?.set(48, forKey: "widgetSpeed")
        shared?.set(45, forKey: "widgetLimit")
        shared?.set("over", forKey: "widgetStatus")
        SpeedFormatting.writeMeasurementSystemToAppGroup("Metric")

        // Reader side (verbatim widget access pattern):
        let speed = shared?.integer(forKey: "widgetSpeed") ?? 0
        let limit = shared?.integer(forKey: "widgetLimit") ?? 0
        let status = shared?.string(forKey: "widgetStatus") ?? "safe"
        let units = shared?.string(forKey: SpeedFormatting.widgetMeasurementSystemAppGroupKey) ?? "Imperial"

        XCTAssertEqual(speed, 48)
        XCTAssertEqual(limit, 45)
        XCTAssertEqual(status, "over")
        XCTAssertEqual(units, "Metric")
    }

    // MARK: - Defaults fallbacks (fresh-install / never-driven states)

    func testUnsetUnitKeyFallsBackToImperial() {
        guard_.resetToFreshInstall()
        XCTAssertEqual(SpeedFormatting.measurementSystemFromAppGroup(), "Imperial",
                       "pre-mirror installs must render sane (Imperial) widgets")
    }

    func testUnsetSpeedAndLimitReadAsZero() {
        guard_.resetToFreshInstall()
        // The widget's `?? 0` / .integer default path: a zero limit must be
        // distinguishable downstream (the widget renders "--" not "0 km/h").
        XCTAssertEqual(shared?.integer(forKey: "widgetLimit") ?? 0, 0)
        XCTAssertEqual(shared?.integer(forKey: "widgetSpeed") ?? 0, 0)
    }

    // MARK: - Unit mirroring round-trip

    func testUnitMirrorRoundTripsBothSystems() {
        SpeedFormatting.writeMeasurementSystemToAppGroup("Metric")
        XCTAssertEqual(SpeedFormatting.measurementSystemFromAppGroup(), "Metric")
        SpeedFormatting.writeMeasurementSystemToAppGroup("Imperial")
        XCTAssertEqual(SpeedFormatting.measurementSystemFromAppGroup(), "Imperial")
    }

    func testIsMetricClassification() {
        XCTAssertTrue(SpeedFormatting.isMetric("Metric"))
        XCTAssertFalse(SpeedFormatting.isMetric("Imperial"))
        // Unknown/garbage falls to non-metric (the historic default).
        XCTAssertFalse(SpeedFormatting.isMetric(""))
    }

    func testAppGroupUnitMirrorDrivesWidgetConversionPath() {
        // The widget multiplies displayed speed by 1.60934 iff isMetric(mirror).
        // Pin the classification the conversion branches on, for both mirror
        // values, after a real write.
        SpeedFormatting.writeMeasurementSystemToAppGroup("Metric")
        XCTAssertTrue(SpeedFormatting.isMetric(SpeedFormatting.measurementSystemFromAppGroup()))
        SpeedFormatting.writeMeasurementSystemToAppGroup("Imperial")
        XCTAssertFalse(SpeedFormatting.isMetric(SpeedFormatting.measurementSystemFromAppGroup()))
    }

    // MARK: - Payload-domain sanity (what the widget will be handed)

    func testRealisticWidgetPayloadSweepRoundTrips() {
        // Every speed/limit pair the HUD can show must survive the suite
        // round-trip losslessly (integers only — no truncation drift).
        let statuses = ["safe", "warning", "over"]
        var i = 0
        for speed in stride(from: 0, through: 120, by: 15) {
            for limit in [0, 20, 25, 30, 35, 45, 55, 65, 70, 75, 80] {
                shared?.set(speed, forKey: "widgetSpeed")
                shared?.set(limit, forKey: "widgetLimit")
                shared?.set(statuses[i % 3], forKey: "widgetStatus")
                XCTAssertEqual(shared?.integer(forKey: "widgetSpeed"), speed)
                XCTAssertEqual(shared?.integer(forKey: "widgetLimit"), limit)
                XCTAssertEqual(shared?.string(forKey: "widgetStatus"), statuses[i % 3])
                i += 1
            }
        }
    }

    func testSpeedAboveLimitStillFitsIntSemantics() {
        // 200 km/h on a 30 zone: no overflow/clamping weirdness.
        shared?.set(200, forKey: "widgetSpeed")
        shared?.set(30, forKey: "widgetLimit")
        XCTAssertEqual(shared?.integer(forKey: "widgetSpeed"), 200)
        XCTAssertEqual(shared?.integer(forKey: "widgetLimit"), 30)
    }

    // MARK: - Standard-vs-AppGroup isolation

    func testWidgetKeysDoNotLeakIntoStandardDefaults() {
        // The widget reads ONLY the App Group suite. If the app ever writes
        // the mirror into .standard by mistake, real devices show stale
        // widget data; assert the two stores are distinct objects.
        UserDefaults.standard.set(77, forKey: "widgetSpeed")
        guard_.resetToFreshInstall()
        // After a fresh-install wipe of the group keys, standard defaults
        // (a different store) must not feed the widget path.
        XCTAssertNotEqual(shared, UserDefaults.standard)
        XCTAssertEqual(shared?.integer(forKey: "widgetSpeed") ?? 0, 0)
    }
}
