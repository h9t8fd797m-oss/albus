import SwiftUI
import SwiftData
import PhotosUI
import AlbusCore

/// Albus Grader — the first-party tool.
///
/// Four questions, in the order a student can answer them:
///   1. What am I marking?      — an assignment, a file, photos, or pasted text
///   2. What against?           — a saved rubric, one you upload, or nothing
///   3. How do you want it?     — the scale their course actually uses
///   4. …then mark it.
///
/// **Step 2 and 3 are what make a real grade possible.** Albus has no way to
/// know whether a course marks out of 100, in IB 1–7, or in letter bands — so
/// rather than inventing a scale, the student says. And rather than refusing to
/// mark work with no rubric on file, they can hand one over, or accept a blind
/// reading that is clearly labelled as not a grade.
struct GraderScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Assignment.deadline) private var assignments: [Assignment]
    @Query(sort: \Rubric.updatedAt, order: .reverse) private var rubrics: [Rubric]

    /// Where the student is in the flow. One value, so back always means back.
    private enum Stage: Equatable {
        case start, work, rubric, presentation, marking, result
    }

    @State private var stage: Stage = .start
    @State private var allowance: GradingService.Allowance?

    // What is being marked.
    @State private var chosenAssignment: Assignment?
    @State private var work = ""
    @State private var sourceLabel: String?
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var workPhotoPicking = false
    @State private var extracting = false
    @State private var extractionFailure: String?

    // What it is marked against.
    @State private var chosenRubric: Rubric?
    @State private var acceptedBlind = false
    @State private var editingRubric: RubricDraft?
    @State private var rubricPhotoPicking = false
    @State private var rubricPhoto: PhotosPickerItem?
    @State private var syncFailure: String?

    // How the student wants it back.
    @State private var presentation = ""

    @State private var failure: GradingService.Failure?
    @State private var result: Grading?
    @State private var showingPaywall = false

    private var wordCount: Int {
        work.split(whereSeparator: \.isWhitespace).count
    }

    /// Blind is the absence of a rubric, however the student got here — they
    /// picked none, or the assignment they chose has none on file.
    private var isBlind: Bool {
        chosenRubric == nil && (chosenAssignment?.rubric == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                switch stage {
                case .start:        startStage
                case .work:         workStage
                case .rubric:       rubricStage
                case .presentation: presentationStage
                case .marking:      markingStage
                case .result:       resultStage
                }
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Albus Grader")
        .navigationBarTitleDisplayMode(.inline)
        .task { allowance = await GradingService().allowance() }
        .sheet(isPresented: $showingPaywall) { PaywallScreen() }
        .sheet(item: $editingRubric) { draft in
            RubricEditorSheet(draft: draft) { saved in
                RubricWriter.commit(saved, context: context) { syncFailure = $0 }
                // Select what was just written, so the student does not have to
                // find it in a list they were not looking at.
                chosenRubric = rubrics.first { $0.id == saved.id }
                acceptedBlind = false
            }
        }
        .photosPicker(isPresented: $workPhotoPicking, selection: $photo, matching: .images)
        .photosPicker(isPresented: $rubricPhotoPicking, selection: $rubricPhoto, matching: .images)
        .onChange(of: rubricPhoto) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let text = try? await WorkExtractor.text(from: .image(image))
                else {
                    syncFailure = "Albus couldn't read that rubric — try a clearer photo."
                    return
                }
                // Straight into the editor rather than saved silently: OCR of a
                // photographed handout is worth a glance before it becomes the
                // thing a grade is based on.
                var draft = RubricDraft.empty
                draft.body = String(text.prefix(Rubric.maxBodyCharacters))
                draft.name = "Photographed rubric"
                editingRubric = draft
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.pdf, .plainText, .rtf, .text],
                      allowsMultipleSelection: false) { outcome in
            guard case .success(let urls) = outcome, let url = urls.first else { return }
            extract(.file(url), label: url.lastPathComponent)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                extract(.image(image), label: "Photo of your work")
            }
        }
    }

    // MARK: - 0 · Start

    @ViewBuilder private var startStage: some View {
        card(rail: Tokens.Palette.accent) {
            HStack {
                modelBadge
                Spacer()
                meter
            }
            Text("A grading reads every paragraph and marks it against your "
                 + "rubric, quoting your own sentences back to you.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }

        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "How it works") { EmptyView() }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                    Text("\(index + 1)")
                        .font(Tokens.Typography.caption).fontWeight(.bold)
                        .foregroundStyle(Tokens.Palette.accent)
                        .frame(width: 22, height: 22)
                        .background(Tokens.Palette.accentWash, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.0).font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text(step.1).font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if allowance?.hasAny == false {
            outOfGradings
        } else {
            PrimaryButton(title: "Grade a piece of work") { stage = .work }
        }
    }

    private var steps: [(String, String)] {
        [("Give me the work", "Pick a task, upload a file, photograph it, or paste it."),
         ("Say what marks it", "A rubric you've saved, or one you hand me now."),
         ("Tell me how you're marked", "Out of 100, IB 1–7, letters — whatever your course uses."),
         ("Get the marks back", "Where they went, quoted from your own writing.")]
    }

    // MARK: - 1 · The work

    @ViewBuilder private var workStage: some View {
        stageTitle("What am I marking?",
                   "Anything on your list brings its rubric and deadline with it.")

        if !openAssignments.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SectionHeader(label: "Your work") { EmptyView() }
                ForEach(openAssignments) { assignment in
                    Button { choose(assignment) } label: {
                        assignmentRow(assignment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(label: "Or bring it in") { EmptyView() }
            importRow("Upload a file", "PDF or plain text", "arrow.up.doc") { importing = true }
            importRow("Take a photo", "Handwriting is fine", "camera") {
                workPhotoPicking = true
            }
        }

        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(label: "Or paste it") { EmptyView() }
            TextEditor(text: $work)
                .font(Tokens.Typography.body)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(Tokens.Spacing.m)
                .background(Tokens.Palette.cardSurface,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                }
        }

        if extracting {
            StatusBanner(tone: .working, message: "Reading it…")
        }
        if let extractionFailure {
            StatusBanner(tone: .warning, message: extractionFailure)
        }
        if let sourceLabel, !work.isEmpty {
            AlbusNote("Read **\(sourceLabel)** — \(wordCount) words.", isBusy: true)
        }

        PrimaryButton(title: "Continue", isEnabled: wordCount > 30) { stage = .rubric }
    }

    private var openAssignments: [Assignment] {
        assignments.filter { $0.statusValue == .active }.prefix(6).map { $0 }
    }

    // MARK: - 2 · The rubric

    @ViewBuilder private var rubricStage: some View {
        stageTitle("What should I mark it against?",
                   "A rubric is the difference between a grade and an opinion.")

        if !rubrics.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SectionHeader(label: "Saved rubrics") { EmptyView() }
                ForEach(rubrics.prefix(6)) { rubric in
                    Button {
                        chosenRubric = rubric
                        acceptedBlind = false
                    } label: {
                        selectableRow(title: rubric.name,
                                      detail: rubric.source,
                                      selected: chosenRubric?.id == rubric.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(label: "Or add one") { EmptyView() }
            // The same editor and the same writer the Rubrics tab uses, so a
            // rubric added here is a real saved rubric rather than a one-off
            // that vanishes after marking.
            importRow("Type or paste a rubric", "Saved for next time", "doc.text") {
                editingRubric = .empty
            }
            importRow("Photograph a rubric", "From a handout or the board", "camera.viewfinder") {
                rubricPhotoPicking = true
            }
        }

        // Blind is offered, never defaulted into silently.
        Button { acceptedBlind = true; chosenRubric = nil } label: {
            blindOption
        }
        .buttonStyle(.plain)

        PrimaryButton(title: "Continue",
                      isEnabled: chosenRubric != nil || acceptedBlind
                                 || chosenAssignment?.rubric != nil) {
            stage = .presentation
        }
    }

    private var blindOption: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                AlbusCactus(size: 26, mood: .cooked)
                Text("I don't have a rubric")
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Spacer()
                if acceptedBlind {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.Palette.accent)
                }
            }
            Text("Albus will read it and say what looks strong or weak — but it "
                 + "won't be a grade, and it won't award marks.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(acceptedBlind ? Tokens.Palette.accent : Tokens.Palette.hairline,
                              lineWidth: acceptedBlind ? 1.5 : 0.5)
        }
    }

    // MARK: - 3 · How they are marked

    @ViewBuilder private var presentationStage: some View {
        stageTitle("How does your course mark this?",
                   "Albus can't know your scale. Tell it, and the result comes "
                   + "back in the form you'll actually be graded in.")

        TextEditor(text: $presentation)
            .font(Tokens.Typography.body)
            .frame(minHeight: 110)
            .scrollContentBackground(.hidden)
            .padding(Tokens.Spacing.m)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
            }

        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(label: "For example") { EmptyView() }
            ForEach(presentationExamples, id: \.self) { example in
                Button { presentation = example } label: {
                    Text(example)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.accent)
                        .padding(.horizontal, Tokens.Spacing.m)
                        .padding(.vertical, Tokens.Spacing.s)
                        .background(Tokens.Palette.accentWash, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }

        if isBlind && !presentation.isEmpty {
            StatusBanner(tone: .warning,
                         message: "With no rubric, Albus still won't give a mark — "
                                + "whatever scale you ask for.")
        }

        PrimaryButton(title: "Mark my work") { Task { await submit() } }
    }

    private var presentationExamples: [String] {
        ["Out of 100, with a letter grade",
         "IB 1–7, with the criterion bands",
         "Percentage, and how far off the next grade I am",
         "No marks — just tell me what's weak"]
    }

    // MARK: - 4 · Marking

    @ViewBuilder private var markingStage: some View {
        VStack(spacing: Tokens.Spacing.l) {
            AlbusCactus(size: 74, mood: .busy)
            Text(isBlind ? "Reading your work." : "Marking against your rubric.")
                .font(Tokens.Typography.cardTitle)
                .foregroundStyle(Tokens.Palette.ink)
            Text("\(wordCount) words. About half a minute.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            ProgressView().tint(Tokens.Palette.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Tokens.Spacing.xxl)
    }

    // MARK: - 5 · Result

    @ViewBuilder private var resultStage: some View {
        if let result {
            GradeResultView(grading: result)
        }
        if let failure {
            StatusBanner(tone: .error, message: failure.errorDescription ?? "Marking failed.")
            PrimaryButton(title: "Try again") { stage = .presentation }
        }
    }

    // MARK: - Pieces

    private var modelBadge: some View {
        HStack(spacing: 5) {
            Circle().frame(width: 4, height: 4)
            Text(isBlind ? "Sonnet 5" : "Opus 5")
                .font(Tokens.Typography.overline).fontWeight(.bold)
        }
        .foregroundStyle(Tokens.Palette.accent)
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, 3)
        .background(Tokens.Palette.accentWash, in: Capsule())
    }

    @ViewBuilder private var meter: some View {
        if let allowance {
            if let left = allowance.weeklyRemaining {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(0..<allowance.limitWeek, id: \.self) { index in
                            Capsule()
                                .fill(index < left ? Tokens.Palette.accent
                                                   : Tokens.Palette.hairline)
                                .frame(width: 14, height: 4)
                        }
                    }
                    Text("\(left) left this week")
                        .font(Tokens.Typography.overline)
                        .foregroundStyle(left > 0 ? Tokens.Palette.inkSecondary
                                                  : Tokens.Palette.danger)
                }
            } else {
                Text("Unlimited")
                    .font(Tokens.Typography.overline)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
        }
    }

    private var outOfGradings: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            AlbusCactus(size: 56, mood: .cooked)
            Text("That's this week's markings used.")
                .font(Tokens.Typography.cardTitle)
                .foregroundStyle(Tokens.Palette.ink)
            Text("They come back as the week rolls on. Albus Plus raises the limit.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            PrimaryButton(title: "See Plus") { showingPaywall = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.l)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    private func stageTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(title)
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func assignmentRow(_ assignment: Assignment) -> some View {
        selectableRow(
            title: assignment.title,
            detail: assignment.rubric != nil ? "Rubric on file" : "No rubric saved",
            selected: chosenAssignment?.id == assignment.id
        )
    }

    private func selectableRow(title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                    .lineLimit(1)
                Text(detail).font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Tokens.Palette.accent : Tokens.Palette.hairline)
        }
        .padding(Tokens.Spacing.l)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(selected ? Tokens.Palette.accent : Tokens.Palette.hairline,
                              lineWidth: selected ? 1.5 : 0.5)
        }
    }

    private func importRow(_ title: String, _ detail: String, _ icon: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { importRowLabel(title, detail, icon) }
            .buttonStyle(.plain)
    }

    private func importRowLabel(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: icon)
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: 32, height: 32)
                .background(Tokens.Palette.accentWash,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text(detail).font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
        .padding(Tokens.Spacing.l)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
        }
    }

    private func card(rail: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Spacing.l)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(alignment: .leading) {
                Rectangle().fill(rail).frame(width: 4)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
            }
    }

    // MARK: - Actions

    private func choose(_ assignment: Assignment) {
        chosenAssignment = assignment
        chosenRubric = assignment.rubric
        sourceLabel = assignment.title
    }

    private func extract(_ source: WorkExtractor.Source, label: String) {
        extracting = true
        extractionFailure = nil
        Task {
            do {
                work = try await WorkExtractor.text(from: source)
                sourceLabel = label
            } catch {
                extractionFailure = (error as? WorkExtractor.Failure)?.errorDescription
                    ?? "Albus couldn't read that."
            }
            extracting = false
        }
    }

    private func submit() async {
        stage = .marking
        failure = nil

        do {
            let marked = try await GradingService().grade(
                work: work,
                rubricID: chosenRubric?.remoteID,
                assignmentID: chosenAssignment?.remoteID,
                presentation: presentation
            )

            let grading = Grading(
                remoteID: marked.id,
                model: marked.model,
                inputChars: work.count,
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
                assignment: chosenAssignment
            )
            context.insert(grading)
            try? context.save()

            // Dropped once stored: the work has been marked, and holding an
            // essay in memory behind a visible result serves nobody.
            work = ""
            result = grading
            allowance = await GradingService().allowance()
            stage = .result

        } catch let error as GradingService.Failure {
            failure = error
            if error == .needsPlus { showingPaywall = true }
            stage = .result
        } catch {
            failure = .unavailable
            stage = .result
        }
    }
}
