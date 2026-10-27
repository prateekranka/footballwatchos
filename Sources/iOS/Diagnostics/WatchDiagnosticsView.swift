import SwiftUI

struct WatchDiagnosticsView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel

    var body: some View {
        Group {
            if model.watchDiagnostics.isEmpty {
                ContentUnavailableView("No Watch diagnostics", systemImage: "checkmark.shield")
            } else {
                List(model.watchDiagnostics) { report in
                    NavigationLink {
                        WatchDiagnosticDetailView(report: report)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(report.detectedAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                                .font(.headline)
                            Text("Last checkpoint: \(report.checkpoints.last?.code ?? "unknown")")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("Build \(report.buildNumber) · \(report.checkpoints.count) checkpoints")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Watch diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await model.refresh()
        }
        .task {
            await model.refresh()
        }
    }
}

private struct WatchDiagnosticDetailView: View {
    let report: WatchDiagnosticReportV1

    var body: some View {
        List {
            Section("Report") {
                LabeledContent("Detected") {
                    Text(report.detectedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute().second())
                }
                LabeledContent("App") {
                    Text("\(report.appVersion) (\(report.buildNumber))")
                }
                LabeledContent("Watch software") {
                    Text(report.operatingSystemVersion)
                }
            }

            Section("Checkpoints") {
                ForEach(report.checkpoints) { checkpoint in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(checkpoint.code)
                            .font(.body.monospaced())
                        Text(checkpoint.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let detail = checkpoint.detail {
                            Text(detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if !report.logTail.isEmpty {
                Section("Watch log tail (newest first)") {
                    ForEach(Array(report.logTail.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Diagnostic report")
        .navigationBarTitleDisplayMode(.inline)
    }
}
