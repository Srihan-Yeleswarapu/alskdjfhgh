// Path: SmartSpeedCompanionWatch/WatchApp.swift
//
// Speedio watch app entry point (watchOS 11+).
//
// The watch app is intentionally single-scene: home HUD + settings sheet.
// `WatchDriveViewModel` owns the GPS/session loop; `WatchPhoneConnector`
// is created by the VM (which activates WCSession at init).

import SwiftUI

@main
struct SpeedioWatchApp: App {
    @StateObject private var viewModel = WatchDriveViewModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchHomeView(viewModel: viewModel)
            }
        }
    }
}
