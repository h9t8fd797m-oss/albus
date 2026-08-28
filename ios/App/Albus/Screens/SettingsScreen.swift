import SwiftUI
import SwiftData
import AlbusCore

/// The fourth tab, and the answer to two questions a student could not ask
/// before: *what am I on*, and *where do I change this*.
///
/// It replaced Ask Albus in the tab bar. That was the right trade in both
/// directions — a conversation belongs beside the work it is about, not in a
/// tab of its own, and every setting in the app was previously reachable only
/// by finding one small button on Home.
struct SettingsScreen: View {
    @Environment(EntitlementService.self) private var entitlements
    @Environment(Preferences.self) private var preferences
    @Environment(SessionService.self) private var session

    @State private var showingPaywall = false

    var body: some View {
        @Bindable var preferences = preferences

        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                header
                planSection
                profileSection($preferences)
                notificationsSection
                aboutSection
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingPaywall) { PaywallScreen() }
        .task { await entitlements.refresh() }
        .refreshable { await entitlements.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("SETTINGS")
                .font(Tokens.Typography.overline)
                .tracking(Tokens.Tracking.overline)
                .foregroundStyle(Tokens.Palette.inkMuted)
            Text("Settings")
                .font(Tokens.Typography.displayLarge)
                .foregroundStyle(Tokens.Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Plan

    /// What they are on, what is left of it, and the way to change it.
    ///
    /// The meters read the same `my_plan()` call the gate enforces, so the
    /// number here cannot disagree with the number that refuses a request —
    /// which is exactly the bug migration 0033 existed to fix on one feature
    /// and this screen would otherwise reintroduce on four.
    private var planSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "Your plan") { EmptyView() }

            GlassCard(isProminent: entitlements.isPaid) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entitlements.plan.displayName)
                            .font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer()
                        Text(entitlements.plan.priceLabel)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    }

                    if let renews = entitlements.plan.expiresAt, entitlements.isPaid {
                        Text("Renews \(renews.formatted(date: .abbreviated, time: .omitted))")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }

                    VStack(spacing: Tokens.Spacing.s) {
                        allowanceRow("Active tasks", entitlements.plan.tasks)
                        allowanceRow("Marking", entitlements.plan.grader, unit: "this week")
                        allowanceRow("Ask Albus", entitlements.plan.chat, unit: "this month")
                        allowanceRow("Saved rubrics", entitlements.plan.rubrics)
                    }

                    PrimaryButton(title: entitlements.isPaid ? "Change plan" : "See the plans") {
                        showingPaywall = true
                    }
                }
            }
        }
    }

    /// One metered line. Three states, because there are genuinely three:
    /// not on this plan, unlimited, or a number left.
    private func allowanceRow(_ label: String,
                              _ allowance: EntitlementService.Allowance,
                              unit: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text(label)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.ink)
            Spacer(minLength: Tokens.Spacing.m)

            // `isIncluded` before `remaining`, always. A limit of zero has a
            // remaining of zero, and rendering "0 left" to somebody who never
            // had any promises a Monday that is not coming.
            if !allowance.isIncluded {
                Text("Not included")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            } else if allowance.isUnlimited {
                Text("Unlimited")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            } else if let left = allowance.remaining, let limit = allowance.limit {
                Text("\(left) of \(limit) left\(unit.map { " \($0)" } ?? "")")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(left > 0 ? Tokens.Palette.inkSecondary
                                              : Tokens.Palette.danger)
            }
        }
    }

    // MARK: - Profile

    /// The answers onboarding asked for, editable afterwards.
    ///
    /// These were write-once until now: a student who picked the wrong exam
    /// board on their first launch had no way to correct it, and the board is
    /// what every curriculum lookup keys on.
    private func profileSection(_ preferences: Bindable<Preferences>) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "You") { EmptyView() }

            GlassCard {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    SheetField(label: "Name") {
                        TextField("Your name", text: preferences.name)
                            .textInputAutocapitalization(.words)
                            .foregroundStyle(Tokens.Palette.ink)
                    }

                    SheetPicker(
                        label: "Programme",
                        options: Preferences.Program.allCases.map { (value: $0, title: $0.rawValue) },
                        selection: preferences.program)

                    // Only A-level has more than one authority, and a picker
                    // with one option is not a choice.
                    if preferences.wrappedValue.availableBoards.count > 1 {
                        SheetPicker(
                            label: "Exam board",
                            options: preferences.wrappedValue.availableBoards.map { (value: $0, title: $0) },
                            selection: preferences.examBoard)
                    }

                    SheetPicker(
                        label: "Work in a day",
                        options: Preferences.StudyLoad.allCases.map { (value: $0, title: $0.title) },
                        selection: preferences.load)
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "Notifications") { EmptyView() }
            NavigationLink { Screen { NotificationSettingsScreen() } } label: {
                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("When Albus speaks")
                                .font(Tokens.Typography.body)
                                .foregroundStyle(Tokens.Palette.ink)
                            Text("Quiet hours, deadline warnings, the morning brief")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Tokens.Spacing.m)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "About") { EmptyView() }
            GlassCard {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    aboutRow("Version", Self.version)
                    aboutRow("Account", accountLabel)
                }
            }
        }
    }

    private func aboutRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.ink)
            Spacer(minLength: Tokens.Spacing.m)
            Text(value)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
    }

    /// Never the user id. It identifies nothing to the student and is the one
    /// string on this screen worth not putting on a shared screenshot.
    private var accountLabel: String {
        if case .signedIn = session.state { return "Signed in" }
        return "Not signed in"
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
