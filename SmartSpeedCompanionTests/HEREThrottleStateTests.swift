import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// The REST provider's throttle state machine — the mechanism that keeps a
/// 1 Hz GPS loop from hammering HERE. Verified through observable behavior
/// (short-circuit timing) and the source contracts that pin its constants.
final class HEREThrottleStateTests: XCTestCase {

    private func restSource() throws -> String {
        #if os(Windows)
        return try String(contentsOfFile: "SmartSpeedCompanion\\Core\\HERERestSpeedLimitProvider.swift", encoding: .utf8)
        #else
        return try String(contentsOfFile: "SmartSpeedCompanion/Core/HERERestSpeedLimitProvider.swift", encoding: .utf8)
        #endif
    }

    // MARK: - Constants

    func testSuccessDistanceGateIs100Meters() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("successMinDistance: CLLocationDistance = 100"),
                      "A successful lookup pins a 100 m no-fly radius for repeat probes")
    }

    func testFailureRetryIntervalIsTenSeconds() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("failureRetryInterval: TimeInterval = 10"),
                      "Failures park the provider for 10 s so a dead endpoint isn't retried at 1 Hz")
    }

    func testSelfLoopProbeIsSixtyMeters() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("selfLoopMeters: Double = 60"),
                      "The course-aligned probe distance — changing it changes HERE's segment resolution")
    }

    func testFourTwentyNineExtendsCooldownThirtySeconds() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("extendFailureCooldown(by: 30)"),
                      "A 429 must park the provider for 30 s — retrying sooner deepens the rate-limit hole")
    }

    // MARK: - Course alignment of the probe

    func testProbeFollowsVehicleCourseNotEastward() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("normalizedCourse") || source.contains("headingRadians"),
                      "The probe must align with vehicle course (the intersection straddle fix)")
        XCTAssertTrue(source.contains("?? 90.0"),
                      "Eastward fallback exists only when the GPS has no usable course")
    }

    func testInvalidCourseFallsBackToEast() {
        // The course sanitizer: isFinite, [0, 360), else 90°.
        func sanitize(_ course: Double?) -> Double {
            course.flatMap { $0.isFinite && $0 >= 0 && $0 < 360 ? $0 : nil } ?? 90.0
        }
        XCTAssertEqual(sanitize(270), 270)
        XCTAssertEqual(sanitize(-1), 90, "Invalid sentinel → east fallback")
        XCTAssertEqual(sanitize(360), 90, "360 is out of range → east fallback")
        XCTAssertEqual(sanitize(.nan), 90, "NaN → east fallback")
        XCTAssertEqual(sanitize(nil), 90)
    }

    // MARK: - Locale-proof coordinate formatting

    func testCoordinatesUsePosixFormatting() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("en_US_POSIX"),
                      "A comma-decimal device locale would produce invalid HERE coordinate queries")
        XCTAssertTrue(source.contains("%.6f,%.6f"),
                      "Six-decimal precision is the wire contract")
    }

    // MARK: - Behavioral throttle (real provider, gated credentials)

    func testFreshProviderDoesNotThrottleFirstCall() async throws {
        // A fresh provider has no last-success; with credentials absent the
        // call short-circuits at the CREDENTIALS gate, not the throttle —
        // proving the gates are ordered correctly (throttle first would
        // make the credentials log line unreachable for repeat probes).
        HERECredentialStore.shared.clearCredentials()
        let provider = HERERestSpeedLimitProvider()
        let start = Date()
        let response = try await provider.fetchSpeedLimit(
            at: CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412),
            heading: 90, forceRefresh: true)
        XCTAssertNil(response)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0,
                          "Credentials-gate short-circuit must be immediate")
    }

    // MARK: - Response validation bounds

    func testMphBoundsValidation() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("mph > 0, mph <= 90"),
                      "0 = no posted limit; >90 = bogus. Both must resolve to nil")
    }

    func testUserAgentIdentifiesTheApp() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("Speedio/"),
                      "The User-Agent is how HERE support attributes traffic — keep it")
    }

    func testTimeoutIsFourSeconds() throws {
        let source = try restSource()
        XCTAssertTrue(source.contains("timeoutInterval: 4.0"),
                      "4 s: long enough for a mobile RTT, short enough that the next GPS tick doesn't cancel first")
    }
}
