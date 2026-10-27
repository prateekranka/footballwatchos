import SwiftUI

struct AddSessionView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var startedAt = Date.now.addingTimeInterval(-86_400)
    @State private var durationText = "45"
    @State private var sessionType: FootballSessionTypeV1 = .fiveASide
    @State private var validationMessage: String?
    @State private var isSaving = false
    @FocusState private var durationFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Session type", selection: $sessionType) {
                        ForEach(FootballSessionTypeV1.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .accessibilityIdentifier("session-type")
                    Group {
                        if textSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Duration")
                                durationInput
                            }
                        } else {
                            LabeledContent("Duration") { durationInput }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { durationFocused = true }
                    durationPresets
                    DatePicker("Started", selection: $startedAt, in: ...Date.now)
                        .accessibilityIdentifier("session-start")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(PerformanceTheme.warning)
                            .accessibilityIdentifier("session-validation")
                    }
                }
            }
            .navigationTitle("Add session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving || model.repositoryUnavailable)
                        .accessibilityIdentifier("save-session")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { durationFocused = false }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        #if DEBUG && targetEnvironment(simulator)
        .modifier(SimulatorQAEnvironment(model: model))
        #endif
    }

    private var durationPresets: some View {
        HStack(spacing: 8) {
            ForEach([30, 45, 60, 90], id: \.self) { minutes in
                let selected = durationText == "\(minutes)"
                Button {
                    durationText = "\(minutes)"
                    durationFocused = false
                } label: {
                    Text("\(minutes) min")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selected ? PerformanceTheme.accent : PerformanceTheme.accent.opacity(0.10),
                            in: Capsule()
                        )
                        .foregroundStyle(selected ? PerformanceTheme.onAccent : PerformanceTheme.accent)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("\(minutes) minutes")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// The unit sits beside the number, so the row label needs no "(minutes)".
    private var durationInput: some View {
        HStack(spacing: 4) {
            TextField("Minutes", text: $durationText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .focused($durationFocused)
                .accessibilityLabel("Duration in minutes")
                .accessibilityIdentifier("session-duration")
                .frame(minWidth: 64)
            Text("min")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func save() {
        durationFocused = false
        guard let minutes = Int(durationText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = ManualSessionDraft.ValidationError.duration.localizedDescription
            return
        }
        let draft = ManualSessionDraft(startedAt: startedAt, durationMinutes: minutes, sessionType: sessionType)
        do {
            try draft.validate()
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        isSaving = true
        validationMessage = nil
        Task {
            if await model.addManualSession(draft) != nil {
                dismiss()
            } else {
                validationMessage = model.message
                isSaving = false
            }
        }
    }
}
