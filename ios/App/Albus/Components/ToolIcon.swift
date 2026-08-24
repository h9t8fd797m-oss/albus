import SwiftUI
import AlbusCore

/// A tool's mark: its real logo, or nothing.
///
/// This used to give every tool a tint picked from the app's palette and colour
/// an SF Symbol with it. That was wrong in the way that is hardest to unsee — a
/// brand colour the app invented is a claim about someone else's identity, and
/// two hundred of them read as a build where nobody checked.
///
/// So: if real artwork is bundled (`logo-<id>`), it is drawn untouched on a
/// neutral card — no tint, no template rendering, no monochrome treatment. If it
/// is not, the tool falls back to a shape in muted ink that says what the tool is
/// *for* and claims no colour at all.
struct ToolIcon: View {
    let tool: StudyTool
    var side: CGFloat = 34
    var cornerRadius: CGFloat = 9

    var body: some View {
        Group {
            if let artwork = ToolArtwork.image(for: tool) {
                // `.original` matters: a template render would recolour the logo,
                // which is the whole thing this file exists to prevent.
                artwork
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .padding(side * 0.16)
            } else {
                Image(systemName: tool.symbolName)
                    .font(.system(size: side * 0.42, weight: .regular))
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
        }
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

    /// How many tools ship with real artwork. Used by tests and by the Tools
    /// header, so the number shown is measured rather than asserted.
    static var bundledCount: Int {
        StudyTool.allCases.count { image(for: $0) != nil }
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
