import SwiftUI
import AlbusCore

/// Albus Plus.
///
/// The purchase itself is RevenueCat's job — this screen presents the offer and
/// hands off. It deliberately owns no entitlement logic: what a student gets is
/// decided by the server from RevenueCat's webhook, and this screen only ever
/// *reads* `EntitlementService`.
struct PaywallScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementService.self) private var entitlements

    @State private var plan: Plan = .annual
    @State private var purchaseState: PurchaseState = .idle

    enum Plan: String, CaseIterable, Identifiable {
        case annual, monthly
        var id: String { rawValue }

        var title: String { self == .annual ? "Annual" : "Monthly" }
        /// Display only. The real price comes from the store at purchase time —
        /// a hardcoded price that disagrees with what the student is charged is
        /// both a bug and an App Store rejection.
        var headline: String { self == .annual ? "$4.17" : "$4.99" }
        var period: String { "per month" }
        var note: String { self == .annual ? "$49.99 billed yearly" : "Billed monthly" }
        var tag: String? { self == .annual ? "2 months free" : nil }
    }

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case unavailable
        case failed(String)
    }

    private struct Value: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Tokens.Tint
        let title: String
        let detail: String
    }

    private let values: [Value] = [
        .init(icon: "calendar", tint: .violet,
              title: "Plans your semester around you",
              detail: "Every deadline becomes a schedule that fits your real week."),
        .init(icon: "arrow.triangle.2.circlepath", tint: .blue,
              title: "Rebuilds the plan when life moves",
              detail: "Miss a block and Albus redistributes the hours before you notice."),
        .init(icon: "list.bullet.indent", tint: .teal,
              title: "Plans inside each task",
              detail: "Essays arrive as steps with estimates, not one line on a list."),
        .init(icon: "book", tint: .amber,
              title: "Knows what your courses ask for",
              detail: "Rubrics, reading lists and past papers shape the work he sets."),
        .init(icon: "chart.line.uptrend.xyaxis", tint: .green,
              title: "Learns how you actually study",
              detail: "Your pace, your best hours, your habit of starting late.")
    ]

    var body: some View {
        ZStack {
            BackgroundGradient()
            if entitlements.isPlus {
                alreadySubscribed
            } else {
                offer
            }
        }
        .task { await entitlements.refresh() }
    }

    private var alreadySubscribed: some View {
        VStack(spacing: Tokens.Spacing.l) {
            EmptyState(icon: "checkmark.seal.fill", title: "You're on Plus",
                       message: expiryMessage)
            PrimaryButton(title: "Done") { dismiss() }
                .padding(.horizontal, Tokens.Spacing.xl)
        }
    }

    private var expiryMessage: String {
        guard let expires = entitlements.expiresAt else {
            return "Everything Albus can do is switched on."
        }
        return "Your plan renews \(expires.formatted(.dateTime.month().day()))."
    }

    private var offer: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                    header
                    valueList
                    planPicker
                    if case .failed(let why) = purchaseState {
                        StatusBanner(tone: .error, message: why)
                    }
                    if purchaseState == .unavailable {
                        StatusBanner(tone: .warning,
                                     message: "Purchases aren't available in this build yet.")
                    }
                }
                .padding(.horizontal, Tokens.Spacing.xl)
                .padding(.bottom, Tokens.Spacing.xl)
            }
            .scrollContentBackground(.hidden)

            purchaseBar
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Text("ALBUS PLUS")
                .font(Tokens.Typography.overline)
                .tracking(Tokens.Tracking.overline)
                .foregroundStyle(Tokens.Palette.accent)
            Text("A plan that keeps up with you.")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Tokens.Spacing.s)
    }

    private var valueList: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader("What Plus adds")
            VStack(spacing: Tokens.Spacing.s) {
                ForEach(values) { value in
                    GlassCard(padding: Tokens.Spacing.m) {
                        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                            Image(systemName: value.icon)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(value.tint.foreground)
                                .frame(width: 34, height: 34)
                                .background(value.tint.background,
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(value.title)
                                    .font(Tokens.Typography.label)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Tokens.Palette.ink)
                                Text(value.detail)
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var planPicker: some View {
        HStack(spacing: Tokens.Spacing.m) {
            ForEach(Plan.allCases) { option in
                PlanCard(plan: option, isSelected: plan == option) {
                    withAnimation(Tokens.Motion.quick) { plan = option }
                }
            }
        }
    }

    private var purchaseBar: some View {
        VStack(spacing: Tokens.Spacing.s) {
            PrimaryButton(title: purchaseState == .purchasing ? "Starting…" : "Start free trial",
                          isEnabled: purchaseState != .purchasing,
                          action: purchase)
            Text("Then \(plan.note) · Cancel anytime")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
        .padding(.horizontal, Tokens.Spacing.xl)
        .padding(.bottom, Tokens.Spacing.l)
    }

    /// Hands off to the store.
    ///
    /// Unimplemented until RevenueCat is configured, and it says so rather than
    /// pretending: a button that silently does nothing is worse than one that
    /// admits it cannot yet. Wiring it up is `Purchases.shared.purchase(...)`
    /// here and nothing else in the app — entitlement still arrives from the
    /// server, via the webhook.
    private func purchase() {
        purchaseState = .unavailable
    }

    private struct PlanCard: View {
        let plan: Plan
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    HStack {
                        Text(plan.title)
                            .font(Tokens.Typography.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer(minLength: 0)
                        Circle()
                            .strokeBorder(isSelected ? Tokens.Palette.accent : Tokens.Palette.hairline,
                                          lineWidth: isSelected ? 5 : 1.5)
                            .frame(width: 18, height: 18)
                    }
                    Text(plan.headline)
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text(plan.period)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkMuted)
                    if let tag = plan.tag {
                        Text(tag)
                            .font(Tokens.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Tokens.Palette.accent)
                            .padding(.horizontal, Tokens.Spacing.s)
                            .padding(.vertical, 2)
                            .background(Tokens.Palette.accentWash, in: Capsule())
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Spacing.m)
                .background(Tokens.Palette.cardSurface,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .strokeBorder(isSelected ? Tokens.Palette.accent : Tokens.Palette.hairline,
                                      lineWidth: isSelected ? 2 : 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityLabel("\(plan.title), \(plan.headline) \(plan.period)")
        }
    }
}
