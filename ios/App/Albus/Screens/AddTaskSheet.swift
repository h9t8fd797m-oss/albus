import SwiftUI
import AlbusCore

/// Three fields. Anything more spends the ninety-second window on setup, which
/// is the most common complaint about every planner in this category.
struct AddTaskSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSubmit: (String, String, Date, Int) async -> Void

    @State private var title = ""
    @State private var taskType = "essay"
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
    @State private var hours = 2.0
    @State private var submitting = false

    private let types = ["essay", "problem_set", "reading", "revision", "lab_report", "project"]

    private var canSubmit: Bool {
        title.trimmingCharacters(in: .whitespaces).count >= 2 && !submitting
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
                    Button(submitting ? "Planning…" : "Plan it") {
                        submitting = true
                        let t = title.trimmingCharacters(in: .whitespaces)
                        let minutes = Int(hours * 60)
                        let type = taskType
                        let due = deadline
                        Task {
                            await onSubmit(t, type, due, minutes)
                            dismiss()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }
}
