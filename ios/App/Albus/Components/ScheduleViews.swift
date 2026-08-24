import SwiftUI
import SwiftData
import AlbusCore

// Schedule views shared by Home and the plan screen.
//
// These used to be private to Home. Home is now the assignment list, and the
// session-level views belong where the sessions are — inside a plan. Extracting
// them was the alternative to a second, drifting copy.

struct WeekStrip: View {
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
struct SessionCard: View {
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

/// The one session-level thing on Home.
///
/// "What do I do right now" is the single question a planner has to answer
/// without making the student navigate. It names the assignment, not the step
/// list, and one tap goes straight into Focus Mode.
struct UpNextCard: View {
    let record: PlanSessionRecord
    let now: Date
    let onStart: () -> Void

    private var subject: Tokens.SubjectColor {
        record.subtask?.assignment?.course?.subjectColor ?? .violet
    }

    private var isNow: Bool { record.startsAt <= now && record.endsAt > now }

    private var whenLabel: String {
        if isNow { return "HAPPENING NOW" }
        let cal = Calendar.current
        if cal.isDateInToday(record.startsAt) { return "UP NEXT · TODAY" }
        if cal.isDateInTomorrow(record.startsAt) { return "UP NEXT · TOMORROW" }
        return "UP NEXT · " + record.startsAt.formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }

    var body: some View {
        Button(action: onStart) {
            GlassCard(isProminent: isNow, tint: subject.color) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    Text(whenLabel)
                        .font(Tokens.Typography.overline)
                        .tracking(Tokens.Tracking.overline)
                        .foregroundStyle(isNow ? subject.color : Tokens.Palette.inkMuted)

                    Text(record.subtask?.assignment?.title ?? "Study session")
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    HStack(spacing: Tokens.Spacing.s) {
                        Text(record.startsAt, format: .dateTime.hour().minute())
                            .font(Tokens.Typography.mono)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                        MetaDot()
                        Text(DurationText.short(minutes: record.plannedSeconds / 60))
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Focus")
                                .font(Tokens.Typography.label)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, Tokens.Spacing.m)
                        .frame(height: 30)
                        .background(Tokens.Palette.accent, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Starts Focus Mode")
    }
}
