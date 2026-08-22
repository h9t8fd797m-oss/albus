import SwiftUI
import SwiftData
import AlbusCore

/// Every piece of work, filtered and grouped by when it is due.
struct TasksScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlanCoordinator.self) private var coordinator

    @Query(sort: \Assignment.deadline) private var assignments: [Assignment]

    @State private var filter: Filter = .all
    @State private var addingTask = false

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

    /// Grouping is by deadline, and "done" is a filter rather than a group —
    /// a finished assignment still belongs to the week it was due in.
    private enum Group: String, CaseIterable {
        case overdue = "Overdue"
        case today = "Today"
        case thisWeek = "This week"
        case later = "Later"
        case done = "Done"
    }

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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 300)) { timeline in
            content(now: timeline.date)
        }
        .sheet(isPresented: $addingTask) {
            AddTaskSheet { title, type, deadline, minutes in
                Task {
                    await coordinator.addAssignment(
                        title: title, taskType: type, deadline: deadline,
                        estimatedMinutes: minutes, course: nil, context: context
                    )
                }
            }
        }
    }

    private func content(now: Date) -> some View {
        let visible = assignments.filter { matches($0, now: now) }
        let grouped = Dictionary(grouping: visible) { group(for: $0, now: now) }

        return ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header

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
                                        AssignmentCard(assignment: assignment, now: now) {
                                            toggleAll(assignment)
                                        }
                                    }
                                    .buttonStyle(.plain)
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("ALL WORK")
                    .font(Tokens.Typography.overline)
                    .tracking(Tokens.Tracking.overline)
                    .foregroundStyle(Tokens.Palette.inkMuted)
                Text("Tasks")
                    .font(Tokens.Typography.displayLarge)
                    .foregroundStyle(Tokens.Palette.ink)
            }
            Spacer()
            IconButton(systemImage: "plus", isFilled: true,
                       accessibilityLabel: "Add assignment") { addingTask = true }
        }
        .padding(.top, Tokens.Spacing.s)
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .all:
            EmptyState(icon: "tray", title: "No open work",
                       message: "Everything you have added is finished. Add the next thing when you are ready.",
                       actionTitle: "Add an assignment") { addingTask = true }
        case .dueSoon:
            EmptyState(icon: "calendar", title: "Nothing due this week",
                       message: "Your next deadline is further out. A good week to get ahead.")
        case .overdue:
            EmptyState(icon: "checkmark.circle", title: "Nothing overdue",
                       message: "You are on top of every deadline.")
        case .done:
            EmptyState(icon: "checkmark.seal", title: "Nothing finished yet",
                       message: "Completed assignments collect here.")
        }
    }

    /// The card-level checkbox completes or reopens the whole assignment.
    /// Per-step control lives in Task detail, where each step is visible.
    private func toggleAll(_ assignment: Assignment) {
        let target = !assignment.isComplete
        for subtask in assignment.subtasks {
            coordinator.setCompleted(subtask, target, context: context)
        }
    }
}

/// One assignment in the list.
private struct AssignmentCard: View {
    let assignment: Assignment
    let now: Date
    let onToggle: () -> Void

    private var subject: Tokens.SubjectColor {
        assignment.course?.subjectColor ?? .violet
    }

    var body: some View {
        SubjectStripeCard(subject: subject, padding: Tokens.Spacing.m + 2) {
            HStack(spacing: Tokens.Spacing.m + 2) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    CourseTag(code: assignment.course?.displayName ?? "General",
                              kind: assignment.taskType, subject: subject)

                    Text(assignment.title)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                        .strikethrough(assignment.isComplete)
                        .opacity(assignment.isComplete ? 0.55 : 1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !assignment.subtasks.isEmpty {
                        HStack(spacing: Tokens.Spacing.s + 2) {
                            ProgressBar(fraction: assignment.progress, tint: subject.color)
                            Text("\(Int(assignment.progress * 100))%")
                                .font(Tokens.Typography.mono)
                                .foregroundStyle(Tokens.Palette.inkMuted)
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                    }

                    DeadlineLabel(deadline: assignment.deadline, now: now)
                }

                Spacer(minLength: 0)
                CompletionToggle(isComplete: assignment.isComplete,
                                 tint: subject.color, action: onToggle)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(assignment.title)
    }
}
