import SwiftUI

/// Restrained, native Settings. Only real, working controls appear here;
/// the concept's decorative Profile/Venue rows are deliberately absent
/// because the product has no model behind them.
struct SettingsHomeView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @AppStorage("appearancePreference") private var appearancePreference = AppearancePreference.system.rawValue
    @AppStorage("playerAge") private var playerAge = 0
    @State private var showsOnboarding = false

    var body: some View {
        Form {
            #if DEBUG && targetEnvironment(simulator)
            if model.isUIQA {
                Section("Simulator QA · synthetic data") {
                    Picker("Data fixture", selection: Binding(
                        get: { model.qaScenario },
                        set: { scenario in Task { await model.setQAData(scenario) } }
                    )) {
                        ForEach(QASessionScenario.allCases) { scenario in
                            Text(scenario.title).tag(scenario)
                        }
                    }
                    .accessibilityIdentifier("qa-data-fixture")
                    .disabled(model.isSettingQAData)
                    Picker("Layout stress", selection: $model.qaLayout) {
                        ForEach(SimulatorQALayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .accessibilityIdentifier("qa-layout-stress")
                    if model.isSettingQAData { ProgressView("Loading fixture") }
                }
            }
            #endif
            Section {
                Stepper(value: Binding(
                    get: { playerAge > 0 ? playerAge : 30 },
                    set: { playerAge = $0 }
                ), in: 10...80) {
                    LabeledContent("Age") {
                        Text(playerAge > 0 ? "\(playerAge)" : "Not set")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                LabeledContent("Max heart rate") {
                    Text(maxHeartRateText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Player")
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearancePreference) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.label).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                NavigationLink {
                    SessionSyncSheet()
                } label: {
                    LabeledContent("Sync status") {
                        Text(SyncPresentation(model: model).title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                LabeledContent("Sessions on this iPhone") {
                    Text("\(model.sessions.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Storage used") {
                    Text(storageSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Sync and storage")
            }

            Section("Getting started") {
                Button("Review onboarding") { showsOnboarding = true }
            }

            Section("Advanced") {
                NavigationLink("Watch diagnostics") {
                    WatchDiagnosticsView()
                }
                LabeledContent("Version") {
                    Text(versionText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle("Settings")
        .fullScreenCover(isPresented: $showsOnboarding) {
            OnboardingView { showsOnboarding = false }
        }
    }

    private var maxHeartRateText: String {
        guard playerAge > 0 else { return "Estimated" }
        let max = PerformanceCoachV1.heartRateMax(age: playerAge, observedPeak: nil)
        return "\(Int(max.rounded())) bpm"
    }

    private var storageSummary: String {
        let totalBytes = model.sessions.reduce(0) { $0 + $1.byteCount }
        let gigabytes = Double(totalBytes) / 1_000_000_000
        if gigabytes >= 1 {
            return String(format: "%.1f GB", gigabytes)
        }
        let megabytes = Double(totalBytes) / 1_000_000
        if megabytes >= 10 {
            return String(format: "%.0f MB", megabytes)
        }
        if megabytes >= 0.1 {
            return String(format: "%.1f MB", megabytes)
        }
        return String(format: "%.0f KB", Double(totalBytes) / 1_000)
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// App-controlled appearance. System keeps the OS decision; the explicit
/// options exist because the light design is the primary experience.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
