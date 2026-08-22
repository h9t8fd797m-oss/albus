import SwiftUI
import SwiftData
import AlbusCore

/// Today: what is happening now, what is next, and how the day is going.
///
/// Assembled from `Components/` — this file positions and feeds them, and
/// contains no colours, radii or card recipes of its own.
struct TodayScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionService.self) private var session
    @Environment(PlanCoordinator.self) private var coordinator

    @Query(sort: \PlanSessionRecord.startsAt) private var sessions: [PlanSessionRecord]

    @State private var addingTask = false
    @State private var showingMonth = false

    /// O(n) over a day's sessions — small enough that caching it would cost
    /// more in invalidation bugs than it saves.
    private var today: [PlanSessionRecord] {
        sessions.filter { Calendar.current.isDateInToday($0.startsAt) }
    }

    private var completedToday: Int {
        today.filter { $0.subtask?.completedAt != nil }.count
    }

    private var studiedMinutes: Int {
        today
            .filter { $0.subtask?.completedAt != nil }
            .reduce(0) { $0 + Int($1.endsAt.timeIntervalSince($1.startsAt) / 60) }
    }

    /// The session in progress, if any. Resolved against a single `now` so two
    /// rows can never both claim to be current.
    private func currentSession(at now: Date) -> PlanSessionRecord? {
        today.first { $0.startsAt <= now && $0.endsAt > now && $0.subtask?.completedAt == nil }
    }

    var body: some View {
        // Re-renders once a minute so "happening now" and the greeting stay
        // true without the screen having to be revisited.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
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
        .navigationDestination(isPresented: $showingMonth) {
            Screen { MonthCalendarScreen() }
        }
    }

    private func content(now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header(now: now)
                status
                FocusCard(done: completedToday, total: today.count,
                          studiedMinutes: studiedMinutes,
                          next: nextSessionLabel(now: now))
                WeekStrip(sessions: sessions, now: now) { showingMonth = true }
                schedule(now: now)
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.l) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(Tokens.Typography.overline)
                    .tracking(Tokens.Tracking.overline)
                    .textCase(.uppercase)
                    .foregroundStyle(Tokens.Palette.inkMuted)
                Text(greeting(at: now))
                    .font(Tokens.Typography.displayLarge)
                    .foregroundStyle(Tokens.Palette.ink)
            }
            Spacer(minLength: 0)
            IconButton(systemImage: "plus", isFilled: true,
                       accessibilityLabel: "Add assignment") { addingTask = true }
        }
        .padding(.top, Tokens.Spacing.s)
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

    private func nextSessionLabel(now: Date) -> String? {
        guard let next = today.first(where: { $0.startsAt > now }) else { return nil }
        return next.startsAt.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Schedule

    @ViewBuilder private func schedule(now: Date) -> some View {
        let current = currentSession(at: now)

        SectionHeader(label: "Today's schedule", count: today.isEmpty ? nil : today.count) {
            if !today.isEmpty {
                Text(DurationText.short(minutes: today.reduce(0) {
                    $0 + Int($1.endsAt.timeIntervalSince($1.startsAt) / 60)
                }))
                .font(Tokens.Typography.mono)
                .foregroundStyle(Tokens.Palette.inkMuted)
            }
        }
        .padding(.top, Tokens.Spacing.xs)

        if today.isEmpty {
            emptySchedule
        } else {
            VStack(spacing: Tokens.Spacing.s + 2) {
                ForEach(today) { record in
                    SessionCard(
                        record: record,
                        isNow: record.id == current?.id,
                        onToggle: {
                            guard let subtask = record.subtask else { return }
                            coordinator.setCompleted(
                                subtask, subtask.completedAt == nil, context: context
                            )
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder private var emptySchedule: some View {
        if sessions.isEmpty {
            EmptyState(
                icon: "calendar",
                title: "Nothing planned yet",
                message: "Add an assignment and Albus will break it into steps and find time for them.",
                actionTitle: "Add an assignment"
            ) { addingTask = true }
        } else {
            EmptyState(icon: "checkmark.circle", title: "Nothing today",
                       message: nextUpMessage)
        }
    }

    private var nextUpMessage: String {
        guard let next = sessions.first(where: { $0.startsAt > .now }) else {
            return "Every step is placed. Enjoy the quiet."
        }
        return "Your next session is \(next.startsAt.formatted(.dateTime.weekday().hour().minute()))."
    }

}

// MARK: - Today-only pieces
//
// These compose the shared components but are specific to Today, so they live
// beside it rather than in Components/ where they would be dead weight for
// every other screen.

/// "Two down, four to go" — the day at a glance.
private struct FocusCard: View {
    let done: Int
    let total: Int
    let studiedMinutes: Int
    let next: String?

    private var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        GlassCard {
            HStack(spacing: Tokens.Spacing.l) {
                ProgressRing(fraction: fraction, label: "\(done)/\(total)")

                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(headline)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text(detail)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if total > 0 {
                        HStack(spacing: Tokens.Spacing.xs + 2) {
                            ForEach(0..<total, id: \.self) { i in
                                Capsule()
                                    .fill(i < done ? Tokens.Palette.accent
                                          : Tokens.Palette.ink.opacity(0.10))
                                    .frame(height: 4)
                            }
                        }
                        .padding(.top, Tokens.Spacing.xs)
                        .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var headline: String {
        guard total > 0 else { return "Nothing scheduled" }
        if done == 0 { return "\(total) block\(total == 1 ? "" : "s") to go" }
        if done == total { return "Day complete" }
        return "\(done) down, \(total - done) to go"
    }

    private var detail: String {
        var parts: [String] = []
        if studiedMinutes > 0 { parts.append("\(DurationText.short(minutes: studiedMinutes)) studied") }
        if let next { parts.append("next block at \(next)") }
        return parts.isEmpty ? "Add an assignment to fill the day." : parts.joined(separator: " · ")
    }
}

/// The week, with a dot per scheduled session.
private struct WeekStrip: View {
    let sessions: [PlanSessionRecord]
    let now: Date
    let onMonthTap: () -> Void

    private var days: [Date] {
        let cal = Calendar.current
        guard let week = cal.dateInterval(of: .weekOfYear, for: now) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week.start) }
    }

    private func count(on day: Date) -> Int {
        sessions.filter { Calendar.current.isDate($0.startsAt, inSameDayAs: day) }.count
    }

    var body: some View {
        GlassCard(padding: Tokens.Spacing.m) {
            VStack(spacing: Tokens.Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(now, format: .dateTime.month(.wide).year())
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                    Spacer()
                    Button(action: onMonthTap) {
                        HStack(spacing: 2) {
                            Text("Month view")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(Tokens.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Tokens.Palette.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Tokens.Spacing.xs)

                HStack(spacing: Tokens.Spacing.xs) {
                    ForEach(days, id: \.self) { day in
                        DayCell(day: day,
                                isToday: Calendar.current.isDate(day, inSameDayAs: now),
                                dots: count(on: day))
                    }
                }
            }
        }
    }

    private struct DayCell: View {
        let day: Date
        let isToday: Bool
        let dots: Int

        var body: some View {
            VStack(spacing: Tokens.Spacing.xs) {
                Text(day, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(isToday ? .white.opacity(0.85) : Tokens.Palette.inkMuted)
                Text(day, format: .dateTime.day())
                    .font(Tokens.Typography.dayNumber)
                    .foregroundStyle(isToday ? .white : Tokens.Palette.ink)
                HStack(spacing: 2) {
                    ForEach(0..<min(dots, 3), id: \.self) { _ in
                        Circle()
                            .fill(isToday ? .white.opacity(0.85) : Tokens.Palette.accent.opacity(0.7))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.Spacing.s)
            .background {
                if isToday {
                    RoundedRectangle(cornerRadius: Tokens.Radius.icon, style: .continuous)
                        .fill(Tokens.Palette.accent)
                        .shadow(color: Tokens.Palette.accent.opacity(0.45), radius: 10, y: 5)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
            .accessibilityValue(dots == 0 ? "Nothing scheduled" : "\(dots) session\(dots == 1 ? "" : "s")")
            .accessibilityAddTraits(isToday ? [.isSelected] : [])
        }
    }
}

/// One scheduled block on Today.
private struct SessionCard: View {
    let record: PlanSessionRecord
    let isNow: Bool
    let onToggle: () -> Void

    private var subject: Tokens.SubjectColor {
        record.subtask?.assignment?.course?.subjectColor ?? .violet
    }
    private var isDone: Bool { record.subtask?.completedAt != nil }

    var body: some View {
        GlassCard(isProminent: isNow, tint: subject.color, padding: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                Rectangle()
                    .fill(subject.color)
                    .frame(width: 3)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Tokens.Spacing.xs + 2) {
                    if isNow {
                        Text("HAPPENING NOW")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(subject.color)
                    }

                    if let assignment = record.subtask?.assignment {
                        CourseTag(
                            code: assignment.course?.displayName ?? assignment.taskType,
                            kind: assignment.course == nil ? nil : assignment.taskType,
                            subject: subject
                        )
                    }

                    Text(record.subtask?.title ?? "Study session")
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(isDone ? Tokens.Palette.inkMuted : Tokens.Palette.ink)
                        .strikethrough(isDone)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Tokens.Spacing.s) {
                        Text("\(record.startsAt, format: .dateTime.hour().minute()) – \(record.endsAt, format: .dateTime.hour().minute())")
                            .font(Tokens.Typography.mono)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                        if let code = record.subtask?.criterionCode {
                            MetaDot()
                            Text("Criterion \(code)")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.accent)
                        }
                    }
                }

                Spacer(minLength: 0)
                CompletionToggle(isComplete: isDone, tint: subject.color, action: onToggle)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
