import SwiftUI
import AlbusCore

/// Three fields. Anything more spends the ninety-second window on setup, which
/// is the most common complaint about every planner in this category.
struct AddTaskSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Reports the values and returns. Generation is the caller's job, so the
    /// sheet does not outlive the tap.
    let onSubmit: (String, String, Date, Int) -> Void

    @State private var title = ""
    @State private var taskType = "essay"
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
    @State private var hours = 2.0

    private let types = ["essay", "problem_set", "reading", "revision", "lab_report", "project"]

    private var canSubmit: Bool {
        title.trimmingCharacters(in: .whitespaces).count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Assignment") {
                    TextField("What is it?", text: $title)
                        .textInputAutocapitalization(.sentences)
                    Picker("Type", selection: $taskType) {
                        ForEach(types, id: \.self) { type in
                            Text(type.replacingOccurrences(of: "_", with: " ").capitalized).tag(type)
                        }
                    }
                }
                Section("When and how long") {
                    DatePicker("Due", selection: $deadline, in: Date.now...,
                               displayedComponents: [.date, .hourAndMinute])
                    // A slider rather than a keyboard: the number is a guess
                    // either way, and the estimator corrects it over time.
                    VStack(alignment: .leading) {
                        Text("About \(hours, format: .number.precision(.fractionLength(1))) hours")
                        Slider(value: $hours, in: 0.5...20, step: 0.5)
                    }
                }
            }
            .navigationTitle("New assignment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Hands off and closes immediately rather than holding the
                    // sheet open for the whole generation.
                    //
                    // The assignment is persisted before the network call, so
                    // it is already in Tasks by the time this closes; Today
                    // shows "Albus is planning…" while the steps arrive. The
                    // old behaviour blocked the student behind a modal for
                    // ~30 seconds and hid the app they had just added work to.
                    Button("Plan it") {
                        onSubmit(title.trimmingCharacters(in: .whitespaces),
                                 taskType, deadline, Int(hours * 60))
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }
}
