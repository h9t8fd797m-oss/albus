import SwiftUI
import SwiftData
import AlbusCore

/// One assignment, and the plan Albus built for it.
///
/// This is where the rubric layer is visible: steps carry the criterion they
/// serve and the tools that help, which is the difference between "study
/// history 6–7" and a plan you can start.
struct TaskDetailScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(Preferences.self) private var preferences

    let assignment: Assignment

    @State private var expanded: UUID?
    @State private var asking = false

    private var subject: Tokens.SubjectColor { assignment.course?.subjectColor ?? .violet }
    private var steps: [Subtask] { assignment.subtasks.sorted { $0.ordinal < $1.ordinal } }
    private var doneCount: Int { steps.filter { $0.completedAt != nil }.count }
    private var totalMinutes: Int { steps.reduce(0) { $0 + $1.estimatedMinutes } }
    private var remainingMinutes: Int {
        steps.filter { $0.completedAt == nil }.reduce(0) { $0 + $1.estimatedMinutes }
    }
    /// The first unfinished step. Everything before it is history; this is the
    /// one the screen argues for.
    private var nextStepID: UUID? { steps.first { $0.completedAt == nil }?.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                summary
                albusNote
                plan
                AskAlbusBar(prompt: "Ask Albus about this \(assignment.taskType)…") {
                    asking = true
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $asking) {
            AskAlbusSheet(assignment: assignment)
        }
    }

    // MARK: - Summary

    private var summary: some View {
        SubjectStripeCard(subject: subject) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                CourseTag(code: assignment.course?.displayName ?? "General",
                          kind: assignment.taskType, subject: subject)

                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(assignment.title)
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notes = assignment.notes, !notes.isEmpty {
                        Text(notes)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                DeadlineLabel(deadline: assignment.deadline)

                if !steps.isEmpty {
                    VStack(spacing: Tokens.Spacing.s) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(doneCount) of \(steps.count) steps · \(DurationText.short(minutes: remainingMinutes)) left of \(DurationText.short(minutes: totalMinutes))")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.inkSecondary)
                            Spacer()
                            Text("\(Int(assignment.progress * 100))%")
                                .font(Tokens.Typography.mono)
                                .foregroundStyle(Tokens.Palette.ink)
                        }
                        ProgressBar(fraction: assignment.progress, tint: subject.color, height: 6)
                    }
                }
            }
        }
    }

    @ViewBuilder private var albusNote: some View {
        if steps.isEmpty {
            StatusBanner(tone: .warning,
                         message: "This assignment has no plan yet. Albus couldn't reach the planner when you added it.")
        } else if let next = steps.first(where: { $0.completedAt == nil }) {
            AlbusNote("**\(next.title)** is the step that makes the rest shorter.", isBusy: true)
        } else {
            AlbusNote("Every step is done. **Hand it in** and take the evening back.")
        }
    }

    // MARK: - Plan

    @ViewBuilder private var plan: some View {
        if !steps.isEmpty {
            SectionHeader(label: "Albus's plan", count: steps.count) {
                Text(DurationText.short(minutes: totalMinutes))
                    .font(Tokens.Typography.mono)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
            .padding(.top, Tokens.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    StepRow(
                        step: step,
                        number: index + 1,
                        isLast: index == steps.count - 1,
                        isNext: step.id == nextStepID,
                        isExpanded: expanded == step.id,
                        subject: subject,
                        onToggleDone: {
                            coordinator.setCompleted(step, step.completedAt == nil, context: context,
                                     availability: preferences.availability)
                        },
                        onTap: {
                            withAnimation(Tokens.Motion.quick) {
                                expanded = expanded == step.id ? nil : step.id
                            }
                        }
                    )
                }
            }
        }
    }
}

/// One step on the rail.
private struct StepRow: View {
    let step: Subtask
    let number: Int
    let isLast: Bool
    let isNext: Bool
    let isExpanded: Bool
    let subject: Tokens.SubjectColor
    let onToggleDone: () -> Void
    let onTap: () -> Void

    private var isDone: Bool { step.completedAt != nil }
    /// The card opens for the next step automatically, and for anything tapped.
    private var showsCard: Bool { isNext || isExpanded }

    /// Tools are suggested from the step's own text. Deterministic and local —
    /// no extra model call to decide that an outline benefits from Claude.
    private var tools: [StudyTool] { StudyTool.suggested(for: step) }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            VStack(spacing: Tokens.Spacing.xs) {
                StepNode(number: number, isComplete: isDone, isNext: isNext, action: onToggleDone)
                if !isLast { StepRailConnector(isComplete: isDone) }
            }
            .frame(width: 24)

            body(for: step)
                .padding(.bottom, Tokens.Spacing.m + 2)
        }
    }

    @ViewBuilder private func body(for step: Subtask) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            headline
            if showsCard { detail }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(showsCard ? Tokens.Spacing.m : 0)
        .padding(.leading, showsCard && isNext ? Tokens.subjectRailWidth : 0)
        .background {
            if showsCard {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.cardSurface)
                    .overlay(alignment: .leading) {
                        if isNext {
                            Rectangle()
                                .fill(Tokens.Palette.accent)
                                .frame(width: Tokens.subjectRailWidth)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                            .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var headline: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                if isNext {
                    Text("DO THIS NEXT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Tokens.Palette.accent)
                }
                Text(step.title)
                    .font(isNext ? Tokens.Typography.cardTitle : Tokens.Typography.label)
                    .foregroundStyle(isDone ? Tokens.Palette.inkMuted : Tokens.Palette.ink)
                    .strikethrough(isDone)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Tokens.Spacing.xs)

            if !showsCard && !tools.isEmpty {
                HStack(spacing: Tokens.Spacing.xs) {
                    ForEach(tools) { ToolChip(tool: $0, compact: true) }
                }
            }

            Text(DurationText.short(minutes: step.estimatedMinutes))
                .font(Tokens.Typography.mono)
                .foregroundStyle(isDone ? Tokens.Palette.inkMuted
                                 : isNext ? Tokens.Palette.accent : Tokens.Palette.inkSecondary)
        }
    }

    @ViewBuilder private var detail: some View {
        if let guidance = step.guidance, !guidance.isEmpty {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Circle()
                    .fill(Tokens.Palette.separator)
                    .frame(width: 4, height: 4)
                    .padding(.top, 6)
                Text(guidance)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let code = step.criterionCode {
            Text("Serves criterion \(code)")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.accent)
        }

        if !tools.isEmpty {
            // Wraps rather than scrolls: a horizontal scroller inside a
            // vertical one steals the drag and makes the list feel broken.
            FlowLayout(spacing: Tokens.Spacing.s) {
                ForEach(tools) { ToolChip(tool: $0) }
            }
            .padding(.top, Tokens.Spacing.xs)
        }

        if isNext {
            HStack(spacing: Tokens.Spacing.s) {
                PrimaryButton(title: "Start \(DurationText.short(minutes: step.estimatedMinutes)) session") {
                    onToggleDone()
                }
                SecondaryButton(title: "Mark done", action: onToggleDone)
            }
            .padding(.top, Tokens.Spacing.xs)
        }
    }
}

/// Minimal wrapping layout. SwiftUI has no built-in flow container, and a
/// horizontal ScrollView nested in a vertical one hijacks the gesture.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
