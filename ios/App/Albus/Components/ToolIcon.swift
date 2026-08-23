import SwiftUI
import AlbusCore

/// A tool's mark.
///
/// Prefers real brand artwork — an image asset named `logo-<tool id>` — and
/// falls back to the tool's SF Symbol when none is bundled. Today nothing is
/// bundled, so every tool shows its symbol; adding logos later means dropping
/// files into the asset catalogue and changing no code at all.
///
/// The symbol is chosen to say what the tool is *for*, which is why this reads
/// as an icon set rather than the initials it replaced.
struct ToolIcon: View {
    let tool: StudyTool
    var side: CGFloat = 34
    var cornerRadius: CGFloat = 9

    /// Asset lookup is cheap but not free, and this renders in a grid of 200.
    /// Resolving once per tool and caching keeps scrolling smooth.
    private var artwork: Image? {
        ToolArtwork.image(for: tool)
    }

    var body: some View {
        Group {
            if let artwork {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(side * 0.18)
            } else {
                Image(systemName: tool.symbolName)
                    .font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(tool.tint.foreground)
            }
        }
        .frame(width: side, height: side)
        .background(tool.tint.background,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Resolves and remembers which tools have bundled artwork.
///
/// `UIImage(named:)` hits the filesystem on a miss as well as a hit, and the
/// Tools grid asks about every visible tile on every scroll frame. One lookup
/// per tool, remembered, turns that into nothing.
@MainActor
private enum ToolArtwork {
    private static var cache: [StudyTool: Image?] = [:]

    static func image(for tool: StudyTool) -> Image? {
        if let cached = cache[tool] { return cached }
        let resolved = UIImage(named: tool.logoAssetName).map(Image.init(uiImage:))
        cache[tool] = resolved
        return resolved
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
