import SwiftUI
import AlbusCore

/// A step being edited.
///
/// A value, not the `@Model`, so Cancel cancels — editing the model directly
/// would persist every keystroke and re-run the scheduler on each one.
struct StepDraft: Identifiable, Equatable {
    var id: UUID
    var title: String
    var minutesText: String
    var isExisting: Bool

    static var empty: StepDraft {
        StepDraft(id: UUID(), title: "", minutesText: "30", isExisting: false)
    }

    @MainActor
    init(_ step: Subtask) {
        id = step.id
        title = step.title
        minutesText = String(step.estimatedMinutes)
        isExisting = true
    }

    init(id: UUID, title: String, minutesText: String, isExisting: Bool) {
        self.id = id
        self.title = title
        self.minutesText = minutesText
        self.isExisting = isExisting
    }

    /// Clamped to the same range the coordinator enforces, so what the sheet
    /// shows is what gets saved.
    var minutes: Int { max(5, min(600, Int(minutesText.trimmed) ?? 30)) }
    var isSavable: Bool { title.trimmed.count >= 2 }
}

/// Editing one step of the plan.
///
/// Albus proposes; the student decides. A plan you cannot correct is one you
/// stop trusting the first time it is wrong about how long something takes —
/// and being wrong about that is normal, which is the whole reason the app
/// learns from measured sessions.
struct StepEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: StepDraft
    let onSave: (StepDraft) -> Void
    var onDelete: (() -> Void)?

    @State private var confirmingDelete = false

    private static let presets = [15, 25, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            Form {
                Section("Step") {
                    TextField("What are you doing?", text: $draft.title, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    HStack {
                        TextField("Minutes", text: $draft.minutesText)
                            .keyboardType(.numberPad)
                        Text("minutes")
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Tokens.Spacing.s) {
                            ForEach(Self.presets, id: \.self) { value in
                                FilterChip(title: "\(value)m",
                                           isSelected: draft.minutesText == String(value)) {
                                    draft.minutesText = String(value)
                                }
                            }
                        }
                    }
                } header: {
                    Text("How long")
                } footer: {
                    Text("Changing this re-flows everything after it. Between 5 and 600 minutes.")
                }

                if draft.isExisting, onDelete != nil {
                    Section {
                        Button("Delete step", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(draft.isExisting ? "Edit step" : "Add step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(!draft.isSavable)
                }
            }
            .confirmationDialog("Delete this step?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The time it was holding goes back to the rest of your plan.")
            }
        }
    }
}

/// Reordering the plan.
///
/// A `List` in edit mode rather than drag handles on the main screen: the plan
/// is a custom rail with a connector between nodes, and a drag gesture on top of
/// that fights the scroll view. A separate sheet gets the system behaviour for
/// free and is honest about being a mode.
struct StepReorderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let steps: [Subtask]
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(steps) { step in
                    HStack(spacing: Tokens.Spacing.m) {
                        Text(step.title)
                            .font(Tokens.Typography.label)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer()
                        Text(DurationText.short(minutes: step.estimatedMinutes))
                            .font(Tokens.Typography.mono)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }
                }
                .onMove(perform: onMove)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
