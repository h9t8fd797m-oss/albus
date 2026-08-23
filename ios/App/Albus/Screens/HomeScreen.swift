import SwiftUI
import SwiftData
import AlbusCore

/// Home: what is happening now, and everything still ahead.
///
/// Was "Today", and only ever showed sessions the scheduler had placed today —
/// so a plan built in the evening, correctly scheduled for tomorrow morning,
/// made the app look empty at the exact moment the student had just used it.
/// It now shows the whole road ahead, with today at the top.
struct HomeScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionService.self) private var session
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(Preferences.self) private var preferences

    @Query(sort: \PlanSessionRecord.startsAt) private var sessions: [PlanSessionRecord]

    @State private var addingTask = false
    @State private var showingMonth = false
    @State private var focusing: PlanSessionRecord?

    var body: some View {
        // Re-renders once a minute so "happening now", the countdown to the
        // next block and the greeting all stay true without being revisited.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(now: timeline.date)
        }
        .sheet(isPresented: $addingTask) {
            AddTaskSheet { title, type, deadline, minutes in
                Task {
                    await coordinator.addAssignment(
                        title: title, taskType: type, deadline: deadline,
                        estimatedMinutes: minutes, course: nil, context: context,
                        availability: preferences.availability
                    )
                }
            }
        }
        .fullScreenCover(item: $focusing) { record in
            FocusModeScreen(record: record)
        }
        // Catch up on anything missed since the app was last open. This is
        // where "it finds a new spot for what you skipped" actually happens.
        .task {
            coordinator.sweepMissedSessions(context: context,
                                            availability: preferences.availability)
        }
        .navigationDestination(isPresented: $showingMonth) {
            Screen { MonthCalendarScreen() }
        }
    }

    private func content(now: Date) -> some View {
        let upcoming = upcomingSessions(now: now)
        let today = upcoming.filter { Calendar.current.isDateInToday($0.startsAt) }
        let current = upcoming.first { $0.startsAt <= now && $0.endsAt > now }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header(now: now)
                status

                FocusCard(sessions: today, studiedMinutes: studiedToday(),
                          next: upcoming.first { $0.startsAt > now })
                WeekStrip(sessions: sessions, now: now) { showingMonth = true }

                if upcoming.isEmpty {
                    emptyState
                } else {
                    schedule(upcoming: upcoming, current: current, now: now)
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    /// Everything not yet done, from the current block onward. Sessions whose
    /// window has passed but which were never completed stay visible: silently
    /// dropping missed work is how a planner loses a student's trust.
    private func upcomingSessions(now: Date) -> [PlanSessionRecord] {
        sessions.filter { $0.subtask?.completedAt == nil && $0.endsAt > now.addingTimeInterval(-86_400) }
    }

    private func studiedToday() -> Int {
        sessions
            .filter { Calendar.current.isDateInToday($0.startsAt) }
            .compactMap(\.measuredMinutes)
            .reduce(0, +)
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

                // Two lines, with the name set apart — the design's own shape.
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

    // MARK: - Schedule

    @ViewBuilder
    private func schedule(upcoming: [PlanSessionRecord],
                          current: PlanSessionRecord?, now: Date) -> some View {
        let groups = Dictionary(grouping: upcoming) {
            Calendar.current.startOfDay(for: $0.startsAt)
        }

        ForEach(groups.keys.sorted(), id: \.self) { day in
            let items = (groups[day] ?? []).sorted { $0.startsAt < $1.startsAt }
            let minutes = items.reduce(0) { $0 + $1.plannedSeconds / 60 }

            SectionHeader(label: dayLabel(day, now: now), count: items.count) {
                Text(DurationText.short(minutes: minutes))
                    .font(Tokens.Typography.mono)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
            .padding(.top, Tokens.Spacing.xs)

            VStack(spacing: Tokens.Spacing.s + 2) {
                ForEach(items) { record in
                    SessionCard(record: record,
                                isNow: record.id == current?.id,
                                isOverdue: record.endsAt < now) {
                        focusing = record
                    }
                }
            }
        }
    }

    private func dayLabel(_ day: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        // Within the week, the weekday alone is enough to orient.
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: day).day,
           days > 0, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var emptyState: some View {
        EmptyState(
            icon: "calendar",
            title: sessions.isEmpty ? "Nothing planned yet" : "You're all caught up",
            message: sessions.isEmpty
                ? "Add an assignment and Albus will break it into steps and find time for them."
                : "Every step is done. Add the next thing when you're ready.",
            actionTitle: "Add an assignment"
        ) { addingTask = true }
    }
}

// MARK: - Home-only pieces

/// "Two down, four to go" — the day at a glance.
private struct FocusCard: View {
    let sessions: [PlanSessionRecord]
    let studiedMinutes: Int
    let next: PlanSessionRecord?

    private var total: Int { sessions.count }
    private var done: Int { sessions.filter { $0.subtask?.completedAt != nil }.count }
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
        guard total > 0 else {
            return next == nil ? "Nothing scheduled" : "Nothing today"
        }
        if done == 0 { return "\(total) block\(total == 1 ? "" : "s") today" }
        if done == total { return "Day complete" }
        return "\(done) down, \(total - done) to go"
    }

    private var detail: String {
        var parts: [String] = []
        if studiedMinutes > 0 {
            parts.append("\(DurationText.short(minutes: studiedMinutes)) focused")
        }
        if let next {
            let when = Calendar.current.isDateInToday(next.startsAt)
                ? next.startsAt.formatted(date: .omitted, time: .shortened)
                : next.startsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            parts.append("next at \(when)")
        }
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

    private var weekNumber: Int {
        Calendar.current.component(.weekOfYear, from: now)
    }

    var body: some View {
        GlassCard(padding: Tokens.Spacing.m) {
            VStack(spacing: Tokens.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s - 2) {
                    Text(now, format: .dateTime.month(.wide))
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text(verbatim: "\(now.formatted(.dateTime.year())) · Week \(weekNumber)")
                        .font(Tokens.Typography.micro)
                        .foregroundStyle(Tokens.Palette.inkMuted)
                    Spacer()
                    Button(action: onMonthTap) {
                        HStack(spacing: 2) {
                            Text("Month view")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(Tokens.Typography.micro)
                        .fontWeight(.semibold)
                        .tracking(0.5)
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
            VStack(spacing: 2) {
                Text(day, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(Tokens.Tracking.overline)
                    .textCase(.uppercase)
                    .foregroundStyle(isToday ? .white.opacity(0.85) : Tokens.Palette.inkMuted)
                Text(day, format: .dateTime.day())
                    .font(Tokens.Typography.dayNumber)
                    .tracking(Tokens.Tracking.display)
                    .foregroundStyle(isToday ? .white : Tokens.Palette.ink)
                HStack(spacing: 2) {
                    ForEach(0..<min(dots, 3), id: \.self) { i in
                        Circle()
                            .fill(isToday ? .white.opacity(0.8) : Tokens.Palette.accent)
                            .opacity(isToday ? 1 : 0.4 + Double(i) * 0.2)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.Spacing.s)
            .background {
                if isToday {
                    RoundedRectangle(cornerRadius: Tokens.Radius.icon, style: .continuous)
                        .fill(Tokens.Palette.accent)
                        .shadow(color: Tokens.Palette.accent.opacity(0.53), radius: 11, y: 5)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
            .accessibilityValue(dots == 0 ? "Nothing scheduled" : "\(dots) session\(dots == 1 ? "" : "s")")
            .accessibilityAddTraits(isToday ? [.isSelected] : [])
        }
    }
}

/// One scheduled block.
///
/// Tapping opens Focus Mode. There is deliberately **no** tick box here: a
/// checkbox that banks a whole session in one tap is what made the estimator's
/// data worthless, and it is the thing this screen most needed to lose.
private struct SessionCard: View {
    let record: PlanSessionRecord
    let isNow: Bool
    let isOverdue: Bool
    let onOpen: () -> Void

    private var subject: Tokens.SubjectColor {
        record.subtask?.assignment?.course?.subjectColor ?? .violet
    }
    private var partial: Int? { record.measuredMinutes }

    var body: some View {
        Button(action: onOpen) {
            GlassCard(isProminent: isNow, tint: subject.color, padding: 0) {
                ZStack(alignment: .topTrailing) {
                    HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                        // Inset rail, following the card's curve rather than
                        // butting against its edge.
                        Capsule()
                            .fill(subject.color)
                            .frame(width: 3)
                            .padding(.vertical, Tokens.Spacing.m + 2)
                            .padding(.leading, 6)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            if let assignment = record.subtask?.assignment {
                                CourseTag(
                                    code: assignment.course?.displayName ?? assignment.taskType,
                                    kind: assignment.course == nil ? nil : assignment.taskType,
                                    subject: subject
                                )
                            }

                            Text(record.subtask?.title ?? "Study session")
                                .font(Tokens.Typography.cardTitle)
                                .foregroundStyle(Tokens.Palette.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: Tokens.Spacing.s) {
                                Text(timeRange)
                                    .font(Tokens.Typography.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(Tokens.Palette.inkSecondary)
                                if let note {
                                    MetaDot()
                                    Text(note)
                                        .font(Tokens.Typography.caption)
                                        .foregroundStyle(noteTint)
                                }
                            }
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isNow ? .white : Tokens.Palette.ink)
                            .frame(width: 32, height: 32)
                            .background(
                                isNow ? AnyShapeStyle(subject.color)
                                      : AnyShapeStyle(Tokens.Palette.ink.opacity(0.06)),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                     style: .continuous)
                            )
                    }
                    .padding(.trailing, Tokens.Spacing.l)
                    .padding(.vertical, Tokens.Spacing.m + 2)

                    if isNow { happeningNow }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens focus mode")
    }

    private var happeningNow: some View {
        HStack(spacing: 5) {
            Circle().fill(.white).frame(width: 5, height: 5)
            Text("HAPPENING NOW")
                .font(.system(size: 9, weight: .bold))
                .tracking(Tokens.Tracking.overline)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Tokens.Spacing.s + 2)
        .padding(.vertical, 4)
        .background(subject.color, in: UnevenRoundedRectangle(
            topLeadingRadius: Tokens.Radius.control,
            bottomLeadingRadius: Tokens.Radius.control,
            bottomTrailingRadius: 0,
            topTrailingRadius: Tokens.Radius.session
        ))
    }

    private var timeRange: String {
        "\(record.startsAt.formatted(date: .omitted, time: .shortened)) – \(record.endsAt.formatted(date: .omitted, time: .shortened))"
    }

    /// One line of context, in priority order: work already banked, then a
    /// missed window, then the rubric criterion.
    private var note: String? {
        if let partial { return "\(DurationText.short(minutes: partial)) done" }
        if isOverdue { return "missed" }
        if let code = record.subtask?.criterionCode { return "Criterion \(code)" }
        return nil
    }

    private var noteTint: Color {
        if partial != nil { return Tokens.SubjectColor.green.color }
        if isOverdue { return Tokens.Palette.danger }
        return Tokens.Palette.accent
    }
}
