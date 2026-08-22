import SwiftUI
import AlbusCore

// Interactive pieces. All of them are `.buttonStyle(.plain)` because the
// default style tints content blue, which would fight every token colour.

/// The 38pt rounded-square glass button in every screen header.
///
/// `badge` draws the unread dot. It is a Bool rather than a count because no
/// design shows a number, and a count nobody displays is state nobody maintains.
struct IconButton: View {
    let systemImage: String
    var badge: Bool = false
    var isFilled: Bool = false
    var accessibilityLabel: String
    var action: () -> Void

    private let side: CGFloat = 38

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFilled ? .white : Tokens.Palette.ink)
                .frame(width: side, height: side)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.icon, style: .continuous)
                        .fill(isFilled ? AnyShapeStyle(Tokens.Palette.accent)
                              : AnyShapeStyle(Tokens.Glass.fill))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.icon, style: .continuous)
                        .strokeBorder(isFilled ? .clear : Tokens.Glass.stroke, lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(Tokens.Palette.accent)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Tokens.Palette.backgroundStops[1].color, lineWidth: 2))
                            .offset(x: -7, y: 7)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A single filter pill.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Typography.label)
                .foregroundStyle(isSelected ? .white : Tokens.Palette.accent)
                .padding(.horizontal, Tokens.Spacing.m)
                .frame(height: 32)
                .background(
                    isSelected ? Tokens.Palette.accent : Tokens.Palette.accentWash,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Horizontally scrolling row of filter chips bound to a selection.
///
/// Generic over any `CaseIterable & Hashable` so a screen defines its filter as
/// an enum and gets the whole row for free — no array of strings that can fall
/// out of step with the switch that handles them.
struct FilterChipRow<Filter: Hashable>: View {
    let filters: [Filter]
    @Binding var selection: Filter
    let title: (Filter) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(filters, id: \.self) { filter in
                    FilterChip(title: title(filter), isSelected: filter == selection) {
                        withAnimation(Tokens.Motion.quick) { selection = filter }
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
        }
        // The row bleeds to both edges; the padding above keeps the first and
        // last chip aligned with the screen's content margin.
        .scrollClipDisabled()
    }
}

/// An external tool Albus suggests for a step — JSTOR, Claude, Grammarly.
///
/// `compact` is the 22pt monogram badge shown on a collapsed step; the full
/// form adds the name and the reason it is suggested.
struct ToolChip: View {
    let tool: StudyTool
    var compact: Bool = false
    var action: (() -> Void)?

    var body: some View {
        if compact {
            monogram(side: 22, fontSize: 10)
                .accessibilityLabel(tool.name)
        } else {
            Button { action?() } label: {
                HStack(spacing: Tokens.Spacing.s) {
                    monogram(side: 24, fontSize: 11)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tool.name)
                            .font(Tokens.Typography.label)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text(tool.reason)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }
                    .lineLimit(1)
                }
                .padding(.leading, 7)
                .padding(.trailing, Tokens.Spacing.m)
                .padding(.vertical, 7)
                .background(Tokens.Palette.cardSurface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tool.name). \(tool.reason)")
        }
    }

    private func monogram(side: CGFloat, fontSize: CGFloat) -> some View {
        Text(tool.monogram)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(tool.tint.foreground)
            .frame(width: side, height: side)
            .background(tool.tint.background,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The inline "Ask Albus about this paper…" entry point.
///
/// A button, not a text field: tapping it opens the chat surface. Making it a
/// live field here would mean two places that own the same conversation state.
struct AskAlbusBar: View {
    var prompt: String = "Ask Albus about this…"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.m) {
                Text(prompt)
                    .font(Tokens.Typography.body)
                    .italic()
                    .foregroundStyle(Tokens.Palette.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Spacing.s)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Tokens.Palette.accent, in: Circle())
            }
            .padding(.leading, Tokens.Spacing.l)
            .padding(.trailing, Tokens.Spacing.s)
            .frame(height: 44)
            .background(Tokens.Glass.fill,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(prompt)
        .accessibilityAddTraits(.isButton)
    }
}

/// Full-width primary action. One definition so every screen's main button is
/// the same height, radius and weight.
struct PrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Typography.label)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    isEnabled ? Tokens.Palette.accent : Tokens.Palette.inkMuted.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// The outlined counterpart to `PrimaryButton`.
struct SecondaryButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Typography.label)
                .foregroundStyle(Tokens.Palette.accent)
                .padding(.horizontal, Tokens.Spacing.l)
                .frame(height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(Tokens.Palette.accent, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Controls") {
    ZStack {
        BackgroundGradient()
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                HStack(spacing: Tokens.Spacing.s) {
                    IconButton(systemImage: "bell", badge: true,
                               accessibilityLabel: "Notifications") {}
                    IconButton(systemImage: "plus", isFilled: true,
                               accessibilityLabel: "Add") {}
                    IconButton(systemImage: "ellipsis", accessibilityLabel: "More") {}
                }

                StatefulPreview()

                HStack(spacing: Tokens.Spacing.xs) {
                    ForEach(StudyTool.allCases) { ToolChip(tool: $0, compact: true) }
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    ForEach(StudyTool.allCases) { ToolChip(tool: $0) }
                }

                AskAlbusBar(prompt: "Ask Albus about this paper…") {}

                HStack(spacing: Tokens.Spacing.s) {
                    PrimaryButton(title: "Start 45m session") {}
                    SecondaryButton(title: "Mark done") {}
                }
                PrimaryButton(title: "Disabled", isEnabled: false) {}
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }
}

/// Previews need somewhere to hold a binding.
private struct StatefulPreview: View {
    enum Filter: String, CaseIterable { case all, dueSoon, overdue, done }
    @State private var selection: Filter = .all

    var body: some View {
        FilterChipRow(filters: Filter.allCases, selection: $selection) {
            switch $0 {
            case .all: "All"
            case .dueSoon: "Due soon"
            case .overdue: "Overdue"
            case .done: "Done"
            }
        }
        .padding(.horizontal, -Tokens.Spacing.xl)
    }
}
