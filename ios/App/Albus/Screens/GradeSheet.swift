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
                work: work, rubricID: rubric.id,
                assignmentID: assignment.remoteID, presentation: nil
            )

            let grading = Grading(
                remoteID: marked.id,
                model: marked.model,
                inputChars: work.trimmingCharacters(in: .whitespacesAndNewlines).count,
                overallMarks: marked.overallMarks,
                totalMarks: marked.totalMarks,
                criteria: marked.criteria.map {
                    GradedCriterion(code: $0.code, name: $0.name, marks: $0.marks,
                                    outOf: $0.outOf, comment: $0.comment,
                                    quote: $0.quote, whereFound: $0.whereFound)
                },
                feedback: marked.feedback,
                improvements: marked.improvements.map {
                    GradedImprovement(change: $0.change, why: $0.why)
                },
                basis: marked.basis,
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
                basisBanner
                score
                improvements

                if !grading.feedback.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        SectionHeader(grading.basis == .blind ? "Albus's read" : "Overall")
                        Text(grading.feedback)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.ink)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !grading.criteria.isEmpty {
                    SectionHeader(grading.basis == .blind ? "What stood out" : "Against the rubric",
                                  count: grading.criteria.count)
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

    /// What this was marked against, said before anything that looks like a mark.
    ///
    /// **The blind case is the reason this is the first thing on the screen.** A
    /// reading with no rubric behind it must never be mistaken for a grade, and
    /// a disclaimer underneath a big number is a disclaimer nobody reads.
    @ViewBuilder private var basisBanner: some View {
        switch grading.basis {
        case .blind:
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                AlbusCactus(size: 34, mood: .cooked)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Albus is grading blindly")
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text("There was no rubric for this, so Albus can only say what "
                         + "it thinks is strong or weak on its own reading. It has "
                         + "not awarded marks, and this may not reflect your real grade.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Tokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(alignment: .leading) {
                Rectangle().fill(Tokens.SubjectColor.amber.color).frame(width: 4)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
            }

        case .personal, .curriculum:
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Tokens.SubjectColor.green.color)
                Text(grading.basis == .personal
                     ? "Graded against your rubric"
                     : "Graded against your course's marking criteria")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
        }
    }

    @ViewBuilder private var improvements: some View {
        if !grading.improvements.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SectionHeader("What to change", count: grading.improvements.count)
                ForEach(Array(grading.improvements.enumerated()), id: \.offset) { index, move in
                    HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                        Text("\(index + 1)")
                            .font(Tokens.Typography.caption).fontWeight(.bold)
                            .foregroundStyle(Tokens.Palette.accent)
                            .frame(width: 22, height: 22)
                            .background(Tokens.Palette.accentWash, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(move.change)
                                .font(Tokens.Typography.cardTitle)
                                .foregroundStyle(Tokens.Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if !move.why.isEmpty {
                                Text(move.why)
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
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

                    // The student's own sentence, next to the mark it earned or
                    // cost. A criticism beside the line it is about reads as
                    // marking; the same criticism alone reads as invented.
                    if let quote = criterion.quote, !quote.isEmpty {
                        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                            Rectangle()
                                .fill(Tokens.Palette.accent.opacity(0.5))
                                .frame(width: 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(quote)
                                    .font(Tokens.Typography.caption)
                                    .italic()
                                    .foregroundStyle(Tokens.Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let source = criterion.whereFound, !source.isEmpty {
                                    Text(source)
                                        .font(Tokens.Typography.micro)
                                        .foregroundStyle(Tokens.Palette.inkMuted)
                                }
                            }
                        }
                        .padding(Tokens.Spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Palette.accentWash.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
