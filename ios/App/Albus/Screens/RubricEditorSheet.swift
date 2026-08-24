import SwiftUI
import AlbusCore

/// An edit in progress.
///
/// A plain value rather than the `@Model` itself, so Cancel actually cancels.
/// Editing the model directly would persist every keystroke and leave a
/// half-typed rubric behind the moment the sheet is dismissed.
struct RubricDraft: Identifiable, Equatable {
    var id: UUID
    var name: String
    var body: String
    var marksText: String
    var items: [Row]
    /// True when this draft came from a rubric that already exists.
    var isExisting: Bool

    struct Row: Identifiable, Equatable {
        var id = UUID()
        var code: String = ""
        var name: String = ""
        var marksText: String = ""
        var guidance: String = ""

        var trimmedCode: String? { code.trimmed.nilIfEmpty }
        var trimmedName: String { name.trimmed }
        var trimmedGuidance: String? { guidance.trimmed.nilIfEmpty }
        var marks: Int? { Int(marksText.trimmed) }
        var isUsable: Bool { !trimmedName.isEmpty }
    }

    static var empty: RubricDraft {
        RubricDraft(id: UUID(), name: "", body: "", marksText: "", items: [], isExisting: false)
    }

    @MainActor
    init(_ rubric: Rubric) {
        id = rubric.id
        name = rubric.name
        body = rubric.body ?? ""
        marksText = rubric.totalMarks.map(String.init) ?? ""
        items = rubric.sortedItems.map {
            Row(code: $0.code ?? "", name: $0.name,
                marksText: $0.marks.map(String.init) ?? "", guidance: $0.guidance ?? "")
        }
        isExisting = true
    }

    init(id: UUID, name: String, body: String, marksText: String,
         items: [Row], isExisting: Bool) {
        self.id = id
        self.name = name
        self.body = body
        self.marksText = marksText
        self.items = items
        self.isExisting = isExisting
    }

    var trimmedName: String { name.trimmed }
    var trimmedBody: String? { body.trimmed.nilIfEmpty }
    var totalMarks: Int? { Int(marksText.trimmed) }
    var usableItems: [Row] { items.filter(\.isUsable) }

    /// A rubric with a name but nothing to mark against would produce confident
    /// grading out of thin air. The sheet will not save one.
    var isSavable: Bool {
        !trimmedName.isEmpty && (trimmedBody != nil || !usableItems.isEmpty)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Two ways in, because both are real: most students have a rubric as a block of
/// text on the sheet, some want it split into criteria they can see marks
/// against. Neither is required to use the other.
struct RubricEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: RubricDraft
    let onSave: (RubricDraft) -> Void

    private var bodyRemaining: Int { Rubric.maxBodyCharacters - draft.body.count }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Mr Hall's essay rubric", text: $draft.name)
                }

                Section {
                    TextEditor(text: $draft.body)
                        .frame(minHeight: 140)
                        .font(Tokens.Typography.body)
                        // The server caps the column at the same number. Enforcing
                        // it here means a rubric that saves locally is one the
                        // server will also accept, rather than one that syncs and
                        // silently truncates.
                        .onChange(of: draft.body) {
                            if draft.body.count > Rubric.maxBodyCharacters {
                                draft.body = String(draft.body.prefix(Rubric.maxBodyCharacters))
                            }
                        }
                } header: {
                    Text("Paste the rubric")
                } footer: {
                    Text(bodyRemaining < 500
                         ? "\(max(0, bodyRemaining)) characters left."
                         : "Paste the marking criteria straight off the assignment sheet. That's enough — the criteria below are optional.")
                }

                Section {
                    ForEach($draft.items) { $row in
                        CriterionRow(row: $row)
                    }
                    .onDelete { draft.items.remove(atOffsets: $0) }
                    .onMove { draft.items.move(fromOffsets: $0, toOffset: $1) }

                    if draft.items.count < Rubric.maxItems {
                        Button {
                            draft.items.append(.init())
                        } label: {
                            Label("Add criterion", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Criteria (optional)")
                } footer: {
                    Text(draft.items.isEmpty
                         ? "Add these if you want marks broken down per criterion when Albus grades your work."
                         : "Albus will shape your plan around these, in this order.")
                }

                Section {
                    TextField("Total marks", text: $draft.marksText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Leave blank to add up the criteria above.")
                }
            }
            .navigationTitle(draft.isExisting ? "Edit rubric" : "New rubric")
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
                ToolbarItem(placement: .topBarLeading) {
                    if !draft.items.isEmpty { EditButton() }
                }
            }
        }
    }

    private struct CriterionRow: View {
        @Binding var row: RubricDraft.Row

        var body: some View {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                HStack(spacing: Tokens.Spacing.s) {
                    TextField("A", text: $row.code)
                        .frame(width: 44)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                    Divider().frame(height: 20)
                    TextField("What it marks", text: $row.name)
                    TextField("Marks", text: $row.marksText)
                        .keyboardType(.numberPad)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                }
                TextField("How it's marked (optional)", text: $row.guidance,
                          axis: .vertical)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .lineLimit(1...3)
            }
            .padding(.vertical, 2)
        }
    }
}
