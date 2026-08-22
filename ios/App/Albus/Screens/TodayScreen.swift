import SwiftUI
import SwiftData
import AlbusCore

/// Today's plan. Deliberately plain — this exists to prove the loop end to end,
/// not to match the designs. The component library comes next.
struct TodayScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionService.self) private var session
    @Environment(PlanCoordinator.self) private var coordinator

    @Query(sort: \PlanSessionRecord.startsAt) private var sessions: [PlanSessionRecord]
    @Query private var assignments: [Assignment]

    @State private var addingTask = false

    private var todaySessions: [PlanSessionRecord] {
        sessions.filter { Calendar.current.isDateInToday($0.startsAt) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header

                if coordinator.status == .planning {
                    banner("Albus is planning…", tint: Tokens.Palette.accent)
                }
                if case .failed(let message) = coordinator.status {
                    banner(message, tint: Tokens.SubjectColor.red.color)
                }

                if todaySessions.isEmpty {
                    if sessions.isEmpty { empty } else { laterOnly }
                } else {
                    ForEach(todaySessions) { sessionRow($0) }
                }

                if !assignments.isEmpty {
                    Text("\(assignments.count) assignment\(assignments.count == 1 ? "" : "s") · \(sessions.count) session\(sessions.count == 1 ? "" : "s") planned")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                }
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottomTrailing) { addButton }
        .sheet(isPresented: $addingTask) {
            AddTaskSheet { title, type, deadline, minutes in
                await coordinator.addAssignment(
                    title: title, taskType: type, deadline: deadline,
                    estimatedMinutes: minutes, course: nil, context: context
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(Tokens.Typography.label)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .textCase(.uppercase)
            Text("Today")
                .font(Tokens.Typography.displayLarge)
                .foregroundStyle(Tokens.Palette.ink)
            // Surfaced so a broken session is visible rather than mysterious.
            if case .failed(let why) = session.state {
                Text("Not signed in: \(why)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.SubjectColor.red.color)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Nothing planned yet.")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.ink)
            Text("Add an assignment and Albus will break it into steps and find time for them.")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }
        .padding(.vertical, Tokens.Spacing.xl)
    }

    private var laterOnly: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Nothing today.")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.ink)
            Text("Your next session is \(sessions.first?.startsAt ?? .now, format: .dateTime.weekday().hour().minute()).")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }
        .padding(.vertical, Tokens.Spacing.xl)
    }

    private func sessionRow(_ record: PlanSessionRecord) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.startsAt, format: .dateTime.hour().minute())
                Text(record.endsAt, format: .dateTime.hour().minute())
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            .font(Tokens.Typography.mono)
            .frame(width: 56, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(record.subtask?.assignment?.course?.subjectColor.color ?? Tokens.Palette.accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.subtask?.title ?? "Session")
                    .font(Tokens.Typography.body.weight(.medium))
                    .foregroundStyle(Tokens.Palette.ink)
                if let criterion = record.subtask?.criterionCode {
                    Text("Criterion \(criterion)")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.accent)
                }
                if let assignment = record.subtask?.assignment {
                    Text(assignment.title)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.m)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    private func banner(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Tokens.Typography.label)
            .foregroundStyle(tint)
            .padding(Tokens.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
    }

    private var addButton: some View {
        Button { addingTask = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Tokens.Palette.accent, in: Circle())
                .shadow(color: Tokens.Palette.accent.opacity(0.3), radius: 12, y: 4)
        }
        .padding(.trailing, Tokens.Spacing.xl)
        .padding(.bottom, Tokens.Spacing.xxl)
        .accessibilityLabel("Add assignment")
    }
}
