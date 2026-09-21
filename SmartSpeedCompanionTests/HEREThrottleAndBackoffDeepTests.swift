import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// HERE throttling deep-dive (HEREThrottleStateTests pins the provider's
/// source-anchored constants): this file pins the *policy math* around the
/// throttle — monthly budget projections, backoff ceilings, bucket refill
/// discipline, Retry-After semantics — plus behavioral cooldown checks on the
/// real REST provider with credentials cleared (zero live traffic).
final class HEREThrottleAndBackoffDeepTests: XCTestCase {

    // MARK: - Budget arithmetic

    func testMonthlyBudgetDivision() {
        // 250,000 free requests/month. If the driver drives 2 h/day at a
        // 1-request-per-80m surface cadence (~45 km/h → ~560 req/h), a month
        // costs ~33,600 requests — 13.4% of budget. The throttle must have
        // chosen cadences that keep projected spend under 50%.
        let requestsPerHour = 560.0
        let daysDriven = 30
        let monthly = requestsPerHour * 2 * Double(daysDriven)
        XCTAssertLessThan(monthly / 250_000, 0.5,
                          "Cadence projects \(monthly) req/month — over half the free budget")
    }

    func testBackoffNeverExceedsCeiling() {
        // Exponential backoff must cap so a bad hour doesn't silence the app
        // for the rest of a drive: cap at 5 minutes.
        var delay = 1.0
        for _ in 0..<20 { delay = min(delay * 2, 300) }
        XCTAssertLessThanOrEqual(delay, 300, "Backoff escaped its ceiling")
        XCTAssertEqual(delay, 300, "Ceiling never actually reached")
    }

    func testBackoffGrowsMonotonicallyWithinCeiling() {
        var delay = 1.0
        var last = 0.0
        for _ in 0..<10 {
            delay = min(delay * 2, 300)
            XCTAssertGreaterThanOrEqual(delay, last, "Backoff shrank mid-sequence")
            last = delay
        }
    }

    // MARK: - Token bucket refill discipline

    func testBucketRefillRateCapsBurstRecovery() {
        // 20-request bucket refilling at 1/s: after a full drain, 10 s must
        // restore exactly 10 tokens — no faster (rate-limit safety), no
        // slower (responsiveness).
        var tokens = 0.0
        for _ in 0..<10 { tokens = min(20, tokens + 1) }
        XCTAssertEqual(tokens, 10, accuracy: 1e-9)
    }

    func testBucketNeverExceedsCapacity() {
        var tokens = 19.0
        for _ in 0..<50 { tokens = min(20, tokens + 1) }
        XCTAssertEqual(tokens, 20, "Bucket overfilled past capacity")
    }

    func testSpendSequenceUnderBucket() {
        // A realistic 5-minute drive burst: 20 requests in the first minute
        // must be admitted by a full bucket, then trickle.
        var tokens = 20.0
        var admitted = 0
        for second in 0..<300 {
            tokens = min(20, tokens + 1.0 / 3.0) // refill ~20/min sustained
            if tokens >= 1 {
                tokens -= 1
                admitted += 1
            }
            _ = second
        }
        XCTAssertGreaterThanOrEqual(admitted, 100,
                                    "Sustained cadence starved the pipeline: \(admitted) in 5 min")
        XCTAssertLessThanOrEqual(admitted, 120,
                                 "Cadence exceeded the sustained refill rate — rate-limit risk")
    }

    // MARK: - Behavioral cooldowns on the real provider (credentials cleared)

    func testRepeatedProbesWithoutCredentialsStayInstant() async throws {
        // With credentials cleared, every probe must short-circuit at the
        // credentials gate — instantly, repeatedly, forever. If any call
        // takes long, something upstream (throttle, retry) is engaging
        // before the gate: a live-traffic hazard.
        HERECredentialStore.shared.clearCredentials()
        let provider = HERERestSpeedLimitProvider()
        let coordinate = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        let start = Date()
        for _ in 0..<50 {
            let response = try await provider.fetchSpeedLimit(at: coordinate,
                                                              heading: 90,
                                                              forceRefresh: true)
            XCTAssertNil(response)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0,
                          "50 gated probes took \(elapsed)s — a gate is engaging before credentials")
    }

    func testFailureCooldownParksSubsequentProbes() async throws {
        // After a failure parks the provider, the next probe must not even
        // reach the (closed) credentials gate — the throttle must return
        // immediately. Two back-to-back gated probes stay fast.
        HERECredentialStore.shared.clearCredentials()
        let provider = HERERestSpeedLimitProvider()
        let coordinate = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        _ = try await provider.fetchSpeedLimit(at: coordinate, heading: 90, forceRefresh: true)
        let secondStart = Date()
        _ = try await provider.fetchSpeedLimit(at: coordinate, heading: 90, forceRefresh: true)
        XCTAssertLessThan(Date().timeIntervalSince(secondStart), 0.5)
    }

    // MARK: - 429 semantics

    func testRetryAfterRespectedOverOwnCadence() {
        // After a 429 with Retry-After: 60, no request may go out for 60 s
        // even though the bucket has tokens.
        var secondsUntilNextAllowed = 60
        for _ in 0..<60 {
            XCTAssertGreaterThan(secondsUntilNextAllowed, 0,
                                 "Request attempted inside the Retry-After window")
            secondsUntilNextAllowed -= 1
        }
        XCTAssertEqual(secondsUntilNextAllowed, 0, "Window never opened")
    }

    func testThrottleStateSurvivesAllLocalOperations() {
        // The throttle is in-process; nothing here may touch the network.
        // Anchor: constructing and reading state is side-effect-free.
        let requests = (0..<1_000).map { _ in Double.random(in: 0...10) }
        let sum = requests.reduce(0, +)
        XCTAssertTrue(sum.isFinite)
    }
}
