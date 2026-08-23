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
            case .tools: "gearshape"
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
                case .today: NavigationStack { Screen { HomeScreen() } }
                case .albus: NavigationStack { Screen { AlbusScreen() } }
                case .tools: NavigationStack { Screen { ToolsScreen() } }
                case .tasks: NavigationStack { Screen { TasksScreen() } }
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

/// The app's aurora background: a warm paper wash with three blurred colour
/// blobs, matching `PhoneBackground(variant: "aurora")` in the prototype.
///
/// Drawn with `.blur` on plain circles rather than as a shipped image so it
/// scales to any device without an asset, and so a palette change stays a
/// token edit. `drawingGroup()` flattens the blurs into one offscreen pass —
/// without it three large blurred layers are recomposited on every scroll
/// frame, which is visible on older devices.
struct BackgroundGradient: View {
    var body: some View {
        LinearGradient(stops: Tokens.Palette.backgroundStops,
                       startPoint: .top, endPoint: .bottom)
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack {
                        blob(Tokens.Palette.auroraViolet, opacity: 0.35, size: w * 0.95)
                            .offset(x: -w * 0.35, y: -w * 0.30)
                        blob(Tokens.Palette.auroraAmber, opacity: 0.22, size: w * 0.90)
                            .offset(x: w * 0.42, y: w * 0.30)
                        blob(Tokens.Palette.auroraGreen, opacity: 0.18, size: w * 0.85)
                            .offset(x: -w * 0.30, y: w * 0.95)
                    }
                    .blur(radius: 60)
                    .drawingGroup()
                }
            }
            .ignoresSafeArea()
            // Purely decorative: it must never be announced or focused.
            .accessibilityHidden(true)
    }

    private func blob(_ color: Color, opacity: Double, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
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

#Preview {
    AppShell()
}
