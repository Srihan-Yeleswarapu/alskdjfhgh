#if DEBUG || DEVELOPER_BUILD
import Foundation
import CoreLocation
import Combine

/// Speed-threshold landmarks baked into the bundled `TestRoutes.gpx` ladder.
/// The route is generated so a known waypoint carries a known exact speed:
/// `t == 25 s` holds 25 mph and `t == 75 s` holds 75 mph (see the GPX
/// `<desc>`). The ladder then holds 70 for 15 s and 76 for 9 s so a 70-mph
/// limit with the default +5 buffer exercises warning AND over states.
enum MockRouteLandmark {
    static let mph25Index = 25
    static let mph75Index = 75
    /// Top of the over-soak vs a 70-mph limit (80 mph fix).
    static let mph80Index = 95
    /// End-of-route safe soak (45 mph fix).
    static let mph45Index = 149
}

/// One replayable GPS fix from a GPX track.
struct MockRoutePoint {
    let coordinate: CLLocationCoordinate2D
    /// Ground speed in meters per second, straight from the GPX `<speed>`
    /// element. The threshold ladder stores exact mph×0.44704 values.
    let speedMetersPerSecond: Double
    /// Course over ground in degrees (0 = north).
    let courseDegrees: Double
    /// Timestamp carried by the GPX fix (2026-09-23T00:00:00Z + index).
    let timestamp: Date
}

/// Debug / Simulator mock-location engine.
///
/// Replays the bundled `TestRoutes.gpx` threshold route through the SAME
/// wire `LocationManager` already listens to — the `.didUpdateMockLocation`
/// notification broadcast by `SimulationManager` — so SpeedEngine's
/// smoothing/deadband pipeline, the HUD gauge, and AlertEngine's warning /
/// overspeed triggers are exercised end-to-end without any CoreLocation
/// hardware (which does not exist in the iOS Simulator).
///
/// Three on-demand controls:
///   • `play()` / `pause()` / `stop()` — 1 Hz replay of the GPX ladder.
///   • `setSpeed(mph:)`              — stream ONE exact-speed fix now.
///   • `streamSpeed(mph:)`           — hold an exact speed every second.
///
/// `@MainActor`: every caller is the main-actor Settings UI or the
/// main-actor `SimulationManager` broadcast loop, matching the isolation
/// policy of the rest of Core/ under Swift 6.
@MainActor
public final class MockLocationManager: ObservableObject {

    public static let shared = MockLocationManager()

    // MARK: - Published state (Developer UI)

    /// True while the 1 Hz GPX replay timer is running.
    @Published public private(set) var isPlaying: Bool = false
    /// Index of the next GPX point to broadcast.
    @Published public private(set) var currentIndex: Int = 0
    /// Route display name parsed from the GPX `<name>` element.
    @Published public private(set) var routeName: String = ""
    /// Set after load / start when the GPX resource is missing or malformed.
    @Published public private(set) var lastError: String?
    /// Speed of the currently held manual stream (mph), nil when none.
    @Published public private(set) var manualStreamMph: Double?

    // MARK: - Route state

    private var points: [MockRoutePoint] = []
    private var replayTimer: AnyCancellable?
    private var manualStreamTimer: AnyCancellable?

    /// Coordinate space is the SimulationManager default (Phoenix, AZ) so
    /// the mock map view and the speed-limit pipeline both start on land.
    private init() {
        loadBundledRoute()
    }

    // MARK: - GPX loading

    /// Loads and parses `TestRoutes.gpx` from the app bundle. A missing or
    /// malformed resource logs loudly but never crashes the app.
    public func loadBundledRoute() {
        guard let url = Bundle.main.url(forResource: "TestRoutes", withExtension: "gpx") else {
            lastError = "TestRoutes.gpx missing from the app bundle (check project.yml resources)"
            DebugLogger.shared.log("MockLocationManager: \(lastError!)")
            return
        }
        do {
            let xml = try String(contentsOf: url, encoding: .utf8)
            let parsed = Self.parseGPX(xml)
            guard !parsed.points.isEmpty else {
                lastError = "TestRoutes.gpx parsed to zero track points"
                DebugLogger.shared.log("MockLocationManager: \(lastError!)")
                return
            }
            points = parsed.points
            routeName = parsed.name
            lastError = nil
            currentIndex = 0
            DebugLogger.shared.log(
                "MockLocationManager: loaded \(points.count) GPX points from '\(routeName)'")
        } catch {
            lastError = "GPX load failed: \(error.localizedDescription)"
            DebugLogger.shared.log("MockLocationManager: \(lastError!)")
        }
    }

    public var pointCount: Int { points.count }

    /// Minimal GPX 1.1 track parser: `XMLParser` delegate driven, tolerant
    /// of `<ele>`/`<speed>`/`<time>` children in any order, and ignores
    /// everything outside `<trkpt>`. Static so the XCTest suite can replay
    /// the SAME parser the app uses against synthetic GPX text.
    nonisolated static func parseGPX(_ xml: String) -> (name: String, points: [MockRoutePoint]) {
        final class Delegate: NSObject, XMLParserDelegate {
            var name = ""
            var points: [MockRoutePoint] = []

            private var inTrkpt = false
            private var lat: Double = 0
            private var lon: Double = 0
            private var speed: Double = -1
            private var course: Double = 0
            private var timeString: String?
            private var currentText: String?
            private var inTrkName = false

            // `nonisolated(unsafe)`: the formatter is used only from the
            // XMLParser delegate callbacks, which run serially on one
            // thread. (Swift 6 strict-concurrency annotation added by the
            // HUD-pill session to unblock whole-module typecheck.)
            private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime]
                return f
            }()

            func parser(_ parser: XMLParser,
                        didStartElement elementName: String,
                        namespaceURI: String?,
                        qualifiedName qName: String?,
                        attributes attributeDict: [String: String] = [:]) {
                currentText = ""
                switch elementName {
                case "trkpt":
                    inTrkpt = true
                    lat = Double(attributeDict["lat"] ?? "") ?? 0
                    lon = Double(attributeDict["lon"] ?? "") ?? 0
                    speed = -1
                    course = 0
                    timeString = nil
                case "name" where !inTrkpt:
                    inTrkName = true
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                currentText?.append(string)
            }

            func parser(_ parser: XMLParser,
                        didEndElement elementName: String,
                        namespaceURI: String?,
                        qualifiedName qName: String?) {
                switch elementName {
                case "trkpt":
                    if inTrkpt {
                        let timestamp = timeString.flatMap { Self.formatter.date(from: $0) } ?? Date()
                        points.append(MockRoutePoint(
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            speedMetersPerSecond: speed,
                            courseDegrees: course,
                            timestamp: timestamp
                        ))
                    }
                    inTrkpt = false
                case "name" where inTrkName:
                    name += currentText ?? ""
                    inTrkName = false
                case "speed" where inTrkpt:
                    speed = Double(currentText?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
                case "course" where inTrkpt:
                    course = Double(currentText?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                case "time" where inTrkpt:
                    timeString = currentText?.trimmingCharacters(in: .whitespaces)
                default:
                    break
                }
                currentText = nil
            }
        }

        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return (delegate.name, delegate.points)
    }

    // MARK: - Broadcast plumbing

    /// Builds the CLLocation fix and posts it on the same wire the manual
    /// SimulationManager uses. Speed is the EXACT m/s carried by the GPX
    /// point (or the exact mph→m/s conversion for manual streams) — no
    /// smoothing, no physics integration. `LocationManager` forwards the
    /// notification object into `latestLocation` while `isMockMode` +
    /// `isUpdatingLocation` hold, so SpeedEngine receives a real CLLocation.
    private func broadcast(coordinate: CLLocationCoordinate2D,
                           speedMps: Double,
                           course: Double,
                           timestamp: Date) {
        let location = CLLocation(
            coordinate: coordinate,
            altitude: 350,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: course,
            speed: speedMps,
            timestamp: timestamp
        )
        NotificationCenter.default.post(name: .didUpdateMockLocation, object: location)
    }

    // MARK: - GPX replay

    /// Starts (or resumes) the 1 Hz replay of the GPX threshold ladder.
    public func play() {
        if points.isEmpty {
            loadBundledRoute()
        }
        guard !points.isEmpty else { return }
        guard replayTimer == nil else { return }
        isPlaying = true
        manualStreamStop()
        DebugLogger.shared.log("MockLocationManager: GPX replay started at index \(currentIndex)")
        replayTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
        // Fire the first fix immediately instead of waiting a full second.
        tick()
    }

    /// Pauses the replay, keeping the current index for `play()` resume.
    public func pause() {
        replayTimer?.cancel()
        replayTimer = nil
        isPlaying = false
        DebugLogger.shared.log("MockLocationManager: GPX replay paused at index \(currentIndex)")
    }

    /// Stops everything (replay + manual stream) and rewinds to the first
    /// GPX fix.
    public func stop() {
        pause()
        manualStreamStop()
        currentIndex = 0
    }

    /// Jumps the replay cursor to a specific GPX index and streams that
    /// exact fix immediately (on-demand threshold jump).
    public func seek(to index: Int) {
        guard points.indices.contains(index) else { return }
        currentIndex = index
        let point = points[index]
        broadcast(coordinate: point.coordinate,
                  speedMps: point.speedMetersPerSecond,
                  course: point.courseDegrees,
                  timestamp: Date())
    }

    private func tick() {
        guard !points.isEmpty else {
            pause()
            return
        }
        // Loop the ladder so an unattended threshold soak-test never dies
        // at the last hold; `stop()` is the explicit way out.
        if currentIndex >= points.count { currentIndex = 0 }
        let point = points[currentIndex]
        broadcast(coordinate: point.coordinate,
                  speedMps: point.speedMetersPerSecond,
                  course: point.courseDegrees,
                  timestamp: Date())
        currentIndex += 1
    }

    // MARK: - On-demand exact speed

    /// Streams ONE fix at the exact requested speed (mph → m/s) from the
    /// nearest GPX coordinate. Feeding 62.5 mph must make the HUD read 62.5
    /// (after the engine's display unit conversion) with no integration.
    public func setSpeed(mph: Double) {
        manualStreamStop()
        let coordinate = currentCoordinate()
        let speedMps = max(0, mph) / 2.23694
        broadcast(coordinate: coordinate,
                  speedMps: speedMps,
                  course: 0,
                  timestamp: Date())
        DebugLogger.shared.log(String(
            format: "MockLocationManager: exact speed %.2f mph (%.4f m/s) broadcast",
            mph, speedMps))
    }

    /// Holds an exact speed: broadcasts the same mph→m/s fix every second
    /// until `pause()` or another control stops it.
    public func streamSpeed(mph: Double) {
        replayTimer?.cancel()
        replayTimer = nil
        isPlaying = false
        manualStreamTimer?.cancel()
        manualStreamMph = max(0, mph)
        let coordinate = currentCoordinate()
        let speedMps = manualStreamMph! / 2.23694
        let emit: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.broadcast(coordinate: coordinate,
                           speedMps: speedMps,
                           course: 0,
                           timestamp: Date())
        }
        emit()
        manualStreamTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                Task { @MainActor in
                    emit()
                }
            }
        DebugLogger.shared.log(String(
            format: "MockLocationManager: streaming %.2f mph at 1 Hz", manualStreamMph!))
    }

    /// Stops the manual exact-speed stream (keeps the replay cursor where
    /// it is so `play()` resumes the ladder afterwards).
    public func pauseManualStream() {
        manualStreamStop()
    }

    private func manualStreamStop() {
        manualStreamTimer?.cancel()
        manualStreamTimer = nil
        manualStreamMph = nil
    }

    private func currentCoordinate() -> CLLocationCoordinate2D {
        let clamped = min(max(currentIndex, 0), max(points.count - 1, 0))
        guard points.indices.contains(clamped) else {
            return CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740)
        }
        return points[clamped].coordinate
    }
}
#endif
