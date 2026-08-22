import SwiftUI
import AlbusCore

/// The tool library: what to open, and when it helps.
///
/// Every destination is a compile-time constant on `StudyTool`, so nothing a
/// model wrote or a student typed can become a URL this screen opens.
struct ToolsScreen: View {
    @Environment(\.openURL) private var openURL
    @State private var category: StudyTool.Category = .all
    @State private var confirming: StudyTool?

    private var visible: [StudyTool] {
        category == .all ? StudyTool.allCases : StudyTool.allCases.filter { $0.category == category }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header

                FilterChipRow(filters: StudyTool.Category.allCases, selection: $category) {
                    $0.title
                }
                .padding(.horizontal, -Tokens.Spacing.xl)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: Tokens.Spacing.m),
                              GridItem(.flexible(), spacing: Tokens.Spacing.m)],
                    spacing: Tokens.Spacing.m
                ) {
                    ForEach(visible) { tool in
                        ToolCard(tool: tool) { confirming = tool }
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        // Leaving the app is a visible step, not a side effect of a tap.
        .confirmationDialog(
            confirming.map { "Open \($0.name)?" } ?? "",
            isPresented: Binding(get: { confirming != nil },
                                 set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let tool = confirming {
                Button("Open in Safari") { openURL(tool.url) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let tool = confirming {
                Text("\(tool.url.host() ?? tool.url.absoluteString) — \(tool.summary)")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("YOUR TOOLKIT")
                .font(Tokens.Typography.overline)
                .tracking(Tokens.Tracking.overline)
                .foregroundStyle(Tokens.Palette.inkMuted)
            Text("Tools")
                .font(Tokens.Typography.displayLarge)
                .foregroundStyle(Tokens.Palette.ink)
            Text("Albus suggests these inside a step when they fit the work.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Tokens.Spacing.s)
    }

    private struct ToolCard: View {
        let tool: StudyTool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                GlassCard(padding: Tokens.Spacing.m) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        Text(tool.monogram)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tool.tint.foreground)
                            .frame(width: 34, height: 34)
                            .background(tool.tint.background,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                        Text(tool.name)
                            .font(Tokens.Typography.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(Tokens.Palette.ink)
                            .multilineTextAlignment(.leading)

                        Text(tool.summary)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(tool.name). \(tool.summary)")
            .accessibilityHint("Opens \(tool.url.host() ?? "the website") in Safari")
        }
    }
}
