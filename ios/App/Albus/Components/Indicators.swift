import SwiftUI
import AlbusCore

// Progress and completion. Every one of these takes a fraction in 0...1 or a
// Bool — none of them computes anything, because a component that derives its
// own state is a component that disagrees with the model.

/// Horizontal progress track.
///
/// Clamps its input. A negative or >1 fraction is a bug upstream, but a bar
/// that renders past its own track is a visual corruption that hides the bug.
struct ProgressBar: View {
    let fraction: Double
    var tint: Color = Tokens.Palette.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Palette.hairline)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * fraction.clamped01)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction.clamped01 * 100)) percent")
    }
}

/// Circular progress ring with a label in the middle.
///
/// The ring starts at twelve o'clock, which is why it is rotated -90°: SwiftUI
/// trims from the leading edge (three o'clock) by default.
struct ProgressRing: View {
    let fraction: Double
    var tint: Color = Tokens.Palette.accent
    var diameter: CGFloat = 68
    var lineWidth: CGFloat = 5
    var label: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Tokens.Palette.ink.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction.clamped01)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let label {
                Text(label)
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(lineWidth * 2)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(label ?? "\(Int(fraction.clamped01 * 100)) percent")
    }
}

/// Round check control. The single way anything in the app is marked done.
struct CompletionToggle: View {
    let isComplete: Bool
    var tint: Color = Tokens.Palette.accent
    var diameter: CGFloat = 24
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isComplete ? tint : .clear)
                    .overlay {
                        Circle().strokeBorder(
                            isComplete ? .clear : Tokens.Palette.hairline,
                            lineWidth: 2
                        )
                    }
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: diameter * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Tokens.Motion.quick, value: isComplete)
        .accessibilityLabel(isComplete ? "Completed" : "Not completed")
        .accessibilityAddTraits(isComplete ? [.isSelected] : [])
        .accessibilityHint(isComplete ? "Double tap to mark as not done" : "Double tap to mark as done")
    }
}

/// A node on the step rail in Task detail: numbered when pending, checked when
/// done, ringed when it is the next step to do.
///
/// Distinct from `CompletionToggle` because it carries an ordinal and a
/// three-way state; folding them together would mean a Bool plus two optionals
/// and a call site that has to explain itself.
struct StepNode: View {
    let number: Int
    let isComplete: Bool
    let isNext: Bool
    var action: () -> Void

    private let diameter: CGFloat = 24

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isComplete ? Tokens.Palette.accent
                          : isNext ? Tokens.Palette.cardSurface : .clear)
                    .overlay {
                        Circle().strokeBorder(
                            isComplete ? .clear
                            : isNext ? Tokens.Palette.accent : Tokens.Palette.hairline,
                            lineWidth: isNext ? 2 : 1.5
                        )
                    }

                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(Tokens.Typography.mono)
                        .foregroundStyle(isNext ? Tokens.Palette.accent : Tokens.Palette.inkMuted)
                }
            }
            .frame(width: diameter, height: diameter)
            // The halo marks the next step without moving anything.
            .background {
                if isNext {
                    Circle().fill(Tokens.Palette.accent.opacity(0.12)).padding(-4)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Tokens.Motion.quick, value: isComplete)
        .accessibilityLabel("Step \(number)")
        .accessibilityValue(isComplete ? "Completed" : isNext ? "Next up" : "Not started")
    }
}

/// The vertical line joining step nodes. Drawn by the list, not the node, so a
/// node never needs to know whether it is last.
struct StepRailConnector: View {
    var isComplete: Bool

    var body: some View {
        Capsule()
            .fill(isComplete ? Tokens.Palette.accent.opacity(0.35) : Tokens.Palette.hairline)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
    }
}

extension Double {
    /// Guards every indicator against out-of-range input in one place.
    var clamped01: Double { Swift.min(1, Swift.max(0, self.isFinite ? self : 0)) }
}

#Preview("Indicators") {
    ZStack {
        BackgroundGradient()
        VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
            ProgressBar(fraction: 0.42)
            ProgressBar(fraction: 1.4, tint: Tokens.SubjectColor.red.color, height: 6)
            HStack(spacing: Tokens.Spacing.l) {
                ProgressRing(fraction: 2.0 / 6.0, label: "2/6")
                ProgressRing(fraction: 0.85, tint: Tokens.SubjectColor.green.color,
                             diameter: 56, label: "85%")
            }
            HStack(spacing: Tokens.Spacing.l) {
                CompletionToggle(isComplete: false) {}
                CompletionToggle(isComplete: true) {}
                StepNode(number: 1, isComplete: true, isNext: false) {}
                StepNode(number: 2, isComplete: false, isNext: true) {}
                StepNode(number: 3, isComplete: false, isNext: false) {}
            }
        }
        .padding(Tokens.Spacing.xl)
    }
}
