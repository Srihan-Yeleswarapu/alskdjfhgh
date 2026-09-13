// Path: SmartSpeedCompanionWatch/WatchSettingsView.swift
//
// Wrist-side settings. Every change is persisted to watch defaults
// (App Groups do NOT sync iPhone↔watch) and pushed to the phone via
// `WatchSettingsSync` over WCSession — the phone keeps the authoritative
// copy and applies what it can.

import SwiftUI

struct WatchSettingsView: View {
    @ObservedObject var viewModel: WatchDriveViewModel

    @AppStorage(WatchSettingsSync.defaultsKeyMeasurementSystem)
    private var measurementSystem: String = "Imperial"
    @AppStorage(WatchSettingsSync.defaultsKeyUserBuffer)
    private var userBuffer: Int = 5
    @AppStorage(WatchSettingsSync.defaultsKeyHaptics)
    private var hapticsEnabled: Bool = true

    var body: some View {
        Form {
            Section("Units") {
                Picker("Units", selection: $measurementSystem) {
                    Text("mph").tag("Imperial")
                    Text("km/h").tag("Metric")
                }
                .onChange(of: measurementSystem) { _, newValue in
                    viewModel.connector.sendSettings(
                        measurementSystem: newValue,
                        userBufferMPH: userBuffer,
                        watchHapticsEnabled: hapticsEnabled
                    )
                }
            }

            Section("Alert buffer") {
                // Display-unit label matches the phone's ±-mph buffer
                // semantics; the value is canonical and unit-independent.
                Stepper(value: $userBuffer, in: -5...10) {
                    Text("Alert at +\(userBuffer)")
                }
                .onChange(of: userBuffer) { _, newValue in
                    viewModel.connector.sendSettings(
                        measurementSystem: measurementSystem,
                        userBufferMPH: newValue,
                        watchHapticsEnabled: hapticsEnabled
                    )
                }
            }

            Section("Haptics") {
                Toggle("Overspeed pulses", isOn: $hapticsEnabled)
                    .onChange(of: hapticsEnabled) { _, newValue in
                        viewModel.connector.sendSettings(
                            measurementSystem: measurementSystem,
                            userBufferMPH: userBuffer,
                            watchHapticsEnabled: newValue
                        )
                    }
                Button {
                    viewModel.hapticsTickForTest()
                } label: {
                    Label("Test pulse", systemImage: "waveform")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
