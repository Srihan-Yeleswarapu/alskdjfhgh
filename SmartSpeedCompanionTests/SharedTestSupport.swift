// SharedTestSupport.swift
// Common infrastructure for the Speedio deep test suite (100 files).
//
// HERE rate-limit policy (user requirement):
//   - Only files whose name contains "HERELive" are allowed to touch the
//     network, and only when the operator opts in by launching `xcodebuild
//     test` with SPEEDIO_LIVE_HERE_TESTS=1 in the environment.
//   - Every other file in this suite MUST be hermetic: no HERE request may
//     escape from them. The shared assertion below (`XCTAssertNoHEREHits`)
//     and the corpus policy (`HereCorpus`) are how we keep it that way:
//     anything that needs HERE-shaped answers reads the single captured
//     corpus JSON instead of the wire.
//
// Runbook (on the Mac):
//   xcodegen generate
//   xcodebuild test -project SmartSpeedCompanion.xcodeproj -scheme
//     SmartSpeedCompanion -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
//   # opt-in live-coverage pass (a handful of HERE requests, not per test):
//   SPEEDIO_LIVE_HERE_TESTS=1 xcodebuild test ... -only-testing:SmartSpeedCompanionTests/HERELive*

import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

// MARK: - Runtime gates

/// Opt-in switches read once per test process. Nothing in CI sets these —
/// the GitHub workflows never run `xcodebuild test`, so the suite can only
/// ever execute on the operator's Mac, exactly as requested.
enum SpeedioTestConfig {
    /// "1" enables the HERELive* files (the only network-touching tests).
    static var liveHEREEnabled: Bool {
        ProcessInfo.processInfo.environment["SPEEDIO_LIVE_HERE_TESTS"] == "1"
    }
    /// "1" enables the wall-clock performance budget assertions. Off by
    /// default so a loaded Mac never produces flaky red runs.
    static var perfBudgetsEnabled: Bool {
        ProcessInfo.processInfo.environment["SPEEDIO_PERF_TESTS"] == "1"
    }
    /// "1" enables the larger N stress matrices (10k-row caches, 50k-fix
    /// replay). Keeps the default suite under a couple of minutes.
    static var stressEnabled: Bool {
        ProcessInfo.processInfo.environment["SPEEDIO_STRESS_TESTS"] == "1"
    }
}

/// Throws XCTSkip unless the operator opted into the live HERE suite.
/// Called from setUp / each test of the HERELive* files only.
func skipUnlessLiveHEREEnabled() throws {
    guard SpeedioTestConfig.liveHEREEnabled else {
        throw XCTSkip(
            "Live HERE suite is opt-in. Re-run with SPEEDIO_LIVE_HERE_TESTS=1 " +
            "to exercise the real HERE REST / Route Matching endpoints."
        )
    }
}

/// Throws XCTSkip for the heavy performance/stress matrices unless opted in.
func skipUnlessPerfEnabled() throws {
    guard SpeedioTestConfig.perfBudgetsEnabled else {
        throw XCTSkip("Performance budget suite is opt-in (SPEEDIO_PERF_TESTS=1).")
    }
}

func skipUnlessStressEnabled() throws {
    guard SpeedioTestConfig.stressEnabled else {
        throw XCTSkip("Stress matrix is opt-in (SPEEDIO_STRESS_TESTS=1).")
    }
}

// MARK: - GPS fix factory

/// Deterministic CLLocation builder used across the whole suite. Realism
/// rules: accuracy 5 m (what a phone reports under open sky), explicit
/// course and m/s speed, injectable timestamp so smoothing/deadband logic
/// can be driven with synthetic clocks instead of runloop sleeps.
enum GPSFixFactory {

    static let mphToMs: Double = 1.0 / 2.23694

    static func fix(
        lat: Double,
        lon: Double,
        speedMph: Double,
        course: Double = 90,
        accuracy: CLLocationAccuracy = 5,
        speedAccuracy: CLLocationAccuracy = 1.0,
        timestamp: Date = Date()
    ) -> CLLocation {
        let clampedSpeedMph = max(0, speedMph)
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 350,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 10,
            course: course,
            speed: clampedSpeedMph * mphToMs,
            speedAccuracy: speedAccuracy,
            timestamp: timestamp
        )
    }

    /// A fix whose speed Core Location marks invalid (the -1 sentinel the
    /// engine must interpret as "no trustworthy speed this tick").
    static func speedlessFix(
        lat: Double = 33.3062,
        lon: Double = -111.8412,
        timestamp: Date = Date()
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 350,
            horizontalAccuracy: 5,
            verticalAccuracy: 10,
            course: 90,
            speed: -1,
            speedAccuracy: -1,
            timestamp: timestamp
        )
    }

    /// Advances a coordinate by `meters` along `heading` (degrees from true
    /// north) using the same flat-earth approximation the providers use.
    static func advance(
        _ coordinate: CLLocationCoordinate2D,
        meters: Double,
        heading: Double
    ) -> CLLocationCoordinate2D {
        let rad = heading * .pi / 180
        let dLat = meters * cos(rad) / 111_111.0
        let dLon = meters * sin(rad) / (111_111.0 * max(0.000001, cos(coordinate.latitude * .pi / 180)))
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + dLat,
            longitude: coordinate.longitude + dLon
        )
    }
}

// MARK: - UserDefaults snapshot guard

/// Snapshot/restores the app-defaults keys the suite mutates so a test run
/// can never leave the operator's real preferences (buffer, units, toggles)
/// changed. Every file that touches UserDefaults uses one instance per test.
final class UserDefaultsTestGuard {
    private var snapshot: [String: Any?] = [:]
    private let keys: [String]

    static let knownKeys = [
        "userBuffer", "measurementSystem", "audioAlertsEnabled",
        "hapticAlertsEnabled", "hapticAlertStyle", "hapticCustomPattern",
        "avoidHighways", "selectedVehicleIconId", "voiceNavEnabled",
        "gpsAccuracyMode",        "widgetSpeed", "widgetLimit", "widgetStatus",
        "sessionRecorder_isRecording"
    ]

    init(keys: [String] = UserDefaultsTestGuard.knownKeys) {
        self.keys = keys
    }

    func snapshotNow() {
        let ud = UserDefaults.standard
        snapshot = [:]
        for key in keys { snapshot[key] = ud.object(forKey: key) }
    }

    func restore() {
        let ud = UserDefaults.standard
        for (key, value) in snapshot {
            if let value { ud.set(value, forKey: key) } else { ud.removeObject(forKey: key) }
        }
    }

    /// Wipes every guarded key so tests start from "fresh install" semantics.
    func resetToFreshInstall() {
        let ud = UserDefaults.standard
        for key in keys { ud.removeObject(forKey: key) }
    }
}

// MARK: - HERE-corpus policy helpers

/// The hermetic tests' contract with the HERE pipeline: a fetch driven by
/// corpus data resolves through the in-memory caches only. These helpers
/// keep that policy in ONE place so a drift in the app's provider names
/// fails loudly here instead of silently leaking network calls.
enum HereCorpusPolicy {

    /// The exact provider names the app treats as HERE. Mirrors
    /// SmartSpeedLimitService.isHEREProviderName + the response-cache guard.
    static let allowedProviderNames: Set<String> = [
        "HERE REST", "HERE Match", "HERE Batch"
    ]

    /// Asserts a candidate response is corpus-safe (i.e. could have come
    /// from the captured corpus rather than a live request).
    static func assertCorpusSafe(_ response: SpeedLimitResponse,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            allowedProviderNames.contains(response.providerName),
            "Non-HERE provider '\(response.providerName)' must never be promoted to a driving answer",
            file: file, line: line
        )
        XCTAssertTrue(
            (1...90).contains(response.speedLimitMph),
            "Corpus-derived limits must be plausible posted values (got \(response.speedLimitMph))",
            file: file, line: line
        )
    }
}

// MARK: - Shared synthetic geography

/// A small synthetic city used by cache, matcher, continuity, camera, and
/// session tests. Distances are chosen so 0.0005° grid cells (~55 m) and
/// 50 m nearest-neighbor radii behave predictably.
enum GeoCorpus {

    /// Grid spacing of the app's response cache (SpeedLimitResponseCache).
    static let cacheCellDegrees: Double = 0.0005

    struct SignedSegment {
        let roadName: String
        let direction: String
        let limitMph: Int
        let latitude: Double
        let longitude: Double
    }

    /// "Downtown" block: 4 roads crossing at a single intersection.
    static let intersection = CLLocationCoordinate2D(latitude: 33.30620, longitude: -111.84120)

    /// Deterministic 24-segment grid of arterial + highway segments.
    static let segments: [SignedSegment] = {
        var result: [SignedSegment] = []
        // East-west arterials every 0.002° lat (~222 m).
        for (rowIdx, lat) in stride(from: 33.3000, through: 33.3120, by: 0.002).enumerated() {
            for (colIdx, lon) in stride(from: -111.8460, through: -111.8360, by: 0.002).enumerated() {
                let isHighway = rowIdx == 3
                result.append(SignedSegment(
                    roadName: isHighway ? "SR-101" : "Corpus Ave \(rowIdx)",
                    direction: colIdx.isMultiple(of: 2) ? "E" : "W",
                    limitMph: isHighway ? 65 : (35 + (rowIdx % 3) * 5),
                    latitude: lat,
                    longitude: lon
                ))
            }
        }
        return result
    }()

    /// A 45 mph arterial heading east through the corpus city.
    static func arterialDrive(fixes: Int = 12, startLat: Double = 33.3062, startLon: Double = -111.8412) -> [CLLocation] {
        var coords: [CLLocationCoordinate2D] = []
        var c = CLLocationCoordinate2D(latitude: startLat, longitude: startLon)
        for _ in 0..<fixes {
            coords.append(c)
            c = GPSFixFactory.advance(c, meters: 30, heading: 90)
        }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        return coords.enumerated().map { idx, coord in
            GPSFixFactory.fix(lat: coord.latitude, lon: coord.longitude,
                              speedMph: 45, course: 90,
                              timestamp: t0.addingTimeInterval(Double(idx)))
        }
    }

    /// City-block turn sequence used by matcher/session tests.
    static let turnSequence: [(heading: Double, meters: Double)] = [
        (90, 160), (0, 80), (270, 160), (180, 80), (90, 320), (45, 120)
    ]
}

// MARK: - Misc

extension XCTestCase {
    /// Drains one main-queue hop so @Published writes from engine pipelines
    /// are observable without hard-coded sleeps.
    func waitForMainQueueTurn(_ description: String = "main queue") {
        let exp = expectation(description: description)
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    /// Asserts two mph values agree to GPS-display precision.
    func assertMph(_ actual: Double, equals expected: Double, _ message: String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, accuracy: 0.06, message, file: file, line: line)
    }
}

// MARK: - HERE credentials gate (the hermetic switch)

/// With HERE credentials absent, every live provider short-circuits BEFORE
/// building a URL (`guard let creds = HERECredentialStore.shared.loadCredentials()
/// else { return nil }`), so the whole engine pipeline can be driven with
/// real GPS fixes and zero wire traffic. Any test that pushes locations
/// through SpeedEngine/simulation uses one of these in setUp/tearDown.
final class HERECredentialsGate {
    private var hadCredentials = false
    private var savedId = ""
    private var savedSecret = ""

    func close() {
        if let creds = HERECredentialStore.shared.loadCredentials() {
            hadCredentials = true
            savedId = creds.accessKeyId
            savedSecret = creds.accessKeySecret
            HERECredentialStore.shared.clearCredentials()
        }
    }

    func reopen() {
        guard hadCredentials else { return }
        HERECredentialStore.shared.saveCredentials(accessKeyId: savedId, accessKeySecret: savedSecret)
    }
}
