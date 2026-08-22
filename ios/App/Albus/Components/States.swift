import SwiftUI
import AlbusCore

// Empty and error states. The design treats these as one system applied
// everywhere rather than as per-screen one-offs, so they are components.

/// What a screen shows when it has nothing to show.
///
/// Always carries a title and a line explaining what would fill it. The action
/// is optional because some empties are good news ("nothing overdue") and
/// offering a button there invents work.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Tokens.Palette.accent.opacity(0.55))
                .frame(width: 64, height: 64)
                .background(Tokens.Palette.accentWash.opacity(0.6), in: Circle())

            VStack(spacing: Tokens.Spacing.xs + 2) {
                Text(title)
                    .font(Tokens.Typography.heading)
                    .foregroundStyle(Tokens.Palette.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                SecondaryButton(title: actionTitle, action: action)
                    .padding(.top, Tokens.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Tokens.Spacing.xl)
        .padding(.vertical, Tokens.Spacing.xxl)
        .accessibilityElement(children: .contain)
    }
}

/// An inline strip of status: Albus working, something failed, something is
/// only cached.
///
/// The tone carries both colour and icon — colour alone fails for a student who
/// cannot distinguish red from grey, and this is the component that tells
/// someone their work did not save.
struct StatusBanner: View {
    enum Tone {
        case working, warning, error

        var tint: Color {
            switch self {
            case .working: Tokens.Palette.accent
            case .warning: Tokens.SubjectColor.amber.color
            case .error:   Tokens.Palette.danger
            }
        }

        var icon: String {
            switch self {
            case .working: "sparkles"
            case .warning: "exclamationmark.triangle.fill"
            case .error:   "xmark.octagon.fill"
            }
        }
    }

    let tone: Tone
    let message: String
    var retryTitle: String?
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: tone.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.tint)
                .symbolEffect(.pulse, isActive: tone == .working)

            Text(message)
                .font(Tokens.Typography.label)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let retryTitle, let retry {
                Button(retryTitle, action: retry)
                    .font(Tokens.Typography.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(tone.tint)
                    .buttonStyle(.plain)
            }
        }
        .padding(Tokens.Spacing.m)
        .background(tone.tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                .strokeBorder(tone.tint.opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        // Screen readers should hear a failure without hunting for it.
        .accessibilityAddTraits(tone == .error ? [.isStaticText] : [])
    }
}

/// Albus's own line about the plan — the mascot slot plus a sentence.
///
/// The mascot is a placeholder glyph until the real cactus asset is added; the
/// layout reserves the exact space the design gives it so dropping the artwork
/// in later moves nothing.
struct AlbusNote: View {
    let text: AttributedString
    var isBusy: Bool = false

    init(_ text: String, isBusy: Bool = false) {
        self.text = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        self.isBusy = isBusy
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            Image(systemName: isBusy ? "leaf.fill" : "leaf")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Tokens.SubjectColor.green.color)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text(text)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("States") {
    ZStack {
        BackgroundGradient()
        ScrollView {
            VStack(spacing: Tokens.Spacing.xl) {
                StatusBanner(tone: .working, message: "Albus is planning…")
                StatusBanner(tone: .warning, message: "Showing your last saved plan.")
                StatusBanner(tone: .error, message: "Couldn't reach Albus.",
                             retryTitle: "Retry") {}

                AlbusNote("Research is behind you. **Build the outline** is the step that makes tomorrow's draft short.", isBusy: true)

                EmptyState(
                    icon: "calendar",
                    title: "Nothing planned yet",
                    message: "Add an assignment and Albus will break it into steps and find time for them.",
                    actionTitle: "Add an assignment"
                ) {}

                EmptyState(
                    icon: "checkmark.circle",
                    title: "All clear",
                    message: "Nothing is overdue. Enjoy it."
                )
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }
}
