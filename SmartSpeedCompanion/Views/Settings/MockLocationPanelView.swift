#if DEBUG || DEVELOPER_BUILD
import SwiftUI

/// Developer / Simulator panel for the custom GPX + mock-location system.
/// Lives behind `#if DEBUG || DEVELOPER_BUILD` like every other simulation
/// surface, and is presented as a sheet from Settings → GPS ACCURACY so the
/// production UI never shows it.
///
/// Surface layout (top to bottom):
///   1. ROUTE — bundle load status (point count / name / load error).
///   2. GPX REPLAY — Play ▸ / Pause ⏸ / Stop ⏹ the 1 Hz threshold ladder.
///   3. THRESHOLD JUMPS — seek straight to the 25 / 75 mph GPX landmarks.
///   4. EXACT SPEED — stream any mph on demand (also drives AlertEngine).
///   5. GPS SOURCE — the real-drive mock toggle (`LocationManager.isMockMode`).
///
/// All controls act on `MockLocationManager.shared` / the process-wide
/// `SimulationManager.shared`, so the HUD speedometer, warning triggers,
/// and session recorder respond exactly as they would to real GPS.
@MainActor
struct MockLocationPanelView: View {
    @EnvironmentObject private var driveViewModel: DriveViewModel
    @ObservedObject private var mock = MockLocationManager.shared
    @ObservedObject private var simulation = SimulationManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var manualMph: Double = 65

    var body: some View {
        NavigationStack {
            Form {
                routeSection
                replaySection
                thresholdSection
                exactSpeedSection
                gpsSourceSection
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("MOCK LOCATIONS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 1. Route status

    private var routeSection: some View {
        Section(header: Text("ROUTE (BUNDLED GPX)")
            .font(DesignSystem.labelFont)
            .foregroundColor(DesignSystem.cyan)) {
            if let error = mock.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(DesignSystem.amber)
            } else {
                LabeledContent("Track") { Text(mock.routeName.isEmpty ? "TestRoutes.gpx" : mock.routeName) }
                LabeledContent("Track points") { Text("\(mock.pointCount)") }
            }
            Button("Reload from bundle") {
                mock.stop()
                mock.loadBundledRoute()
            }
            .foregroundColor(DesignSystem.cyan)
        }
        .listRowBackground(DesignSystem.bgPanel)
    }

    // MARK: - 2. Replay transport

    private var replaySection: some View {
        Section(header: Text("GPX REPLAY (1 HZ)")
            .font(DesignSystem.labelFont)
            .foregroundColor(DesignSystem.cyan),
                footer: Text("Streams the 25→75 mph threshold ladder through the same wire as real GPS: SpeedEngine smoothing, the gauge, and AlertEngine all react live.")
                    .font(.caption2)
                    .foregroundColor(.gray)) {
            HStack(spacing: 24) {
                Button {
                    mock.play()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.neonGreen)
                .disabled(mock.isPlaying)

                Button {
                    mock.pause()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.amber)
                .disabled(!mock.isPlaying)

                Button {
                    mock.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.alertRed)
                .disabled(!mock.isPlaying && mock.currentIndex == 0)
            }
            .frame(maxWidth: .infinity)

            if mock.pointCount > 0 {
                LabeledContent("Cursor") {
                    Text("\(min(mock.currentIndex, mock.pointCount)) / \(mock.pointCount)")
                        .monospacedDigit()
                }
            }
        }
        .listRowBackground(DesignSystem.bgPanel)
    }

    // MARK: - 3. Threshold jumps

    private var thresholdSection: some View {
        Section(header: Text("THRESHOLD JUMPS")
            .font(DesignSystem.labelFont)
            .foregroundColor(DesignSystem.cyan),
                footer: Text("Seeks straight to the GPX waypoints carrying exact 25 / 75 mph fixes and broadcasts them immediately.")
                    .font(.caption2)
                    .foregroundColor(.gray)) {
            Button {
                mock.seek(to: MockRouteLandmark.mph25Index)
            } label: {
                Label("Jump to 25 MPH fix", systemImage: "gauge.with.needle")
                    .foregroundColor(.white)
            }
            Button {
                mock.seek(to: MockRouteLandmark.mph75Index)
            } label: {
                Label("Jump to 75 MPH fix", systemImage: "gauge.with.needle")
                    .foregroundColor(.white)
            }
        }
        .listRowBackground(DesignSystem.bgPanel)
    }

    // MARK: - 4. Exact speed on demand

    private var exactSpeedSection: some View {
        Section(header: Text("EXACT SPEED (M/S CONVERSION)")
            .font(DesignSystem.labelFont)
            .foregroundColor(DesignSystem.cyan),
                footer: Text("Bypasses CoreLocation and streams the exact mph→m/s value every second. Push past your buffer to fire the warning beep and red overspeed state on demand.")
                    .font(.caption2)
                    .foregroundColor(.gray)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(Int(manualMph)) MPH")
                        .font(DesignSystem.displayFont)
                        .foregroundColor(.white)
                    Spacer()
                    if let streaming = mock.manualStreamMph {
                        Label("streaming \(Int(streaming))", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundColor(DesignSystem.neonGreen)
                    }
                }
                Slider(value: $manualMph, in: 0...120, step: 1)
                    .tint(DesignSystem.cyan)
            }
            HStack(spacing: 12) {
                Button("Stream") {
                    mock.streamSpeed(mph: manualMph)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.cyan)

                Button("One fix") {
                    mock.setSpeed(mph: manualMph)
                }
                .buttonStyle(.bordered)

                Button("Hold") {
                    simulation.mockSpeed = manualMph
                    simulation.isSimulationActive = true
                }
                .buttonStyle(.bordered)
            }
            if mock.manualStreamMph != nil {
                Button("Stop manual stream", role: .destructive) {
                    mock.pauseManualStream()
                }
            }
        }
        .listRowBackground(DesignSystem.bgPanel)
    }

    // MARK: - 5. GPS source

    private var gpsSourceSection: some View {
        Section(header: Text("GPS SOURCE")
            .font(DesignSystem.labelFont)
            .foregroundColor(DesignSystem.cyan),
                footer: Text("Mock mode intercepts CoreLocation so ONLY simulated fixes reach the app. It auto-engages in the iOS Simulator; leave it on for replay sessions.")
                    .font(.caption2)
                    .foregroundColor(.gray)) {
            Toggle("Mock mode (bypass CoreLocation)",
                   isOn: Binding(
                    get: { driveViewModel.locationManager.isMockMode },
                    set: { driveViewModel.locationManager.isMockMode = $0 }))
                .tint(DesignSystem.neonGreen)

            Toggle("Manual simulation loop",
                   isOn: Binding(
                    get: { simulation.isSimulationActive },
                    set: { simulation.isSimulationActive = $0 }))
                .tint(DesignSystem.neonGreen)
        }
        .listRowBackground(DesignSystem.bgPanel)
    }
}
#endif
