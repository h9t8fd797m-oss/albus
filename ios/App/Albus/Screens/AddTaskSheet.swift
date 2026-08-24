import SwiftUI
import SwiftData
import AlbusCore

/// Adding an assignment.
///
/// The flow asks for everything Albus needs to plan well and nothing else:
/// what it is, what kind, what it is marked against, anything the teacher said,
/// how urgent it is, when it is due, and how long the student thinks it will
/// take. Rubric and instructions are the two that actually change the plan —
/// both were previously either impossible to supply or silently ignored.
struct AddTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Course.displayName) private var courses: [Course]
    @Query(sort: \Rubric.updatedAt, order: .reverse) private var rubrics: [Rubric]

    let onAdd: (NewAssignment) -> Void

    @State private var title = ""
    @State private var taskType = "essay"
    @State private var courseID: UUID?
    @State private var rubricID: UUID?
    @State private var notes = ""
    @State private var priority: AssignmentPriority = .normal
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
    @State private var hours = 2.0
    @State private var creatingRubric: RubricDraft?
    @State private var addingCourse = false
    @State private var newCourseName = ""

    /// The vocabulary the server's check constraint accepts. Kept here rather
    /// than as free text so a typo is a compile error, not a 422.
    private static let types: [(id: String, label: String)] = [
        ("essay", "Essay"),
        ("problem_set", "Problem set"),
        ("lab_report", "Lab report"),
        ("reading", "Reading"),
        ("revision", "Revision"),
        ("project", "Project"),
        ("presentation", "Presentation"),
        ("other", "Other")
    ]

    private var selectedCourse: Course? { courses.first { $0.id == courseID } }
    private var selectedRubric: Rubric? { rubrics.first { $0.id == rubricID } }

    private var canAdd: Bool {
        title.trimmed.count >= 2
    }

    var body: some View {
        AlbusSheetScaffold(
            eyebrow: "New assignment",
            title: "What's on your plate?",
            primaryTitle: "Plan it",
            isPrimaryEnabled: canAdd,
            primaryAction: add,
            onCancel: { dismiss() }
        ) {
            SheetField(label: "Assignment") {
                TextField("What is it?", text: $title)
                    .textInputAutocapitalization(.sentences)
            }

            SheetPicker(label: "Type", options: Self.types.map { (value: $0.id, title: $0.label) },
                       selection: $taskType)

            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SheetPicker(
                    label: "Subject",
                    options: [(value: UUID?.none, title: "None")]
                        + courses.map { (value: UUID?.some($0.id), title: $0.displayName) },
                    selection: $courseID
                )
                // Subjects had no way of being created, so the picker was
                // permanently empty and every assignment was "General" —
                // which also meant Albus never knew what the student takes.
                Button("New subject\u{2026}") { addingCourse = true }
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.accent)
            }

            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SheetPicker(
                    label: "Marked against",
                    options: [(value: UUID?.none, title: "None")]
                        + rubrics.map { (value: UUID?.some($0.id), title: $0.name) },
                    selection: $rubricID
                )
                Button("New rubric\u{2026}") { creatingRubric = .empty }
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.accent)
                Text(selectedRubric == nil
                     ? "Optional. With a rubric, Albus shapes the steps around the criteria and can mark your work against them later."
                     : selectedRubric!.summary)
                    .font(Tokens.Typography.micro)
                    .foregroundStyle(Tokens.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SheetField(label: "Instructions (optional)") {
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 70)
                    .font(Tokens.Typography.body)
                    .onChange(of: notes) {
                        if notes.count > NewAssignment.maxNoteCharacters {
                            notes = String(notes.prefix(NewAssignment.maxNoteCharacters))
                        }
                    }
            }
            Text("Anything the teacher said: sources to use, a word count, a question to answer.")
                .font(Tokens.Typography.micro)
                .foregroundStyle(Tokens.Palette.inkMuted)
                .padding(.top, -Tokens.Spacing.s)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("Priority")
                    .font(Tokens.Typography.micro)
                    .tracking(Tokens.Tracking.overline)
                    .foregroundStyle(Tokens.Palette.inkMuted)
                    .textCase(.uppercase)
                Picker("Priority", selection: $priority) {
                    ForEach(AssignmentPriority.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .tint(Tokens.Palette.accent)
            }

            SheetField(label: "Due") {
                DatePicker("Due", selection: $deadline, in: Date.now...,
                          displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }

            SheetField(label: "About how long") {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("About \(hours, format: .number.precision(.fractionLength(1))) hours")
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.ink)
                    Slider(value: $hours, in: 0.5...20, step: 0.5)
                        .tint(Tokens.Palette.accent)
                }
            }
        }
        .sheet(isPresented: $addingCourse) {
            NewSubjectSheet(name: $newCourseName) { addCourse() }
        }
        .sheet(item: $creatingRubric) { draft in
            RubricEditorSheet(draft: draft) { saved in
                // Saved through the same path the Rubrics tab uses, then
                // selected — so a rubric written here is a real saved rubric,
                // reusable next time, not a one-off attached to this task.
                if let created = RubricWriter.commit(saved, context: modelContext) {
                    rubricID = created
                }
            }
        }
    }

    /// Colours cycle through the token set rather than being chosen: a subject's
    /// colour is a property of the course, and picking one per assignment is how
    /// HIST ends up red on one screen and green on another.
    private func addCourse() {
        let name = newCourseName.trimmed
        newCourseName = ""
        guard !name.isEmpty else { return }

        let palette = Tokens.SubjectColor.allCases
        let colour = palette[courses.count % palette.count]
        let course = Course(displayName: name, colorKey: colour)
        modelContext.insert(course)
        try? modelContext.save()
        courseID = course.id

        Task {
            // The remote id is what the breakdown endpoint needs to attach the
            // assignment to a course. Without it the subject stays local, which
            // is worse but not broken.
            if let remote = await ProfileService().createCourse(
                displayName: name, colorKey: colour.rawValue
            ) {
                course.remoteID = remote
                try? modelContext.save()
            }
        }
    }

    private func add() {
        onAdd(NewAssignment(
            title: title.trimmed,
            taskType: taskType,
            deadline: deadline,
            estimatedMinutes: Int(hours * 60),
            priority: priority,
            course: selectedCourse,
            rubric: selectedRubric,
            notes: notes.trimmed.nilIfEmpty
        ))
        dismiss()
    }
}

/// Naming a subject. Small enough that it doesn't need its own file, but still
/// built from the same scaffold — a `.alert` with a text field is the single
/// most "default iPhone" control there is, and this is exactly the kind of
/// popup this pass exists to replace.
private struct NewSubjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    let onAdd: () -> Void

    private var canAdd: Bool { !name.trimmed.isEmpty }

    var body: some View {
        AlbusSheetScaffold(
            eyebrow: "New subject",
            title: "What's it called?",
            primaryTitle: "Add",
            isPrimaryEnabled: canAdd,
            primaryAction: {
                onAdd()
                dismiss()
            },
            onCancel: {
                name = ""
                dismiss()
            },
            // A fixed height rather than .medium/.large: this is one field and
            // a footnote, and giving it half the screen would be mostly empty
            // paper background under the keyboard.
            detents: [.height(340)]
        ) {
            SheetField {
                TextField("e.g. History HL", text: $name)
                    .textInputAutocapitalization(.words)
            }
            Text("Albus uses your subjects to pitch answers at the right level.")
                .font(Tokens.Typography.micro)
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
    }
}
