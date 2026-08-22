import SwiftUI
import AlbusCore

// The app has exactly two card surfaces. Everything that looks like a card is
// one of these, which is why a screen never writes `.background(...)` itself.
//
//   GlassCard         translucent, blurred, large radius — the Today surfaces
//   SubjectStripeCard opaque paper with a colour rail — anything owned by a course
//
// Keeping both here makes the difference deliberate rather than incidental.

/// Translucent blurred surface over the app gradient.
///
/// `isProminent` is the "happening now" treatment: more opaque, tinted edge,
/// coloured shadow. It is a parameter rather than a second component because
/// the two differ only in emphasis, and a copy would drift.
struct GlassCard<Content: View>: View {
    var isProminent: Bool = false
    /// Tints the border and shadow when prominent. Defaults to the accent.
    var tint: Color = Tokens.Palette.accent
    var padding: CGFloat = Tokens.Spacing.l
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Tokens.Radius.glass, style: .continuous)
    }

    var body: some View {
        content
            .padding(padding)
            .background {
                shape
                    .fill(isProminent ? Tokens.Glass.fillProminent : Tokens.Glass.fill)
                    .background(.ultraThinMaterial, in: shape)
            }
            .overlay {
                shape.strokeBorder(
                    isProminent ? tint.opacity(0.35) : Tokens.Glass.stroke,
                    lineWidth: isProminent ? 1.5 : 1
                )
            }
            .shadow(
                color: isProminent ? tint.opacity(0.30) : Tokens.Glass.shadow,
                radius: Tokens.Glass.shadowRadius,
                y: Tokens.Glass.shadowY
            )
    }
}

/// Opaque card carrying a subject's colour as a left rail.
///
/// The rail is drawn as an overlay clipped to the card shape rather than as a
/// leading `HStack` element, so it follows the corner curve instead of leaving
/// a square notch — the detail that separates this from a rectangle with a
/// coloured strip next to it.
struct SubjectStripeCard<Content: View>: View {
    let subject: Tokens.SubjectColor
    var padding: CGFloat = Tokens.Spacing.l
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
    }

    var body: some View {
        content
            .padding(padding)
            .padding(.leading, Tokens.subjectRailWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.cardSurface, in: shape)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(subject.color)
                    .frame(width: Tokens.subjectRailWidth)
            }
            .overlay { shape.strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5) }
            .clipShape(shape)
    }
}

#Preview("Surfaces") {
    ZStack {
        BackgroundGradient()
        ScrollView {
            VStack(spacing: Tokens.Spacing.l) {
                GlassCard {
                    Text("Glass — the Today surface")
                        .font(Tokens.Typography.cardTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GlassCard(isProminent: true, tint: Tokens.SubjectColor.red.color) {
                    Text("Glass, prominent — happening now")
                        .font(Tokens.Typography.cardTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Tokens.SubjectColor.allCases, id: \.self) { subject in
                    SubjectStripeCard(subject: subject) {
                        Text("Stripe card — \(subject.rawValue)")
                            .font(Tokens.Typography.cardTitle)
                    }
                }
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }
}
