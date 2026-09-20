// Path: Core/WatchSessionController.swift
//
// The phone side of the phone↔watch WCSession bridge (Phase 2).
//
// WATCH-SIDE MIRROR: SmartSpeedCompanionWatch/WatchPhoneConnector.swift
// Payload vocabulary: Core/WatchLink.swift (compiled into both targets).
//
// RESPONSIBILITIES
// ────────────────
//   • Broadcast `WatchPhoneState` snapshots to the watch while a drive
//     session or navigation is active (applicationContext, latest-wins).
//   • Execute watch commands (start/end session, snooze) against
//     `AppDelegate.sharedDriveViewModel` on the main actor.
//   • Receive wrist-side `WatchSettingsSync` changes.
//
// TRANSPORT NOTES
// ───────────────
//   • Outgoing state rides `updateApplicationContext` — latest-wins,
//     delivered even when the watch app is suspended. `sendMessage` is
//     deliberately NOT used for state: it fails while the watch app is
//     backgrounded, and a dropped snapshot is harmless (the watch renders
//     its own GPS view meanwhile).
//   • Incoming commands arrive via sendMessage (watch reachable) or
//     transferUserInfo (queued) — both handled below.

import Foundation
import WatchConnectivity
import Combine

public final class WatchSessionController: NSObject, WCSessionDelegate {

    public static let shared = WatchSessionController()

    // MARK: - Observation state

    private var cancellables = Set<AnyCancellable>()
    private var isObserving = false
    /// True while the phone is recording or navigating — drives the
    /// continuous 5 s broadcast cadence.
    private var sessionActive = false
    /// Last snapshot broadcast, for idle dedupe (an unchanged
    /// applicationContext write still wakes the watch radio — avoid it).
    private var lastBroadcast: WatchPhoneState?

    // MARK: - Init

    private override init() {
        super.init()
        guard WCSession.isSupported() else {
            DebugLogger.shared.log("WatchSessionController: WCSession unsupported on this phone")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Called from AppDelegate.didFinishLaunching. Activation already
    /// happened in init; kept as an explicit idempotent hook for clarity.
    public func activate() {}

    // MARK: - State observation + broadcast

    /// Subscribes to the shared DriveViewModel:
    ///   • 5 s throttled speed cadence while a session is active
    ///     (matches the Live Activity tick the phone already runs),
    ///   • immediate broadcast on session start/stop and status
    ///     transitions (safe→warning→over) so the watch badge and
    ///     phone chip never lag a state change.
    public func observe(viewModel: DriveViewModel) {
        guard !isObserving else { return }
        isObserving = true

        viewModel.$speed
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                self.maybeBroadcast(viewModel: viewModel, force: false)
            }
            .store(in: &cancellables)

        viewModel.$isRecording
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.sessionActive = viewModel.isRecording || viewModel.isNavigating
                self.maybeBroadcast(viewModel: viewModel, force: true)
            }
            .store(in: &cancellables)

        viewModel.$status
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.maybeBroadcast(viewModel: viewModel, force: true)
            }
            .store(in: &cancellables)
    }

    private func maybeBroadcast(viewModel: DriveViewModel, force: Bool) {
        // While a session is active: broadcast every cadence tick. While
        // idle: only on forced transitions, so an idle phone never chatters.
        guard sessionActive || force else { return }

        let state = WatchPhoneState(
            speed: viewModel.speed,
            limitMph: viewModel.limit,
            status: viewModel.status.rawValue,
            isRecording: viewModel.isRecording,
            isNavigating: viewModel.isNavigating,
            measurementSystem: SpeedFormatting.measurementSystem(),
            nextManeuver: viewModel.isNavigating ? viewModel.nextManeuverInstruction : nil,
            distanceToNextTurnMeters: viewModel.isNavigating ? viewModel.distanceToNextTurn : nil,
            eta: viewModel.isNavigating ? viewModel.eta : nil
        )
        // Idle dedupe: identical snapshots are dropped (force == false only).
        if !force, state == lastBroadcast { return }
        lastBroadcast = state
        broadcast(state)
    }

    private func broadcast(_ state: WatchPhoneState) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(state.encodedDictionary())
        } catch {
            DebugLogger.shared.log("WatchSessionController: applicationContext update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - WCSessionDelegate

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            DebugLogger.shared.log("WatchSessionController: activation error \(error.localizedDescription)")
        }
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        // Apple guidance: deactivate → re-activate to support pairing changes.
        session.activate()
    }

    // MARK: - Incoming (watch → phone)

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(payload: message)
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncoming(payload: userInfo)
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncoming(payload: applicationContext)
    }

    private func handleIncoming(payload: [String: Any]) {
        if let command = WatchCommand.from(dictionary: payload) {
            execute(command)
        }
        if let settings = WatchSettingsSync.from(dictionary: payload) {
            applySettings(settings)
        }
    }

    // MARK: - Command execution

    private func execute(_ command: WatchCommand) {
        DebugLogger.shared.log("WatchSessionController: received command \(command.rawValue)")
        switch command {
        case .startSession:
            Task { @MainActor in
                guard !AppDelegate.sharedDriveViewModel.isRecording else { return }
                AppDelegate.sharedDriveViewModel.startSession()
            }
        case .endSession:
            Task { @MainActor in
                guard AppDelegate.sharedDriveViewModel.isRecording else { return }
                AppDelegate.sharedDriveViewModel.endSession()
            }
        case .snoozeAlert:
            // Same 15 s window the CarPlay snooze button uses
            // (CarPlayNavigationRootTemplate.snoozeButton).
            Task { @MainActor in
                AppDelegate.sharedDriveViewModel.alertEngine.snoozeFor(15)
            }
        case .requestState:
            Task { @MainActor in
                let vm = AppDelegate.sharedDriveViewModel
                self.sessionActive = vm.isRecording || vm.isNavigating
                self.maybeBroadcast(viewModel: vm, force: true)
            }
        case .applySettings:
            break // settings travel in their own payload; nothing to do
        }
    }

    // MARK: - Settings application (watch → phone)

    private func applySettings(_ settings: WatchSettingsSync) {
        let defaults = UserDefaults.standard

        if defaults.string(forKey: SpeedFormatting.measurementSystemDefaultsKey) != settings.measurementSystem {
            defaults.set(settings.measurementSystem, forKey: SpeedFormatting.measurementSystemDefaultsKey)
            // Mirror to the App Group so widget/Live Activity units stay
            // consistent with the wrist-side change (same path the
            // in-app Settings UNITS picker uses).
            SpeedFormatting.writeMeasurementSystemToAppGroup(settings.measurementSystem)
        }

        // SpeedEngine.userBuffer accepts Int- or Double-backed values, so an
        // Int write from the watch is read correctly by the phone engine.
        if (defaults.object(forKey: "userBuffer") as? Int) != settings.userBufferMPH {
            defaults.set(settings.userBufferMPH, forKey: "userBuffer")
        }

        // `watchHapticsEnabled` is watch-local by definition; the phone does
        // not store it (the wrist owns its own haptics surface).

        DebugLogger.shared.log("WatchSessionController: settings applied from watch (units=\(settings.measurementSystem), buffer=\(settings.userBufferMPH))")
    }
}
