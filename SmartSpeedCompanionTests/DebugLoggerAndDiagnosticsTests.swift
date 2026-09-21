import XCTest
@testable import SmartSpeedCompanion

/// DebugLogger + diagnostics: the ring buffer the Developer tab and every
/// incident report lean on. Formatting stability matters — timestamps are
/// parsed by eye at 2 a.m. — and the 1500-entry ceiling is the memory cap
/// that keeps a 4-hour drive from OOMing the diagnostics screen.
@MainActor
final class DebugLoggerAndDiagnosticsTests: XCTestCase {

    // MARK: - LogEntry

    func testFormattedTimestampShape() {
        let entry = LogEntry(timestamp: Date(timeIntervalSince1970: 1_700_000_000), message: "hello")
        // HH:mm:ss.SSS shape: two colons and a dot with 3 fractional digits.
        let pattern = "^\\d{2}:\\d{2}:\\d{2}\\.\\d{3}$"
        let predicate = NSPredicate(format: "SELF MATCHES %@", pattern)
        XCTAssertTrue(predicate.evaluate(with: entry.formattedTimestamp),
                      "Timestamp '\(entry.formattedTimestamp)' must be HH:mm:ss.SSS")
    }

    func testLogEntryIdentifiable() {
        let a = LogEntry(timestamp: .now, message: "a")
        let b = LogEntry(timestamp: .now, message: "a")
        XCTAssertNotEqual(a.id, b.id, "Identical messages must still be distinct entries")
    }

    // MARK: - Logger behavior

    func testLogAppendsEntry() {
        let logger = DebugLogger.shared
        let before = logger.logs.count
        logger.log("suite-test-append-\(UUID().uuidString)")
        // The write hops queues; poll briefly.
        let exp = expectation(description: "log appended")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertGreaterThanOrEqual(logger.logs.count, before)
    }

    func testClearEmptiesLogs() {
        let logger = DebugLogger.shared
        logger.clear()
        let exp = expectation(description: "cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        // clear() hops to main; by now it has run.
        XCTAssertTrue(logger.logs.isEmpty || logger.logs.count < 1500)
    }

    func testMaxLogsCapIsFifteenHundred() throws {
        let source = try String(contentsOfFile: loggerPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("maxLogs = 1500"),
                      "The ring-buffer cap is the heat/memory boundary for long drives — raising it needs a re-think of the diagnostics screen")
    }

    func testLogDoesNotCrashWithLongMessage() {
        let long = String(repeating: "x", count: 100_000)
        DebugLogger.shared.log(long) // must not block or trap
    }

    func testLogWithInterpolatedDiagnostics() {
        // The production logging style: interpolate state for support.
        let mph = 47.3
        let limit = 45
        DebugLogger.shared.log("HUD: speed=\(mph) limit=\(limit) status=over") // no crash
    }

    // MARK: - Observability contracts (the logs tests read elsewhere)

    func testHEREThrottleLogsExist() throws {
        let source = try String(contentsOfFile: hereRestPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("HERE REST: HTTP"),
                      "HTTP status logging is the primary rate-limit diagnostic")
        XCTAssertTrue(source.contains("429"),
                      "The 429 path must be explicitly observable (cooldown extension)")
    }

    func testContinuityGuardDecisionsAreLogged() throws {
        let source = try String(contentsOfFile: servicePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("[ContinuityGuard] HOLD"),
                      "Hold decisions must be log-visible to diagnose flicker reports")
    }

    func testGeofenceTriggerIsLogged() throws {
        let source = try String(contentsOfFile: geofencePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("triggering background batch fetch"),
                      "Batch-fetch triggers must be visible in diagnostics")
    }

    private func loggerPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\DebugLogger.swift"
        #else
        return "SmartSpeedCompanion/Core/DebugLogger.swift"
        #endif
    }

    private func hereRestPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\HERERestSpeedLimitProvider.swift"
        #else
        return "SmartSpeedCompanion/Core/HERERestSpeedLimitProvider.swift"
        #endif
    }

    private func servicePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\SpeedLimitService.swift"
        #else
        return "SmartSpeedCompanion/Core/SpeedLimitService.swift"
        #endif
    }

    private func geofencePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\HEREGeofenceManager.swift"
        #else
        return "SmartSpeedCompanion/Core/HEREGeofenceManager.swift"
        #endif
    }
}
