import SwiftUI
import SwiftData
import AlbusCore

/// The fourth tab, and the answer to two questions a student could not ask
/// before: *what am I on*, and *where do I change this*.
///
/// It replaced Ask Albus in the tab bar. That was the right trade in both
/// directions — a conversation belongs beside the work it is about, not in a
/// tab of its own, and every setting in the app was previously reachable only
/// by finding one small button on Home.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementService.self) private var entitlements
    @Environment(Preferences.self) private var preferences
    @Environment(SessionService.self) private var session
    @Query(sort: \Course.displayName) private var courses: [Course]

    @State private var showingPaywall = false
    @State private var examSession: ExamSession?
    @State private var targetPointsText = ""
    @State private var savedTargetPoints: Int?
    @State private var contextFailure: String?
    @State private var courseFailure: String?
    @State private var savingSession = false
    @State private var savingPoints = false
    @State private var savingCourseIDs: Set<UUID> = []

    var body: some View {
        @Bindable var preferences = preferences

        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                header
                planSection
                profileSection($preferences)
                if !courses.isEmpty { subjectsSection }
                notificationsSection
                aboutSection
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingPaywall) { PaywallScreen() }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("SETTINGS")
                .font(Tokens.Typography.overline)
                .tracking(Tokens.Tracking.overline)
                .foregroundStyle(Tokens.Palette.inkMuted)
            Text("Settings")
                .font(Tokens.Typography.displayLarge)
                .foregroundStyle(Tokens.Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Plan

    /// What they are on, what is left of it, and the way to change it.
    ///
    /// The meters read the same `my_plan()` call the gate enforces, so the
    /// number here cannot disagree with the number that refuses a request —
    /// which is exactly the bug migration 0033 existed to fix on one feature
    /// and this screen would otherwise reintroduce on four.
    private var planSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "Your plan") { EmptyView() }

            if entitlements.refreshFailed {
                EntitlementRefreshNotice()
            }

            GlassCard(isProminent: entitlements.isPaid) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entitlements.plan.displayName)
                            .font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer()
                        Text(entitlements.plan.priceLabel)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    }

                    if let renews = entitlements.plan.expiresAt, entitlements.isPaid {
                        Text("Renews \(renews.formatted(date: .abbreviated, time: .omitted))")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }

                    VStack(spacing: Tokens.Spacing.s) {
                        allowanceRow("Active tasks", entitlements.plan.tasks)
                        allowanceRow("Marking", entitlements.plan.grader, unit: "this week")
                        allowanceRow("Ask Albus", entitlements.plan.chat, unit: "this month")
                        allowanceRow("Saved rubrics", entitlements.plan.rubrics)
                    }

                    PrimaryButton(title: entitlements.isPaid ? "Change plan" : "See the plans") {
                        showingPaywall = true
                    }
                }
            }
        }
    }

    /// One metered line. Three states, because there are genuinely three:
    /// not on this plan, unlimited, or a number left.
    private func allowanceRow(_ label: String,
                              _ allowance: EntitlementService.Allowance,
                              unit: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text(label)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.ink)
            Spacer(minLength: Tokens.Spacing.m)

            // `isIncluded` before `remaining`, always. A limit of zero has a
            // remaining of zero, and rendering "0 left" to somebody who never
            // had any promises a Monday that is not coming.
            if !allowance.isIncluded {
                Text("Not included")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            } else if allowance.isUnlimited {
                Text("Unlimited")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            } else if let left = allowance.remaining, let limit = allowance.limit {
                Text("\(left) of \(limit) left\(unit.map { " \($0)" } ?? "")")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(left > 0 ? Tokens.Palette.inkSecondary
                                              : Tokens.Palette.danger)
            }
        }
    }

    // MARK: - Profile

    /// The answers onboarding asked for, editable afterwards.
    ///
    /// These were write-once until now: a student who picked the wrong exam
    /// board on their first launch had no way to correct it, and the board is
    /// what every curriculum lookup keys on.
    private func profileSection(_ preferences: Bindable<Preferences>) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "You") { EmptyView() }

            GlassCard {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    SheetField(label: "Name") {
                        TextField("Your name", text: preferences.name)
                            .textInputAutocapitalization(.words)
                            .foregroundStyle(Tokens.Palette.ink)
                    }

                    // One programme is not a question, so the control hides
                    // itself rather than presenting a list of length one.
                    if Preferences.Program.offered.count > 1 {
                        SheetPicker(
                            label: "Programme",
                            options: Preferences.Program.offered.map { (value: $0, title: $0.rawValue) },
                            selection: preferences.program)
                    }

                    // Only A-level has more than one authority, and a picker
                    // with one option is not a choice.
                    if preferences.wrappedValue.availableBoards.count > 1 {
                        SheetPicker(
                            label: "Exam board",
                            options: preferences.wrappedValue.availableBoards.map { (value: $0, title: $0) },
                            selection: preferences.examBoard)
                    }

                    SheetPicker(
                        label: "Examination session",
                        options: examinationSessionOptions,
                        selection: examinationSessionBinding
                    )
                    .disabled(savingSession)

                    SheetField(label: "Target points · optional") {
                        HStack(spacing: Tokens.Spacing.s) {
                            TextField("Out of 45", text: $targetPointsText)
                                .keyboardType(.numberPad)
                                .foregroundStyle(Tokens.Palette.ink)

                            if savedTargetPoints != nil {
                                Button("Clear") { clearTargetPoints() }
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.inkMuted)
                                    .buttonStyle(.plain)
                                    .disabled(savingPoints)
                            }

                            Button("Save") { saveTargetPoints() }
                                .font(Tokens.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(Tokens.Palette.accent)
                                .buttonStyle(.plain)
                                .disabled(!canSaveTargetPoints || savingPoints)
                        }
                    }

                    if !TargetPointsInput.isValidOrEmpty(targetPointsText) {
                        Text("Target points must be from 1 to 45.")
                            .font(Tokens.Typography.micro)
                            .foregroundStyle(Tokens.Palette.danger)
                    }

                    SheetPicker(
                        label: "Work in a day",
                        options: Preferences.StudyLoad.allCases.map { (value: $0, title: $0.title) },
                        selection: preferences.load)

                    if let contextFailure {
                        Text(contextFailure)
                            .font(Tokens.Typography.micro)
                            .foregroundStyle(Tokens.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Subjects

    private var subjectsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "Your subjects") { EmptyView() }

            GlassCard {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    ForEach(Array(courses.enumerated()), id: \.element.id) { index, course in
                        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(course.displayName)
                                        .font(Tokens.Typography.body)
                                        .foregroundStyle(Tokens.Palette.ink)
                                    if let curriculum = course.curriculum {
                                        Text(curriculum.qualification.title)
                                            .font(Tokens.Typography.micro)
                                            .foregroundStyle(Tokens.Palette.inkMuted)
                                    }
                                }
                                Spacer(minLength: Tokens.Spacing.s)
                                if !CourseLevel.applies(to: course.curriculumSubjectCode) {
                                    Text("No HL / SL")
                                        .font(Tokens.Typography.caption)
                                        .foregroundStyle(Tokens.Palette.inkMuted)
                                }
                            }

                            if CourseLevel.applies(to: course.curriculumSubjectCode) {
                                CourseLevelSelector(
                                    selection: courseLevelBinding(course),
                                    accessibilityPrefix: "settingsLevel.\(course.id.uuidString)"
                                )
                                    .disabled(savingCourseIDs.contains(course.id))
                            }
                        }

                        if index < courses.count - 1 {
                            Divider().overlay(Tokens.Palette.hairline)
                        }
                    }

                    if let courseFailure {
                        Text(courseFailure)
                            .font(Tokens.Typography.micro)
                            .foregroundStyle(Tokens.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - IB context

    private var examinationSessionOptions: [(value: ExamSession?, title: String)] {
        var sessions = ExamSession.editableSessions()
        if let examSession, !sessions.contains(examSession) {
            sessions.append(examSession)
            sessions.sort { $0.rawValue < $1.rawValue }
        }

        var options: [(value: ExamSession?, title: String)] = sessions.map {
            (value: Optional($0), title: $0.title)
        }
        if examSession == nil {
            options.insert((value: nil, title: "Choose a session…"), at: 0)
        }
        return options
    }

    private var examinationSessionBinding: Binding<ExamSession?> {
        Binding(
            get: { examSession },
            set: { selected in
                guard let selected, selected != examSession else { return }
                let previous = examSession
                examSession = selected
                savingSession = true
                contextFailure = nil

                Task {
                    let saved = await ProfileService().setIBContext(examSession: selected)
                    savingSession = false
                    guard !saved else { return }
                    examSession = previous
                    contextFailure = "That examination session did not save. Try again."
                }
            }
        )
    }

    private var canSaveTargetPoints: Bool {
        guard let value = TargetPointsInput.value(from: targetPointsText) else { return false }
        return value != savedTargetPoints
    }

    private func refresh() async {
        async let plan: Void = entitlements.refresh()
        async let context: Void = loadIBContext()
        _ = await (plan, context)
    }

    private func loadIBContext() async {
        guard let snapshot = await ProfileService().ibContext() else {
            if case .signedIn = session.state {
                contextFailure = "Albus couldn't load your IB details. Pull to try again."
            }
            return
        }

        examSession = snapshot.examSession
        savedTargetPoints = snapshot.targetPoints
        targetPointsText = snapshot.targetPoints.map(String.init) ?? ""
        contextFailure = nil
    }

    private func saveTargetPoints() {
        guard let value = TargetPointsInput.value(from: targetPointsText) else { return }
        let previous = savedTargetPoints
        savingPoints = true
        contextFailure = nil

        Task {
            let saved = await ProfileService().setIBContext(targetPoints: value)
            savingPoints = false
            if saved {
                savedTargetPoints = value
            } else {
                savedTargetPoints = previous
                targetPointsText = previous.map(String.init) ?? ""
                contextFailure = "Those target points did not save. Try again."
            }
        }
    }

    private func clearTargetPoints() {
        let previous = savedTargetPoints
        savingPoints = true
        contextFailure = nil

        Task {
            let saved = await ProfileService().setIBContext(clearTargetPoints: true)
            savingPoints = false
            if saved {
                savedTargetPoints = nil
                targetPointsText = ""
            } else {
                savedTargetPoints = previous
                targetPointsText = previous.map(String.init) ?? ""
                contextFailure = "Those target points did not clear. Try again."
            }
        }
    }

    private func courseLevelBinding(_ course: Course) -> Binding<CourseLevel?> {
        Binding(
            get: { course.level },
            set: { setLevel($0, for: course) }
        )
    }

    private func setLevel(_ level: CourseLevel?, for course: Course) {
        let previous = course.level
        guard previous != level else { return }
        guard let remoteID = course.remoteID else {
            courseFailure = "The level for \(course.displayName) could not save because that subject is not synced."
            return
        }

        course.level = level
        do {
            try modelContext.save()
        } catch {
            course.level = previous
            courseFailure = "The level for \(course.displayName) could not save on this device."
            return
        }

        savingCourseIDs.insert(course.id)
        courseFailure = nil
        Task {
            let saved = await ProfileService().updateCourse(
                remoteID: remoteID,
                level: level,
                clearLevel: level == nil
            )
            savingCourseIDs.remove(course.id)
            guard !saved else { return }

            course.level = previous
            try? modelContext.save()
            courseFailure = "The level for \(course.displayName) did not save. Try again."
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "Notifications") { EmptyView() }
            NavigationLink { Screen { NotificationSettingsScreen() } } label: {
                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("When Albus speaks")
                                .font(Tokens.Typography.body)
                                .foregroundStyle(Tokens.Palette.ink)
                            Text("Quiet hours, deadline warnings, the morning brief")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Tokens.Spacing.m)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "About") { EmptyView() }
            GlassCard {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    aboutRow("Version", Self.version)
                    aboutRow("Account", accountLabel)
                }
            }
        }
    }

    private func aboutRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.ink)
            Spacer(minLength: Tokens.Spacing.m)
            Text(value)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
    }

    /// Never the user id. It identifies nothing to the student and is the one
    /// string on this screen worth not putting on a shared screenshot.
    private var accountLabel: String {
        if case .signedIn = session.state { return "Signed in" }
        return "Not signed in"
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
