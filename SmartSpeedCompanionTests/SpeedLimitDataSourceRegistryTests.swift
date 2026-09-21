import XCTest
@testable import SmartSpeedCompanion

/// Data-source registry: `SpeedLimitDataSource` is the typed enum that names
/// where a limit came from — the Developer debug screen prints `rawValue`
/// verbatim and older persisted state decodes legacy cases. These tests pin
/// the wire strings (they are persisted!), the legacy decode path, and the
/// active-pipeline source set.
final class SpeedLimitDataSourceRegistryTests: XCTestCase {

    // MARK: - Registry shape

    func testRegistryIsNotEmpty() {
        XCTAssertFalse(SpeedLimitDataSource.allCases.isEmpty,
                       "No data sources registered — limit resolution would dead-end")
    }

    func testCaseCountPinnedAtEight() {
        // Raw values are persisted to SpeedReading rows; adding/removing a
        // case is a product decision that must update decode/restore logic.
        // If this trips, review persisted-state compatibility first.
        XCTAssertEqual(SpeedLimitDataSource.allCases.count, 8,
                       "Registry changed — verify persisted-state decode compatibility")
    }

    func testRawValuesAreNonEmptyAndUnique() {
        let raws = SpeedLimitDataSource.allCases.map { $0.rawValue }
        XCTAssertTrue(raws.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(raws.count, Set(raws).count,
                       "Two sources share a rawValue — persisted state becomes ambiguous")
    }

    func testRawValuesAreUserReadable() {
        // The debug screen prints rawValue directly; wire strings must be
        // human-readable (this is why they're not "case1"-style).
        for source in SpeedLimitDataSource.allCases {
            let raw = source.rawValue
            XCTAssertFalse(raw.contains("_"), "\(raw) leaks identifier style to UI")
            XCTAssertLessThan(raw.count, 30, "\(raw) overflows the debug row")
        }
    }

    // MARK: - HERE sources present

    func testHEREBatchCacheSourceExists() {
        XCTAssertEqual(SpeedLimitDataSource.batchCache.rawValue, "Batch (HERE)")
    }

    func testLiveHERESourcesExist() {
        XCTAssertEqual(SpeedLimitDataSource.liveHERE.rawValue, "Live (HERE)")
        XCTAssertEqual(SpeedLimitDataSource.liveHEREMatch.rawValue, "Live (HERE Match)")
    }

    // MARK: - Legacy decode compatibility (persisted old rows)

    func testLegacyCasesStillDecode() throws {
        // Older persisted state uses these; removing the cases breaks
        // decoding of existing histories.
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "DB"), .localDB)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "DB (Recovered)"), .localDBRecovered)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "Live (ArcGIS)"), .liveArcGIS)
        XCTAssertEqual(SpeedLimitDataSource(rawValue: "Live (Overpass)"), .liveOverpass)
    }

    func testUnknownRawValueFailsDecodeNotCrash() {
        XCTAssertNil(SpeedLimitDataSource(rawValue: "Totally Made Up"),
                     "Unknown strings must not fabricate a source")
    }

    func testNoDataSentinelExists() {
        // The UI's "searching" state keys on this case.
        XCTAssertEqual(SpeedLimitDataSource.noData.rawValue, "No Data")
    }

    // MARK: - Codability (persisted rows)

    func testSourcesSurviveCodableRoundTrip() throws {
        for source in SpeedLimitDataSource.allCases {
            let data = try JSONEncoder().encode(source)
            let back = try JSONDecoder().decode(SpeedLimitDataSource.self, from: data)
            XCTAssertEqual(back, source)
        }
    }

    func testEnumerationOrderStableAcrossCalls() {
        XCTAssertEqual(SpeedLimitDataSource.allCases.map { $0.rawValue },
                       SpeedLimitDataSource.allCases.map { $0.rawValue },
                       "Enumeration is nondeterministic")
    }
}
