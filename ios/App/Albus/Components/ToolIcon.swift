import SwiftUI
import AlbusCore

/// A tool's mark: its real logo, or nothing at all.
///
/// This used to give every tool a tint from the app's palette and colour an SF
/// Symbol with it. That is wrong in the way that is hardest to unsee — a brand
/// colour the app invented is a claim about someone else's identity, and two
/// hundred of them read as a build where nobody checked.
///
/// So the rule is: real artwork, drawn untouched, or no mark. Not a letter, not
/// a stand-in glyph, not a colour we chose. `logos/` holds what
/// `scripts/tools/fetch_logos.py` could find; the rest of the catalogue shows
/// its name and nothing else, which is honest and looks deliberate.
struct ToolIcon: View {
    let tool: StudyTool
    var side: CGFloat = 34
    var cornerRadius: CGFloat = 9

    var body: some View {
        // No frame in the empty case, so a card without a logo closes the gap
        // rather than leaving a hole where a mark should be.
        if let artwork = ToolArtwork.image(for: tool) {
            artwork
                .resizable()
                // `.original` matters: a template render would recolour the
                // logo, which is the whole thing this file exists to prevent.
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .padding(side * 0.14)
                .frame(width: side, height: side)
                .background(Tokens.Palette.cardSurface,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        }
    }
}

/// Resolves and remembers which tools have bundled artwork.
///
/// `UIImage(named:)` hits the filesystem on a miss as well as a hit, and the
/// Tools grid asks about every visible tile on every scroll frame. One lookup
/// per tool, remembered, turns that into nothing.
@MainActor
enum ToolArtwork {
    private static var cache: [StudyTool: Image?] = [:]

    static func image(for tool: StudyTool) -> Image? {
        if let cached = cache[tool] { return cached }
        let resolved = UIImage(named: tool.logoAssetName).map(Image.init(uiImage:))
        cache[tool] = resolved
        return resolved
    }

    static func has(_ tool: StudyTool) -> Bool { image(for: tool) != nil }

    /// How many tools ship with real artwork. Measured, not asserted — a broken
    /// asset-naming convention would otherwise show up as a silently logo-less
    /// app rather than as a failing test.
    static var bundledCount: Int {
        StudyTool.allCases.count { has($0) }
    }
}

#Preview("Tool icons") {
    ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6),
                  spacing: Tokens.Spacing.m) {
            ForEach(StudyTool.allCases) { tool in
                VStack(spacing: 4) {
                    ToolIcon(tool: tool)
                    Text(tool.name)
                        .font(.system(size: 7))
                        .lineLimit(1)
                        .foregroundStyle(Tokens.Palette.inkMuted)
                }
            }
        }
        .padding()
    }
    .background(BackgroundGradient())
}
