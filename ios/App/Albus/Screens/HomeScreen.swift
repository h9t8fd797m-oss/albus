import SwiftUI
import SwiftData
import AlbusCore

/// Home: the work, not the work's parts.
///
/// This screen listed individual scheduled blocks, and a separate Tasks tab
/// listed the assignments those blocks belonged to — the same information twice,
/// with the less useful half given the more prominent slot. A student keeps
/// track of *assignments*; the steps are what they open an assignment to see.
///
/// So Home is the assignment list now, and the plan lives one tap in. The single
/// exception is the "up next" row: what to do *right now* is the one question a
/// planner must answer without navigation, and it names the assignment rather
/// than exposing the plan.
struct HomeScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionService.self) private var session
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(Preferences.self) private var preferences
    @Environment(EntitlementService.self) private var entitlements

    @Query(sort: \Assignment.deadline) private var assignments: [Assignment]
    @Query(sort: \PlanSessionRecord.startsAt) private var sessions: [PlanSessionRecord]

    @State private var filter: Filter = .all
    @State private var addingTask = false
    @State private var showingMonth = false
    @State private var showingPaywall = false
    @State private var focusing: PlanSessionRecord?

    enum Filter: String, CaseIterable, Identifiable {
        case all, dueSoon, overdue, done
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .dueSoon: "Due soon"
            case .overdue: "Overdue"
            case .done: "Done"
            }
        }
    }

    /// Grouping is by deadline; "done" is a filter rather than a group, because
    /// a finished assignment still belongs to the week it was due in.
    private enum Group: String, CaseIterable {
        case overdue = "Overdue"
        case today = "Due today"
        case thisWeek = "This week"
        case later = "Later"
        case done = "Done"
    }

    var body: some View {
        // Once a minute: the greeting, the countdown and "happening now" all go
        // stale on their own.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(now: timeline.date)
        }
        .sheet(isPresented: $addingTask) {
            AddTaskSheet { draft in
                Task {
                    await coordinator.addAssignment(draft, context: context,
                                                    availability: preferences.availability)
                }
            }
        }
        .sheet(isPresented: $showingPaywall) { PaywallScreen() }
        .fullScreenCover(item: $focusing) { record in
            FocusModeScreen(record: record)
        }
        // Catch up on anything missed since the app was last open. This is where
        // "it finds a new spot for what you skipped" actually happens.
        .task {
            coordinator.sweepMissedSessions(context: context,
                                            availability: preferences.availability)
        }
        .navigationDestination(isPresented: $showingMonth) {
            Screen { MonthCalendarScreen() }
        }
    }

    private func content(now: Date) -> some View {
        let visible = assignments.filter { matches($0, now: now) }
        let grouped = Dictionary(grouping: visible) { group(for: $0, now: now) }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header(now: now)
                status
                freeLimitNotice

                if let next = upNext(now: now) {
                    UpNextCard(record: next, now: now) { focusing = next }
                }

                WeekStrip(sessions: sessions, now: now) { showingMonth = true }

                FilterChipRow(filters: Filter.allCases, selection: $filter) { $0.title }
                    .padding(.horizontal, -Tokens.Spacing.xl)

                if visible.isEmpty {
                    emptyState
                } else {
                    ForEach(Group.allCases, id: \.self) { section in
                        if let items = grouped[section], !items.isEmpty {
                            SectionHeader(section.rawValue, count: items.count)
                                .padding(.top, Tokens.Spacing.xs)
                            VStack(spacing: Tokens.Spacing.s + 2) {
                                ForEach(items) { assignment in
                                    NavigationLink {
                                        Screen { TaskDetailScreen(assignment: assignment) }
                                    } label: {
                                        AssignmentCard(assignment: assignment, now: now)
                                    }
                                    .buttonStyle(.plain)
                                    // The up-next card shows the same title, so
                                    // "the element labelled <title>" is genuinely
                                    // ambiguous on this screen — and the two do
                                    // different things. A UI test that picks the
                                    // wrong one lands in Focus Mode and reports
                                    // that the plan is missing.
                                    .accessibilityIdentifier("assignmentCard")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Selection

    private func group(for assignment: Assignment, now: Date) -> Group {
        if assignment.isComplete { return .done }
        let cal = Calendar.current
        if assignment.deadline < now { return .overdue }
        if cal.isDateInToday(assignment.deadline) { return .today }
        if let week = cal.date(byAdding: .day, value: 7, to: now),
           assignment.deadline <= week { return .thisWeek }
        return .later
    }

    private func matches(_ assignment: Assignment, now: Date) -> Bool {
        switch filter {
        case .all: !assignment.isComplete
        case .dueSoon: !assignment.isComplete
            && assignment.deadline >= now
            && assignment.deadline <= (Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now)
        case .overdue: !assignment.isComplete && assignment.deadline < now
        case .done: assignment.isComplete
        }
    }

    /// The block happening now, or the next one due. Nil once everything is done.
    private func upNext(now: Date) -> PlanSessionRecord? {
        let live = sessions.filter { $0.subtask?.completedAt == nil }
        return live.first { $0.startsAt <= now && $0.endsAt > now }
            ?? live.first { $0.startsAt > now }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(Tokens.Typography.overline)
                    .tracking(Tokens.Tracking.dateline)
                    .textCase(.uppercase)
                    .foregroundStyle(Tokens.Palette.inkMuted)

                VStack(alignment: .leading, spacing: -2) {
                    Text(greeting(at: now) + ",")
                        .font(Tokens.Typography.displayLarge)
                        .tracking(Tokens.Tracking.display)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text(preferences.firstName.isEmpty ? "let's go" : preferences.firstName)
                        .font(.system(size: 30, weight: .regular))
                        .italic()
                        .tracking(Tokens.Tracking.display)
                        .foregroundStyle(Tokens.Palette.ink)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: Tokens.Spacing.s) {
                AlbusCactus(size: 36, mood: moodForToday())
                IconButton(systemImage: "plus", isFilled: true,
                           accessibilityLabel: "Add assignment") { addingTask = true }
            }
        }
        .padding(.top, Tokens.Spacing.s)
    }

    /// The cactus bristles as the day fills up.
    private func moodForToday() -> AlbusCactus.Mood {
        let minutes = sessions
            .filter { Calendar.current.isDateInToday($0.startsAt) && $0.subtask?.completedAt == nil }
            .reduce(0) { $0 + $1.plannedSeconds / 60 }
        return .forMinutes(minutes)
    }

    private func greeting(at now: Date) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 0..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    @ViewBuilder private var status: some View {
        if coordinator.status == .planning {
            StatusBanner(tone: .working, message: "Albus is planning…")
        }
        if case .failed(let message) = coordinator.status {
            StatusBanner(tone: .error, message: message)
        }
        if case .failed(let why) = session.state {
            StatusBanner(tone: .warning, message: "Not signed in: \(why)")
        }
    }

    /// Mirrors the server's free-tier cap. Guidance only — the database enforces
    /// it in the same transaction as the insert, so this being wrong costs a
    /// clearer message, never a bypassed limit.
    @ViewBuilder private var freeLimitNotice: some View {
        if !entitlements.isPlus && assignments.count(where: { !$0.isComplete }) >= 3 {
            StatusBanner(tone: .warning,
                         message: "Free plans cover three assignments at a time.",
                         retryTitle: "See Plus") { showingPaywall = true }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .all:
            EmptyState(icon: "tray", title: assignments.isEmpty ? "Nothing here yet" : "No open work",
                       message: assignments.isEmpty
                         ? "Add an assignment and Albus will break it into steps and find time for them."
                         : "Everything you have added is finished. Add the next thing when you're ready.",
                       actionTitle: "Add an assignment") { addingTask = true }
        case .dueSoon:
            EmptyState(icon: "calendar", title: "Nothing due this week",
                       message: "Your next deadline is further out. A good week to get ahead.")
        case .overdue:
            EmptyState(icon: "checkmark.circle", title: "Nothing overdue",
                       message: "You're on top of every deadline.")
        case .done:
            EmptyState(icon: "checkmark.seal", title: "Nothing finished yet",
                       message: "Completed assignments collect here.")
        }
    }
}

/// One assignment in the list.
///
/// No completion toggle. Ticking a whole assignment off from a list is how a
/// student banks six steps they did not do, and it is the same shortcut that
/// made the duration estimates worthless. Completion belongs where the steps
/// are visible.
private struct AssignmentCard: View {
    let assignment: Assignment
    let now: Date

    private var subject: Tokens.SubjectColor {
        assignment.course?.subjectColor ?? .violet
    }

    var body: some View {
        SubjectStripeCard(subject: subject, padding: Tokens.Spacing.m + 2) {
            HStack(spacing: Tokens.Spacing.m + 2) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    HStack(spacing: Tokens.Spacing.s) {
                        CourseTag(code: assignment.course?.displayName ?? "General",
                                  kind: assignment.taskType, subject: subject)
                        if assignment.priorityValue == .high, !assignment.isComplete {
                            PriorityFlag()
                        }
                    }

                    Text(assignment.title)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                        .strikethrough(assignment.isComplete)
                        .opacity(assignment.isComplete ? 0.55 : 1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if assignment.subtasks.isEmpty {
                        Text("No plan yet")
                            .font(Tokens.Typography.micro)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    } else {
                        HStack(spacing: Tokens.Spacing.s + 2) {
                            ProgressBar(fraction: assignment.progress, tint: subject.color)
                            Text("\(assignment.subtasks.count(where: { $0.completedAt != nil }))/\(assignment.subtasks.count)")
                                .font(Tokens.Typography.mono)
                                .foregroundStyle(Tokens.Palette.inkMuted)
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                    }

                    HStack(spacing: Tokens.Spacing.s) {
                        DeadlineLabel(deadline: assignment.deadline, now: now)
                        if assignment.rubric != nil {
                            MetaDot()
                            Label("Rubric", systemImage: "list.bullet.rectangle.portrait")
                                .labelStyle(.titleAndIcon)
                                .font(Tokens.Typography.micro)
                                .foregroundStyle(Tokens.Palette.inkMuted)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(assignment.title)
        .accessibilityHint("Opens the plan")
    }
}

private struct PriorityFlag: View {
    var body: some View {
        Label("High", systemImage: "exclamationmark")
            .labelStyle(.titleAndIcon)
            .font(Tokens.Typography.micro)
            .foregroundStyle(Tokens.Tint.orange.foreground)
            .padding(.horizontal, Tokens.Spacing.s)
            .padding(.vertical, 2)
            .background(Tokens.Tint.orange.background,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
    }
}
