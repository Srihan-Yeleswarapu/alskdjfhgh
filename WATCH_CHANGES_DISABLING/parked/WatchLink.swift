// Path: Core/WatchLink.swift
//
// Shared payload vocabulary for the phone↔watch pairing (Phase 2 of the
// Apple Watch integration).
//
// COMPILED INTO BOTH TARGETS
// ──────────────────────────
//   • SmartSpeedCompanion (iOS)          — phone side, via WatchSessionController
//   • SmartSpeedCompanionWatch (watchOS) — watch side, via WatchPhoneConnector
//
// The file is deliberately dependency-free: Foundation only. No
// WatchConnectivity import here — the transport lives in the per-target
// controllers; these types only define WHAT crosses the Bluetooth link so
// both sides agree on the schema and the payloads stay unit-testable.
//
// UNIT CONTRACT (mirrors SpeedEngine exactly — do not "fix" one side)
// ────────────────────────────────────────────────────────────────────
//   • `speed`      is already expressed in the user's DISPLAY unit
//                  (mph for Imperial, km/h for Metric) — same as
//                  `SpeedEngine.speed`, which the phone HUD renders
//                  without conversion.
//   • `limitMph`   is canonical MPH — same as `SpeedEngine.limit`.
//                  The receiving side runs it through
//                  `SpeedFormatting.displayLimit(forMph:measurementSystem:)`.
//   • `status`     is the raw `SpeedStatus` rawValue ("safe" | "warning" | "over").
//   • `measurementSystem` mirrors `SpeedFormatting.measurementSystem()` so the
//                  watch renders the same units the phone shows without a
//                  round-trip through watch-local settings.

import Foundation

// MARK: - Phone → Watch: live driving state

/// Snapshot of the phone's live drive state, broadcast to the watch while a
/// session or navigation is active. Encoded as the WCSession
/// `applicationState` / `userInfo` value under `WatchLinkKeys.stateKey`.
public struct WatchPhoneState: Codable, Equatable {
    /// Current speed in the user's DISPLAY unit (see unit contract above).
    public var speed: Double
    /// Posted limit, canonical MPH (0 = "no limit resolved yet").
    public var limitMph: Int
    /// `SpeedStatus.rawValue`.
    public var status: String
    /// True while the phone is recording a drive session.
    public var isRecording: Bool
    /// True while the phone is actively navigating a route.
    public var isNavigating: Bool
    /// Wall-clock time the snapshot was taken. The watch uses this to detect
    /// staleness: if `timestamp` is older than `stalenessWindow` the watch
    /// switches to its own GPS per the user's "both devices have GPS" choice.
    public var timestamp: Date
    /// "Imperial" | "Metric" — mirrored so the watch displays identical units.
    public var measurementSystem: String

    // Navigation metadata (nil when not navigating).
    public var nextManeuver: String?
    public var distanceToNextTurnMeters: Double?
    public var eta: Date?

    public init(
        speed: Double,
        limitMph: Int,
        status: String,
        isRecording: Bool,
        isNavigating: Bool,
        measurementSystem: String,
        nextManeuver: String? = nil,
        distanceToNextTurnMeters: Double? = nil,
        eta: Date? = nil,
        timestamp: Date = Date()
    ) {
        self.speed = speed
        self.limitMph = limitMph
        self.status = status
        self.isRecording = isRecording
        self.isNavigating = isNavigating
        self.measurementSystem = measurementSystem
        self.nextManeuver = nextManeuver
        self.distanceToNextTurnMeters = distanceToNextTurnMeters
        self.eta = eta
        self.timestamp = timestamp
    }

    /// A phone state older than this is considered stale on the watch and the
    /// watch falls back to its own GPS. 6 s ≈ two missed 1 Hz broadcast ticks
    /// plus Bluetooth latency headroom.
    public static let stalenessWindow: TimeInterval = 6.0
}

// MARK: - Watch → Phone: commands

/// Commands the watch sends to the phone. Delivered as a single-key
/// dictionary under `WatchLinkKeys.commandKey` so every command is atomic
/// (no partial-dictionary merging semantics).
public enum WatchCommand: String, Codable, Equatable {
    /// Start recording a drive session (mirrors `DriveViewModel.startSession`).
    case startSession
    /// End the current drive session (mirrors `DriveViewModel.endSession`).
    case endSession
    /// Silence the current overspeed alert for one snooze window
    /// (the watch-side "I know" — mirrors the in-app snooze).
    case snoozeAlert
    /// Watch asks for a fresh `WatchPhoneState` immediately
    /// (on WCSession activation, app foreground, or after a stall).
    case requestState
    /// Watch confirms the user changed a synced setting on the wrist;
    /// carries the values via `WatchSettingsSync`.
    case applySettings
}

// MARK: - Settings sync (bidirectional)

/// User preferences mirrored across the link so both devices agree. Written
/// by whichever side changed a setting; the receiving side persists to its
/// own local defaults (`UserDefaults` on iOS, `UserDefaults.standard` on
/// watchOS — App Groups do NOT sync iPhone↔watch, which is why this
/// explicit channel exists at all).
public struct WatchSettingsSync: Codable, Equatable {
    public var measurementSystem: String   // "Imperial" | "Metric"
    public var userBufferMPH: Int          // -5...10, alert buffer
    public var watchHapticsEnabled: Bool   // wrist haptic alerts on/off

    public init(
        measurementSystem: String,
        userBufferMPH: Int,
        watchHapticsEnabled: Bool
    ) {
        self.measurementSystem = measurementSystem
        self.userBufferMPH = userBufferMPH
        self.watchHapticsEnabled = watchHapticsEnabled
    }

    /// Canonical watch-side storage keys (watch `UserDefaults.standard`).
    public static let defaultsKeyMeasurementSystem = "watchMeasurementSystem"
    public static let defaultsKeyUserBuffer = "watchUserBuffer"
    public static let defaultsKeyHaptics = "watchHapticsEnabled"
}

// MARK: - Transport keys

/// Dictionary keys used on the WCSession `userInfo` / `messageContent` /
/// `applicationState` payloads. Kept in one place so a typo cannot silently
/// fork the schema between targets.
public enum WatchLinkKeys {
    /// Value: encoded `WatchPhoneState` (phone → watch).
    public static let stateKey = "watchPhoneState"
    /// Value: `WatchCommand.rawValue` string (watch → phone).
    public static let commandKey = "watchCommand"
    /// Value: encoded `WatchSettingsSync` (bidirectional).
    public static let settingsKey = "watchSettingsSync"
}

// MARK: - Codable helpers over WCSession dictionaries
//
// WCSession moves `[String: Any]` dictionaries, so payloads travel as JSON
// blobs under a single key. These helpers centralize encode/decode + error
// swallowing (a malformed payload must never crash a driving app).

extension WatchPhoneState {
    public func encodedDictionary() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [WatchLinkKeys.stateKey: data]
    }

    public static func from(dictionary: [String: Any]) -> WatchPhoneState? {
        guard let data = dictionary[WatchLinkKeys.stateKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchPhoneState.self, from: data)
    }
}

extension WatchCommand {
    public func encodedDictionary() -> [String: Any] {
        [WatchLinkKeys.commandKey: rawValue]
    }

    public static func from(dictionary: [String: Any]) -> WatchCommand? {
        guard let raw = dictionary[WatchLinkKeys.commandKey] as? String else { return nil }
        return WatchCommand(rawValue: raw)
    }
}

extension WatchSettingsSync {
    public func encodedDictionary() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [WatchLinkKeys.settingsKey: data]
    }

    public static func from(dictionary: [String: Any]) -> WatchSettingsSync? {
        guard let data = dictionary[WatchLinkKeys.settingsKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSettingsSync.self, from: data)
    }
}
