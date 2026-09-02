import SwiftUI
import AlbusCore

/// One compact, explicit control for a nullable IB course level.
///
/// "Not set" is a real option rather than an implicit default: choosing SL on
/// a student's behalf would turn missing context into a false fact.
struct CourseLevelSelector: View {
    @Binding var selection: CourseLevel?
    var accessibilityPrefix: String? = nil

    private struct Option: Identifiable {
        let id: String
        let value: CourseLevel?
        let title: String
    }

    private let options: [Option] = [
        Option(id: "none", value: nil, title: "Not set"),
        Option(id: CourseLevel.sl.rawValue, value: .sl, title: CourseLevel.sl.short),
        Option(id: CourseLevel.hl.rawValue, value: .hl, title: CourseLevel.hl.short)
    ]

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            ForEach(options) { option in
                let selected = selection == option.value
                Button {
                    withAnimation(Tokens.Motion.quick) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(Tokens.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(selected ? .white : Tokens.Palette.inkSecondary)
                        .padding(.horizontal, Tokens.Spacing.s)
                        .frame(height: 32)
                        .background(
                            selected ? AnyShapeStyle(Tokens.Palette.accent)
                                     : AnyShapeStyle(Tokens.Glass.fill),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().strokeBorder(selected ? .clear : Tokens.Palette.hairline,
                                                   lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier(
                    accessibilityPrefix.map { "\($0).\(option.id)" } ?? "courseLevel.\(option.id)"
                )
            }
        }
    }
}
