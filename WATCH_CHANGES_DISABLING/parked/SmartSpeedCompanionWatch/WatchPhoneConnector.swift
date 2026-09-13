// Path: SmartSpeedCompanionWatch/WatchPhoneConnector.swift
//
// The watch side of the phone↔watch WCSession bridge (Phase 2).
//
// PHONE-SIDE MIRROR: SmartSpeedCompanion/Core/WatchSessionController.swift
// Both sides share the payload vocabulary from Core/WatchLink.swift:
//   • phone → watch : WatchPhoneState  (stateKey)
//   • watch → phone : WatchCommand     (commandKey)
//   • both ways     : WatchSettingsSync (settingsKey)
//
// WCSession reaches the watch app in the background for applicationContext /
// userInfo transfers, but NOT for live sendMessage replies (those fail while
// suspended). State therefore travels via applicationContext (latest-wins,
// immediately delivered on next activation) — the correct transport for a
// 1 Hz live readout that must survive the app being suspended.

import Foundation
import WatchConnectivity
import Combine

public final class WatchPhoneConnector: NSObject, WCSessionDelegate, ObservableObject {

    public static let shared = WatchPhoneConnector()

    /// Latest decoded phone state (nil = nothing fresh received yet).
    @Published public var phoneState: WatchPhoneState?

    /// Combine subscriptions from external observers (the drive VM subscribes
    /// in init — exposing the bag keeps lifetimes explicit and testable).
    public var observerCancellables: Set<AnyCancellable> = []

    /// True when the WCSession counterpart app is installed & reachable-ish
    /// (installation state, not live reachability).
    public var isPhoneInstalled: Bool {
        session?.isReachable ?? false
    }

    private var session: WCSession?

    private override init() {
        super.init()
        guard WCSession.isSupported() else {
            DebugLogger.shared.log("WatchPhoneConnector: WCSession unsupported on this device")
            return
        }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
    }

    // MARK: - Watch → Phone sends

    /// Sends a command to the phone. Uses sendMessage when reachable
    /// (instant, wakes the phone app) and falls back to a userInfo transfer
    /// (delivered whenever the phone next processes the queue) otherwise,
    /// so a Start/End tap is never silently dropped.
    public func sendCommand(_ command: WatchCommand) {
        guard let session, session.activationState == .activated else {
            DebugLogger.shared.log("WatchPhoneConnector: cannot send command \(command.rawValue) — session not activated")
            return
        }
        let payload = command.encodedDictionary()

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                DebugLogger.shared.log("WatchPhoneConnector: sendMessage failed (\(error.localizedDescription)) — queueing transferUserInfo fallback")
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
            DebugLogger.shared.log("WatchPhoneConnector: phone unreachable — queued \(command.rawValue) via transferUserInfo")
        }
    }

    /// Sends current watch-side settings to the phone (and is the transport
    /// for the watch→phone direction of the settings sync).
    public func sendSettings(_ settings: WatchSettingsSync) {
        guard let session, session.activationState == .activated else { return }
        let payload = settings.encodedDictionary()
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                session.transferUserInfo(payload)
            })
        } else {
            session.transferUserInfo(payload)
        }
    }

    /// Convenience: builds the settings payload from watch UserDefaults.
    public func sendSettings(
        measurementSystem: String? = nil,
        userBufferMPH: Int? = nil,
        watchHapticsEnabled: Bool? = nil
    ) {
        let settings = WatchSettingsSync(
            measurementSystem: measurementSystem
                ?? UserDefaults.standard.string(forKey: WatchSettingsSync.defaultsKeyMeasurementSystem)
                ?? SpeedFormatting.measurementSystem(),
            userBufferMPH: userBufferMPH
                ?? UserDefaults.standard.object(forKey: WatchSettingsSync.defaultsKeyUserBuffer) as? Int
                ?? 5,
            watchHapticsEnabled: watchHapticsEnabled
                ?? (UserDefaults.standard.object(forKey: WatchSettingsSync.defaultsKeyHaptics) as? Bool ?? true)
        )
        sendSettings(settings)
    }

    // MARK: - WCSessionDelegate

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            DebugLogger.shared.log("WatchPhoneConnector: activation error \(error.localizedDescription)")
        }
    }

    /// Live state updates from the phone (latest-wins applicationContext).
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncoming(payload: applicationContext)
    }

    /// Commands/settings queued while the phone was unreachable.
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncoming(payload: userInfo)
    }

    // MARK: - Payload routing

    private func handleIncoming(payload: [String: Any]) {
        // Phone state → published chip / badges.
        if let state = WatchPhoneState.from(dictionary: payload) {
            DispatchQueue.main.async { [weak self] in
                self?.phoneState = state
            }
        }
        // Settings sync → persist to watch defaults.
        if let settings = WatchSettingsSync.from(dictionary: payload) {
            applySettings(settings)
        }
        // Commands are watch→phone only; if one loops back, ignore silently.
    }

    private func applySettings(_ settings: WatchSettingsSync) {
        UserDefaults.standard.set(settings.measurementSystem, forKey: WatchSettingsSync.defaultsKeyMeasurementSystem)
        UserDefaults.standard.set(settings.userBufferMPH, forKey: WatchSettingsSync.defaultsKeyUserBuffer)
        UserDefaults.standard.set(settings.watchHapticsEnabled, forKey: WatchSettingsSync.defaultsKeyHaptics)
        DebugLogger.shared.log("WatchPhoneConnector: settings applied (haptics=\(settings.watchHapticsEnabled))")
    }
}
