import SwiftUI
import AlbusCore

/// The tool library: what to open, and when it helps.
///
/// Two hundred-odd tools is too many to scroll, so the screen is built around
/// finding one: search first, categories second, and a count so the size of the
/// library is legible rather than overwhelming.
struct ToolsScreen: View {
    @Environment(\.openURL) private var openURL

    @State private var category: StudyTool.Category = .all
    @State private var query = ""
    @State private var confirming: StudyTool?

    private var visible: [StudyTool] {
        StudyTool.allCases.filter {
            (category == .all || $0.category == category) && $0.matches(query)
        }
    }

    /// Search cuts across categories, so grouping the results keeps them
    /// readable when a query spans several.
    private var grouped: [(StudyTool.Category, [StudyTool])] {
        let byCategory = Dictionary(grouping: visible, by: \.category)
        return StudyTool.Category.allCases
            .filter { $0 != .all }
            .compactMap { key in
                guard let tools = byCategory[key], !tools.isEmpty else { return nil }
                return (key, tools)
            }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header

                // First, always, and never inside the grid.
                //
                // `StudyTool` is a catalogue of external URLs — every entry
                // opens Safari, and its own doc comment is explicit that every
                // destination is a compile-time constant. Albus Grader has no
                // URL and opens a screen, so it is not a case in that enum and
                // is not filtered by the category chips or the search field: it
                // is the app's own tool, not a link to somebody else's.
                if query.isEmpty && (category == .all || category == .writing) {
                    albusGraderCard
                }

                searchField

                FilterChipRow(filters: StudyTool.Category.allCases, selection: $category) {
                    $0.title
                }
                .padding(.horizontal, -Tokens.Spacing.xl)

                if visible.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "Nothing matches",
                               message: "Try a subject, or what you're trying to do — \"cite\", \"graph\", \"focus\".")
                } else {
                    ForEach(grouped, id: \.0) { key, tools in
                        SectionHeader(key.title, count: tools.count)
                            .padding(.top, Tokens.Spacing.xs)
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: Tokens.Spacing.m),
                                      GridItem(.flexible(), spacing: Tokens.Spacing.m)],
                            spacing: Tokens.Spacing.m
                        ) {
                            ForEach(tools) { tool in
                                ToolCard(tool: tool) { confirming = tool }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        // Leaving the app is a visible step, not a side effect of a tap — and
        // the host is named, so a student always knows where they are going.
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
                Text("\(tool.host) — \(tool.reason)")
            }
        }
    }

    /// The one first-party entry in a screen full of other people's software.
    private var albusGraderCard: some View {
        NavigationLink {
            Screen { GraderScreen() }
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                // The mascot, not a letter and not an SF Symbol. Every other
                // tile here shows a real logo or nothing; this one is ours, so
                // it shows the thing the app is.
                AlbusCactus(size: 44, mood: .busy)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text("Albus Grader")
                            .font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text("BY ALBUS")
                            .font(Tokens.Typography.overline)
                            .fontWeight(.bold)
                            .foregroundStyle(Tokens.Palette.accent)
                            .padding(.horizontal, Tokens.Spacing.xs)
                            .padding(.vertical, 2)
                            .background(Tokens.Palette.accentWash, in: Capsule())
                    }
                    Text("Mark finished work against your own rubric, and see where every mark went.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
            .padding(Tokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(alignment: .leading) {
                Rectangle().fill(Tokens.Palette.accent).frame(width: 4)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("YOUR TOOLKIT")
                .font(Tokens.Typography.overline)
                .tracking(Tokens.Tracking.dateline)
                .foregroundStyle(Tokens.Palette.inkMuted)
            Text("Tools")
                .font(Tokens.Typography.displayLarge)
                .tracking(Tokens.Tracking.display)
                .foregroundStyle(Tokens.Palette.ink)
            Text("\(StudyTool.allCases.count) tools. Albus picks from all of them inside a step, by what the step is for.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Tokens.Spacing.s)
    }

    private var searchField: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.Palette.inkMuted)
            TextField("Search tools", text: $query)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Tokens.Palette.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .frame(height: 44)
        .background(Tokens.Glass.fill,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
        }
    }

    private struct ToolCard: View {
        let tool: StudyTool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                GlassCard(padding: Tokens.Spacing.m) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        // Nothing at all when no logo is bundled: the name is
                        // already the loudest thing on the card, and a made-up
                        // mark would be worse than an honest gap.
                        ToolIcon(tool: tool)
                        Text(tool.name)
                            .font(Tokens.Typography.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(Tokens.Palette.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Text(tool.reason)
                            .font(Tokens.Typography.micro)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(tool.name). \(tool.reason)")
            .accessibilityHint("Opens \(tool.host) in Safari")
        }
    }
}
