import SwiftUI
import AlbusCore

/// The chrome every Albus popup shares.
///
/// `AddTaskSheet` and `RubricEditorSheet` used a bare `NavigationStack { Form
/// { ... } }` with a system Cancel/Save toolbar — the default grouped-list
/// look, indistinguishable from any other app's settings screen. The Albus AI
/// design folder has the intended shape for this
/// (`2 Design Exports/Add Task Flow.png`, sourced from `1 Prototype/plus-flow.jsx`):
/// a hand-drawn drag handle, an eyebrow over a big friendly question, fields in
/// their own bordered cards, and one primary action pinned to the bottom —
/// never a system list or alert.
///
/// A new popup should build on this rather than reach for `Form`.
struct AlbusSheetScaffold<Content: View>: View {
    let eyebrow: String
    let title: String
    var primaryTitle: String?
    var isPrimaryEnabled: Bool = true
    var primaryAction: (() -> Void)?
    /// Nil hides the close button — for a small nested popup where the sheet's
    /// own swipe-to-dismiss is enough and a second control would be clutter.
    var onCancel: (() -> Void)?
    /// Overridable in one place. A caller that also applied its own
    /// `.presentationDetents` on top of this view had two conflicting
    /// declarations reach the same `.sheet` — undefined which one won, and in
    /// practice it produced a sheet whose touch handling silently broke rather
    /// than one that just looked wrong.
    var detents: Set<PresentationDetent> = [.medium, .large]
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Tokens.Palette.hairline)
                .frame(width: 40, height: 4)
                .padding(.top, Tokens.Spacing.s)

            header

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                    content
                }
                .padding(.horizontal, Tokens.Spacing.xl)
                .padding(.top, Tokens.Spacing.s)
                .padding(.bottom, Tokens.Spacing.m)
            }
            .scrollDismissesKeyboard(.interactively)

            if let primaryTitle, let primaryAction {
                PrimaryButton(title: primaryTitle, isEnabled: isPrimaryEnabled, action: primaryAction)
                    .padding(.horizontal, Tokens.Spacing.xl)
                    .padding(.top, Tokens.Spacing.s)
                    .padding(.bottom, Tokens.Spacing.l)
                    .background(
                        // A hairline only where there's something to separate
                        // from — content scrolled under the button, not empty
                        // space.
                        Tokens.Palette.hairline.frame(height: 0.5),
                        alignment: .top
                    )
            }
        }
        .background(Tokens.Palette.backgroundStops[0].color)
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(Tokens.Radius.sheet)
        .presentationDetents(detents)
    }

    private var header: some View {
        SheetHeader(eyebrow: eyebrow, title: title, onCancel: onCancel)
    }
}

/// The eyebrow + headline + close button on their own, for a popup that needs
/// the same top chrome but not `AlbusSheetScaffold`'s `ScrollView` body — a
/// screen built around a `List` (for row reordering, say) supplies its own
/// scrollable content and just wants this on top of it.
struct SheetHeader: View {
    let eyebrow: String
    let title: String
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased())
                    .font(Tokens.Typography.overline)
                    .tracking(Tokens.Tracking.dateline)
                    .foregroundStyle(Tokens.Palette.inkMuted)
                Text(title)
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Spacing.s)
            if let onCancel {
                IconButton(systemImage: "xmark", accessibilityLabel: "Close", action: onCancel)
            }
        }
        .padding(.horizontal, Tokens.Spacing.xl)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.xs)
    }
}

/// One field, in the sheet's own chrome: an overline label above a bordered
/// white card — never a `Form` row.
struct SheetField<Content: View>: View {
    var label: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            if let label {
                Text(label.uppercased())
                    .font(Tokens.Typography.micro)
                    .tracking(Tokens.Tracking.overline)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
            content
                .padding(Tokens.Spacing.m)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .background(Tokens.Palette.cardSurface,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: 1)
                }
        }
    }
}

/// A tap-to-choose field styled like every other row in the sheet.
///
/// This was a raw `Menu` with a hand-drawn trigger, which was the wrong call:
/// anchored deep inside `ScrollView → .sheet`, its popover rendered as a small,
/// mis-sized card — one option visible, the rest clipped and untappable.
/// Reproduced on device, not just suspected. A `Picker` with `.menuStyle` is
/// Apple's own implementation of the identical interaction — tap a row, see the
/// current value, get a list — and it doesn't carry the same bug because
/// nothing here is hand-rolling the popover any more. `SheetField` still draws
/// the card, so it looks like the rest of the sheet either way.
struct SheetPicker<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        SheetField(label: label) {
            Picker(selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Tokens.Palette.ink)
            // Left-aligned rather than stretched: a `.menu`-style Picker's tap
            // target is its own intrinsic content — `.contentShape` on the
            // frame around it does not extend it, tried and confirmed on
            // device. The card stays full width for visual consistency with
            // the rest of the sheet; only the value + chevron itself responds
            // to a tap, which is exactly how this control behaves inline
            // everywhere else in iOS.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// Un-defaults one `List` row: no separator, no grouped-list background,
    /// horizontal room matching the rest of the sheet. Keeps `.onDelete` /
    /// `.onMove` working — only `List` gives you those — while everything a
    /// student can actually see stops reading as a system list.
    func sheetRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: Tokens.Spacing.xs, leading: Tokens.Spacing.xl,
                                      bottom: Tokens.Spacing.xs, trailing: Tokens.Spacing.xl))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
