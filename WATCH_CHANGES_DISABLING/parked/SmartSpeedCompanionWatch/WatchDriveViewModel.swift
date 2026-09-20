// Path: SmartSpeedCompanionWatch/WatchDriveViewModel.swift
//
// The watch's own speed engine loop.
//
// GPS SOURCE (per the Phase 2 decision "GPS on both phone and watch")
// ───────────────────────────────────────────────────────────────────
// The watch ALWAYS runs its own CLLocationManager + SpeedEngine when a
// watch session is active. It does not depend on the phone for GPS.
// Phone data arrives separately over WCSession (`WatchPhoneState`) and is
// rendered as a secondary "Phone" chip so the driver can compare the two
// readings if they want; each device's haptics/alerts act independently
// on its own engine.
//
// This reuses the exact same Core engines as the phone (SpeedEngine,
// SpeedLimitService, RoadGeocoder...) so status thresholds, the 15 mph
// continuity guard, and the display-unit contract are identical on both
// devices. `SpeedEngine` is @MainActor, so the entire VM is too.

import Foundation
import CoreLocation
import Combine
import WatchConnectivity
import WidgetKit

@MainActor
public final class WatchDriveViewModel: NSObject, ObservableObject {

    // MARK: - Rendered state

    /// Speed in the DISPLAY unit (mph / km/h) — mirrors SpeedEngine.speed.
    @Published public private(set) var speed: Double = 0
    /// Posted limit, canonical MPH (0 = unresolved). Display value is
    /// derived at render time via `displayLimit`.
    @Published public private(set) var limitMph: Int = 0
    @Published public private(set) var status: SpeedStatus = .safe
    /// True while the watch session is recording (GPS owned by the watch).
    @Published public private(set) var isWatchSessionActive: Bool = false
    /// True while the phone reports an active session over WCSession.
    @Published public private(set) var isPhoneSessionActive: Bool = false
    /// Most recent phone state received (rendered as the "Phone" chip).
    @Published public private(set) var phoneState: WatchPhoneState?
    /// True when the location permission prompt has been answered and GPS
    /// is actually delivering fixes; drives the "waiting for GPS" hint.
    @Published public private(set) var hasGPSFix: Bool = false
    /// Last completed session summary (from the phone or the watch).
    @Published public private(set) var lastSessionSummary: String?

    // MARK: - Engines (shared Core, compiled into this target)

    private let locationManager = LocationManager()
    /// Lazily created on session start — SpeedEngine subscribes to
    /// LocationManager in init, so it must not exist before the user
    /// asks to record (keeps idle GPS/network work at zero).
    private var speedEngine: SpeedEngine?

    /// Subscribe in `startWatchSession` (not init) so nothing observes
    /// engine state while idle.
    private var engineCancellables: Set<AnyCancellable> = []
    /// Timer-driven alert evaluation (~1 s while a session is active),
    /// mirroring AlertEngine's tick cadence on the phone.
    private var monitorTimer: Timer?

    // MARK: - Services

    /// WCSession connector (also owns phone-state freshness stamping).
    let connector = WatchPhoneConnector.shared
    private let haptics = WatchHaptics.shared

    // MARK: - Session summary accumulation (watch-recorded)

    private var sessionStart: Date?
    private var maxSpeedMph: Double = 0
    private var overSamples: Int = 0
    private var totalSamples: Int = 0

    // MARK: - Init

    public override init() {
        super.init()
        // Observe incoming phone state for the "Phone" chip + session badge.
        connector.$phoneState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.phoneState = state
                self.isPhoneSessionActive = state?.isRecording ?? false
            }
            .store(in: &connector.observerCancellables)
    }

    // MARK: - Display helpers

    public var displayLimit: Int {
        SpeedFormatting.displayLimit(
            forMph: limitMph,
            measurementSystem: SpeedFormatting.measurementSystem()
        )
    }

    public var unitLabel: String {
        SpeedFormatting.unitLabelShort(measurementSystem: SpeedFormatting.measurementSystem())
    }

    /// Rendered phone-chip speed (nil = no fresh phone data to show).
    public var phoneChipText: String? {
        guard let state = phoneState else { return nil }
        return "\(Int(state.speed.rounded())) \(unitLabel)"
    }

    // MARK: - Session lifecycle (watch-owned)

    /// Starts a watch-recorded session: requests permission if needed,
    /// creates the engine (which owns limit lookups), and begins the
    /// ~1 s alert tick.
    public func startWatchSession() {
        guard !isWatchSessionActive else { return }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            // The user can tap Start again once the prompt is answered;
            // the button stays enabled and re-entry completes the start.
            DebugLogger.shared.log("WatchDriveViewModel: awaiting location authorization")
            return
        case .denied, .restricted:
            lastSessionSummary = "Location permission is off in Settings."
            return
        default:
            break
        }

        isWatchSessionActive = true
        sessionStart = Date()
        maxSpeedMph = 0
        overSamples = 0
        totalSamples = 0
        haptics.reset()

        // Fresh engine per session so smoothing state never leaks between
        // drives (mirrors the phone's per-session semantics).
        let engine = SpeedEngine(locationManager: locationManager)
        speedEngine = engine

        locationManager.startUpdatingLocation()
        locationManager.setBackgroundUpdates(true)

        engine.$speed
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.speed = value
                // Convert the display-unit speed back to canonical MPH for
                // the max-speed tracker. SpeedFormatting exposes the
                // conversion constant rather than a per-value helper.
                let isMetric = SpeedFormatting.isMetric(SpeedFormatting.measurementSystem())
                let canonicalMph = isMetric ? value / SpeedFormatting.kmhPerMph : value
                self.maxSpeedMph = max(self.maxSpeedMph, canonicalMph)
            }
            .store(in: &engineCancellables)

        engine.$limit
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.limitMph = value
            }
            .store(in: &engineCancellables)

        engine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.status = value
            }
            .store(in: &engineCancellables)

        // ~1 s alert tick — haptic cadence + summary accumulation.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.monitorTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer

        haptics.play(.start)
        writeComplicationSnapshot()
        DebugLogger.shared.log("WatchDriveViewModel: watch session started")
    }

    public func endWatchSession() {
        guard isWatchSessionActive else { return }
        isWatchSessionActive = false

        monitorTimer?.invalidate()
        monitorTimer = nil
        engineCancellables.removeAll()
        speedEngine = nil
        locationManager.stopUpdatingLocation()
        locationManager.setBackgroundUpdates(false)

        lastSessionSummary = buildSummary()
        sessionStart = nil

        haptics.play(.success)
        writeComplicationSnapshot()
        DebugLogger.shared.log("WatchDriveViewModel: watch session ended")
    }

    // MARK: - Complication snapshot

    /// Publishes the last-session snapshot to the watch-local App Group
    /// (`group.com.smartspeedcompanion.app.watch`) and reloads the widget
    /// timelines. Called ONLY on session start/end — complications have a
    /// tight daily refresh budget, so a 1 Hz live speed on the watch face is
    /// deliberately out of scope (the in-app HUD + Smart Stack Live Activity
    /// cover live readings).
    private func writeComplicationSnapshot() {
        let suite = UserDefaults(suiteName: "group.com.smartspeedcompanion.app.watch")
        suite?.set(isWatchSessionActive, forKey: "watchComplicationRecording")
        suite?.set(Int(speed.rounded()), forKey: "watchComplicationLastSpeed")
        suite?.set(limitMph, forKey: "watchComplicationLastLimit")
        suite?.set(status.rawValue, forKey: "watchComplicationLastStatus")
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Tick

    private func monitorTick() {
        guard isWatchSessionActive else { return }

        // Haptic cadence on the watch's own engine state.
        haptics.tick(status: status, hapticsEnabled: hapticsEnabled)

        // Summary accumulation (canonical MPH domain, like the phone).
        totalSamples += 1
        if status == .over { overSamples += 1 }
    }

    /// Watch-side haptics preference (`WatchSettingsSync.defaultsKeyHaptics`).
    public var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: WatchSettingsSync.defaultsKeyHaptics) as? Bool ?? true
    }

    public func setHapticsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: WatchSettingsSync.defaultsKeyHaptics)
        // Convenience overload rebuilds the payload from watch defaults.
        connector.sendSettings()
    }

    /// Manual test pulse from Settings → Haptics → "Test pulse". Plays a
    /// `.directionUp` tap so the user can feel exactly what an alert is
    /// like without waiting for a real overspeed event.
    public func hapticsTickForTest() {
        haptics.play(.directionUp)
    }

    /// Builds the end-of-session line shown on the watch home screen.
    /// Uses the same ±-window math as the phone's AlertEngine so the
    /// watch's summary matches the phone's in-limit percentage semantics.
    private func buildSummary() -> String? {
        guard let start = sessionStart, totalSamples > 0 else { return nil }
        let minutes = Int(Date().timeIntervalSince(start) / 60)
        let inLimitPct = totalSamples > 0
            ? Int((Double(totalSamples - overSamples) / Double(totalSamples) * 100).rounded())
            : 100
        let isMetric = SpeedFormatting.isMetric(SpeedFormatting.measurementSystem())
        let topDisplay = Int((isMetric ? maxSpeedMph * SpeedFormatting.kmhPerMph : maxSpeedMph).rounded())
        return "\(minutes) min · top \(topDisplay) · \(inLimitPct)% in limit"
    }

    // MARK: - Phone bridge

    /// Forwards the watch's Start/End tap to the phone as well, so one
    /// button press starts (or ends) recording on BOTH devices. The phone
    /// session remains the richer one (crash detection, session recorder);
    /// the watch session keeps working if the phone is unreachable.
    public func togglePhoneSession() {
        if isPhoneSessionActive {
            connector.sendCommand(.endSession)
        } else {
            connector.sendCommand(.startSession)
        }
    }
}
