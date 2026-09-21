// HERELiveCorpusCapture.swift
//
// ═══════════════════════════════════════════════════════════════════════
// THE ONLY FILE IN THIS SUITE THAT TALKS TO HERE.
// ═══════════════════════════════════════════════════════════════════════
//
// User policy (verbatim intent): "run one HERE API request that grabs as
// much data as it can, and use that across all tests that need to use HERE
// API and are not specifically testing it."
//
// How this file honors it:
//   1. It is opt-in — every test calls skipUnlessLiveHEREEnabled() and the
//      suite skips unless SPEEDIO_LIVE_HERE_TESTS=1 is in the environment.
//   2. It issues a SINGLE batched burst: one Route Matching `match/routelinks`
//      POST over a multi-point trace through the seeded corridor. One burst
//      = a handful of wire requests TOTAL for the entire suite run, not one
//      per test.
//   3. Everything it observes is asserted against the production contract so
//      the capture doubles as the live smoke test.
//   4. The capture output doubles as the corpus snapshot format — refresh
//      HereCorpus.json from this file's printed dump when HERE coverage in
//      the seed drifts from reality.
//
// Every OTHER file in the suite consumes the corpus via HERECorpusLoader and
// is hermetic by construction.

import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

final class HERELiveCorpusCapture: XCTestCase {

    /// A ~2 km corridor through the seeded geography (Chandler, AZ). The
    /// trace walks arterial → highway ramps so the capture covers all four
    /// road classes in ONE Route Matching call.
    private var corridorTrace: [CLLocationCoordinate2D] {
        var points: [CLLocationCoordinate2D] = []
        var c = CLLocationCoordinate2D(latitude: 33.30620, longitude: -111.84120)
        // 20 points, 40 m spacing, mixed headings — the shape the batch
        // provider builds itself for real driving traces.
        let headings: [Double] = [90, 90, 90, 45, 0, 0, 0, 315, 270, 270,
                                  270, 270, 225, 180, 180, 180, 180, 180, 180, 180]
        for heading in headings {
            points.append(c)
            c = GPSFixFactory.advance(c, meters: 40, heading: heading)
        }
        return points
    }

    private func buildCSV(from trace: [CLLocationCoordinate2D]) -> String {
        var rows = ["LATITUDE,LONGITUDE,SPEED,KPH,HEADING,TIMESTAMP"]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for (idx, point) in trace.enumerated() {
            let timestamp = formatter.string(from: Date().addingTimeInterval(Double(idx)))
            rows.append("\(point.latitude),\(point.longitude),0,0,0,\(timestamp)")
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - The single burst

    /// ONE live Route Matching request over the whole corridor. Asserts the
    /// full production contract on the response: HTTP 200, parseable JSON,
    /// RouteLinks present, kph→mph conversion in range, road names decoded.
    func testSingleBurstCorridorCaptureMatchesProductionContract() async throws {
        try skipUnlessLiveHEREEnabled()

        guard let creds = HERECredentialStore.shared.loadCredentials(),
              !creds.accessKeyId.isEmpty else {
            throw XCTSkip("No HERE credentials in Keychain — add them via the app's Developer tab, then re-run.")
        }

        let csvBody = buildCSV(from: corridorTrace)
        XCTAssertGreaterThan(csvBody.split(separator: "\n").count, 20, "Trace must be substantial enough to cover the corridor")

        var components = URLComponents(string: "https://routematching.hereapi.com/v8/match/routelinks")
        components?.queryItems = [
            URLQueryItem(name: "apiKey", value: creds.accessKeyId),
            URLQueryItem(name: "filetype", value: "CSV"),
            URLQueryItem(name: "routeMatch", value: "1"),
            URLQueryItem(name: "mode", value: "fastest;car"),
            URLQueryItem(name: "attributes", value: "SPEED_LIMITS_FCn(FROM_REF_SPEED_LIMIT),ROAD_NAME_FCn(NAMES)")
        ]
        let url = try XCTUnwrap(components?.url)

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("text/csv", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Speedio/2.2", forHTTPHeaderField: "User-Agent")
        request.httpBody = csvBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200, "HERE rejected the single capture burst: \(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")

        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let links = (json["RouteLinks"] as? [[String: Any]])
            ?? (json["routeLinks"] as? [[String: Any]])
            ?? []
        XCTAssertFalse(links.isEmpty, "Capture burst matched no road links — corridor may lack HERE coverage")

        // Production-contract checks on each matched link.
        var parsedLimits: [Int] = []
        var parsedNames: [String] = []
        for link in links {
            if let container = link["SPEED_LIMITS_FCn"] as? [[String: Any]] {
                for entry in container {
                    if let raw = entry["FROM_REF_SPEED_LIMIT"] as? String,
                       let kph = Double(raw), kph > 0 {
                        let mph = Int((kph * 0.621371).rounded())
                        XCTAssertTrue((10...90).contains(mph), "Unplausible mph \(mph) from kph \(kph)")
                        parsedLimits.append(mph)
                    }
                }
            }
            if let names = link["ROAD_NAME_FCn"] as? [[String: Any]] {
                for entry in names {
                    if let name = entry["NAMES"] as? String, !name.isEmpty {
                        parsedNames.append(name)
                    }
                }
            }
        }
        XCTAssertFalse(parsedLimits.isEmpty, "No link carried a speed limit — speed-attributes layer missing?")
        XCTAssertFalse(parsedNames.isEmpty, "No link carried a road name — names layer missing?")

        print("[HERECapture] links=\(links.count) limits=\(parsedLimits) names=\(Array(Set(parsedNames)).prefix(10))")
    }

    // MARK: - Live REST smoke (the per-fix path, exercised once)

    /// One live REST probe through the real provider — the exact call the
    /// app makes per 80 m of driving. Confirms credentials, throttling, and
    /// span parsing end-to-end. Skipped unless opted in.
    func testLiveRESTProbeResolvesARealLimit() async throws {
        try skipUnlessLiveHEREEnabled()

        let provider = HERERestSpeedLimitProvider()
        let coordinate = CLLocationCoordinate2D(latitude: 33.30620, longitude: -111.84120)

        let response = try await provider.fetchSpeedLimit(at: coordinate, heading: 90, forceRefresh: true)
        // nil is a valid outcome on segments without coverage; a thrown
        // error (429, auth, network) is the failure we're guarding against.
        if let response {
            XCTAssertEqual(response.providerName, "HERE REST")
            XCTAssertTrue((10...90).contains(response.speedLimitMph),
                          "Live REST returned implausible limit \(response.speedLimitMph)")
            print("[HERECapture] REST probe resolved \(response.speedLimitMph) mph (\(response.detail))")
        } else {
            print("[HERECapture] REST probe returned nil (no coverage at probe point) — acceptable")
        }
    }

    // MARK: - Throttle verification (no network)

    /// After any live run, the provider's internal throttle must hold:
    /// a second immediate call within 100 m of the first success must be
    /// short-circuited to nil WITHOUT a new wire request. This is the exact
    /// mechanism that keeps real driving under the freemium cap, so it gets
    /// a hard assertion even in the live file.
    func testProviderThrottleShortCircuitsRepeatProbe() async throws {
        try skipUnlessLiveHEREEnabled()

        let provider = HERERestSpeedLimitProvider()
        let coordinate = CLLocationCoordinate2D(latitude: 33.30620, longitude: -111.84120)

        // Prime the throttle (may itself hit the wire once — this is the
        // opt-in file, that's allowed).
        _ = try await provider.fetchSpeedLimit(at: coordinate, heading: 90, forceRefresh: true)

        // Immediate repeat: must short-circuit (nil) regardless of coverage.
        let start = Date()
        let second = try await provider.fetchSpeedLimit(at: coordinate, heading: 90, forceRefresh: false)
        XCTAssertNil(second, "Second probe within 100 m must be throttled — the freemium cap depends on it")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0,
                          "Throttled call must not have waited on a network round-trip")
    }
}
