import SwiftUI
import AlbusCore

/// Owns the two things every screen sits inside: the full-screen gradient and
/// the floating tab bar.
///
/// Both live here rather than in each screen so the safe-area maths is solved
/// once. Content scrolls *under* the bar, which means the bottom inset is set
/// in exactly one place and no screen adds padding of its own.
struct AppShell: View {
    @State private var tab: Tab = .today

    enum Tab: String, CaseIterable, Identifiable {
        case today, albus, tools, tasks
        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: "Today"
            case .albus: "Albus"
            case .tools: "Tools"
            case .tasks: "Tasks"
            }
        }

        var icon: String {
            switch self {
            case .today: "calendar"
            case .albus: "text.alignleft"
            case .tools: "sparkles"
            case .tasks: "checkmark.square"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // A stack per tab so pushing a detail view from Tasks does not
            // reset scroll position on Today.
            Group {
                switch tab {
                case .today: NavigationStack { Screen { TodayScreen() } }
                case .albus: NavigationStack { Screen { PlaceholderScreen(title: "Albus") } }
                case .tools: NavigationStack { Screen { PlaceholderScreen(title: "Tools") } }
                case .tasks: NavigationStack { Screen { PlaceholderScreen(title: "Tasks") } }
                }
            }

            AppTabBar(selection: $tab)
        }
        .ignoresSafeArea(.keyboard)
    }
}

/// Wraps a screen's content with the shared background and the inset the
/// floating tab bar needs.
///
/// The gradient has to live *inside* the NavigationStack: a stack paints its
/// own surface, so a gradient placed behind one is simply covered. Putting the
/// scaffold here means screens still never think about either concern.
struct Screen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BackgroundGradient())
            .safeAreaPadding(.bottom, Tokens.Spacing.tabBarInset)
    }
}

struct BackgroundGradient: View {
    var body: some View {
        LinearGradient(stops: Tokens.Palette.backgroundStops,
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct AppTabBar: View {
    @Binding var selection: AppShell.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppShell.Tab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: Tokens.Spacing.xs) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: .medium))
                        Text(tab.title)
                            .font(Tokens.Typography.caption)
                    }
                    .foregroundStyle(selection == tab
                                     ? Tokens.Palette.accent
                                     : Tokens.Palette.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.vertical, Tokens.Spacing.m)
        .padding(.horizontal, Tokens.Spacing.s)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, Tokens.Spacing.xl)
        .padding(.bottom, Tokens.Spacing.s)
    }
}

/// Temporary. Real screens land once the component library exists.
struct PlaceholderScreen: View {
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                Text(title)
                    .font(Tokens.Typography.displayLarge)
                    .foregroundStyle(Tokens.Palette.ink)
                Text("Screen not built yet.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Spacing.xl)
        }
        // Same reason: a ScrollView draws the system background unless told
        // otherwise. Every real screen will need this, so it belongs in the
        // shared scaffold rather than being repeated.
        .scrollContentBackground(.hidden)
        .background(.clear)
    }
}

#Preview {
    AppShell()
}
