import SwiftUI
import SwiftData
import AlbusCore

/// Marking finished work against the rubric it will actually be marked against.
///
/// Paste, not upload: it is the smallest thing that works, it needs no file
/// permissions, and it is honest about what is being sent. Photos and documents
/// are meaningfully more machinery and meaningfully more attack surface, and
/// neither is needed to answer "is this any good yet".
struct GradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(EntitlementService.self) private var entitlements

    let assignment: Assignment

    @Query(sort: \Rubric.updatedAt, order: .reverse) private var rubrics: [Rubric]

    @State private var work = ""
    @State private var rubricID: UUID?
    @State private var isMarking = false
    @State private var failure: GradingService.Failure?
    @State private var result: Grading?
    @State private var showingPaywall = false

    private var rubric: Rubric? {
        rubrics.first { $0.id == rubricID } ?? assignment.rubric
    }

    private var characters: Int {
        work.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var canSubmit: Bool {
        rubric != nil
            && characters >= GradingService.minWorkCharacters
            && characters <= GradingService.maxWorkCharacters
            && !isMarking
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    GradeResultView(grading: result)
                } else {
                    form
                }
            }
            .navigationTitle(result == nil ? "Mark my work" : "Marked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Mark it") { Task { await submit() } }
                            .disabled(!canSubmit)
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) { PaywallScreen() }
        }
        .interactiveDismissDisabled(isMarking)
        .onAppear { rubricID = assignment.rubric?.id ?? rubrics.first?.id }
    }

    private var form: some View {
        Form {
            if rubrics.isEmpty {
                Section {
                    Text("Save a rubric first — marking needs something to mark against.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                }
            } else {
                Section {
                    Picker("Rubric", selection: $rubricID) {
                        ForEach(rubrics) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                } header: {
                    Text("Marked against")
                } footer: {
                    if let rubric { Text(rubric.summary) }
                }
            }

            Section {
                TextEditor(text: $work)
                    .frame(minHeight: 220)
                    .font(Tokens.Typography.body)
                    .disabled(isMarking)
            } header: {
                Text("Your work")
            } footer: {
                Text(lengthNote)
            }

            if let failure, failure != .needsPlus {
                Section {
                    StatusBanner(tone: .error,
                                 message: failure.errorDescription ?? "Marking failed.")
                }
            }

            if isMarking {
                Section {
                    HStack(spacing: Tokens.Spacing.m) {
                        ProgressView()
                        Text("Albus is reading it properly. This takes a moment.")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    }
                }
            }

            Section {
                Text("Albus sends this text to be marked and keeps only the marks and the feedback. Your work isn't stored.")
                    .font(Tokens.Typography.micro)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
        }
    }

    private var lengthNote: String {
        if characters == 0 {
            return "Paste the finished piece. Albus marks what's here, not a summary of it."
        }
        if characters < GradingService.minWorkCharacters {
            return "\(characters) characters — there isn't enough here to mark yet."
        }
        if characters > GradingService.maxWorkCharacters {
            return "About \(characters / 6) words. That's longer than Albus can mark in one go."
        }
        return "About \(characters / 6) words."
    }

    private func submit() async {
        guard let rubric else { return }
        isMarking = true
        failure = nil

        do {
            let marked = try await GradingService().grade(
                work: work, rubricID: rubric.id, assignmentID: assignment.remoteID
            )

            let grading = Grading(
                remoteID: marked.id,
                model: marked.model,
                inputChars: work.trimmingCharacters(in: .whitespacesAndNewlines).count,
                overallMarks: marked.overallMarks,
                totalMarks: marked.totalMarks,
                criteria: marked.criteria.map {
                    GradedCriterion(code: $0.code, name: $0.name, marks: $0.marks,
                                    outOf: $0.outOf, comment: $0.comment)
                },
                feedback: marked.feedback,
                assignment: assignment
            )
            context.insert(grading)
            try? context.save()

            // Dropped deliberately once the result is stored: the work has been
            // marked, and holding the essay in memory behind a visible result
            // serves nobody.
            work = ""
            result = grading

        } catch let error as GradingService.Failure {
            failure = error
            // A paywall is not an error. The student did nothing wrong; they
            // asked for something they have not paid for.
            if error == .needsPlus { showingPaywall = true }
        } catch {
            failure = .unavailable
        }

        isMarking = false
    }
}

/// What came back.
struct GradeResultView: View {
    let grading: Grading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                score
                if !grading.feedback.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        SectionHeader("What to change")
                        Text(grading.feedback)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.ink)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !grading.criteria.isEmpty {
                    SectionHeader("Against the rubric", count: grading.criteria.count)
                    VStack(spacing: Tokens.Spacing.s) {
                        ForEach(grading.criteria) { criterion in
                            CriterionCard(criterion: criterion)
                        }
                    }
                }

                Text("Marked by \(grading.model) · about \(grading.approximateWords) words")
                    .font(Tokens.Typography.micro)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
            .padding(Tokens.Spacing.xl)
        }
        .background(BackgroundGradient())
    }

    @ViewBuilder private var score: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                if let text = grading.scoreText {
                    Text(text)
                        .font(Tokens.Typography.displayLarge)
                        .foregroundStyle(Tokens.Palette.ink)
                    if let fraction = grading.fraction {
                        ProgressBar(fraction: fraction, tint: Tokens.Palette.accent, height: 6)
                    }
                } else {
                    // A rubric with no marks is a real case, and rendering it as
                    // "0" would be a lie about the work.
                    Text("Marked")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text("This rubric doesn't carry marks, so Albus commented instead of scoring.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct CriterionCard: View {
        let criterion: GradedCriterion

        var body: some View {
            GlassCard(padding: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(criterion.displayName)
                            .font(Tokens.Typography.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer()
                        if let score = criterion.scoreText {
                            Text(score)
                                .font(Tokens.Typography.mono)
                                .foregroundStyle(Tokens.Palette.accent)
                        }
                    }
                    if !criterion.comment.isEmpty {
                        Text(criterion.comment)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
