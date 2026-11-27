import ProofKit
import SwiftUI

/// One group of the inspector as a card with its title inside, as Pixelmator Pro lays out its
/// adjustments on iPhone and iPad. Reset sits beside an optional switch; turning the switch off
/// closes the card, and what that means for the photo is up to the caller. In a panel that sets
/// `foldedCards`, a titled card also has a disclosure arrow that folds it. The cards are laid out
/// by hand rather than as a grouped `Form`, which on macOS removes the filled background from
/// pop-up buttons inside it.
public struct InspectorCard<Content: View>: View {
    /// Space between cards.
    public static var spacing: CGFloat { 16 }
    /// Space between the controls inside a card, and around them.
    public static var controlSpacing: CGFloat { 14 }
    public static var padding: CGFloat { 16 }
    /// About the grouped form's cards on macOS 26, which these replace.
    public static var cornerRadius: CGFloat { 14 }
    /// The names of controls inside a card: between the primary and secondary label colors, which
    /// macOS has no stop for, so the card's title reads first but the names don't look dull.
    public static var labelColor: Color { Color.primary.opacity(0.75) }

    var title: String?
    var isOn: Binding<Bool>?
    var canReset = false
    var reset: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isInspectorSheet) private var isInspectorSheet
    @Environment(\.foldedCards) private var foldedCards
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(title: String? = nil, isOn: Binding<Bool>? = nil, canReset: Bool = false, reset: (() -> Void)? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isOn = isOn
        self.canReset = canReset
        self.reset = reset
        self.content = content
    }

    public var body: some View {
        Group {
            if let title, let foldedCards {
                // The same disclosure arrow as the Info card. It folds the card apart from the
                // switch; unfolding a card that is off turns it on, since an off card shows nothing.
                let isExpanded = Binding(
                    get: { foldedCards.wrappedValue.isExpanded(title, isOn: isOn?.wrappedValue ?? true) },
                    set: { expanded in
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            foldedCards.wrappedValue.setFolded(title, !expanded)
                            if expanded { isOn?.wrappedValue = true }
                        }
                    })
                DisclosureGroup(isExpanded: isExpanded) {
                    VStack(alignment: .leading, spacing: Self.controlSpacing) {
                        content()
                    }
                    .padding(.top, Self.controlSpacing)
                } label: {
                    header(title) { isExpanded.wrappedValue.toggle() }
                }
            } else {
                VStack(alignment: .leading, spacing: Self.controlSpacing) {
                    if let title { header(title) }
                    if isOn?.wrappedValue ?? true {
                        content()
                    }
                }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color(white: isInspectorSheet ? Self.sheetFillGray : Self.fillGray(for: colorScheme))))
    }

    /// `fold`, when given, runs on a click anywhere in the row but Reset and the switch, so the
    /// title and the space beside it fold the card as well as the small arrow does.
    private func header(_ title: String, fold: (() -> Void)? = nil) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At the accessibility text sizes the title takes its own line, with Reset and the
                // switch under it, since the three don't fit across the card.
                VStack(alignment: .leading, spacing: 8) {
                    headerTitle(title)
                    HStack(spacing: 8) {
                        Spacer()
                        headerControls(title)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    headerTitle(title)
                        // One line, ahead of the buttons, so "White Balance" doesn't wrap beside Reset.
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer()
                    headerControls(title)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { fold?() }
    }

    private func headerTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func headerControls(_ title: String) -> some View {
        if let reset {
            // A small bordered button, so it reads as a control beside the title and the switch.
            Button("Reset", action: reset)
                #if os(macOS)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                #else
                // iOS's disabled bordered button is a near-black fill with unreadable text on
                // the card's gray; Reset is disabled on most cards, so it must stay legible.
                .buttonStyle(ResetButtonStyle())
                #endif
                .fixedSize()
                .disabled(!canReset)
                .accessibilityLabel("Reset \(title)")
        }
        if let isOn {
            Toggle(title, isOn: Binding(get: { isOn.wrappedValue },
                                        set: { value in
                                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                                isOn.wrappedValue = value
                                                // Turning a card on opens it, so its controls show.
                                                if value { foldedCards?.wrappedValue.setFolded(title, false) }
                                            }
                                        }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                // Without a tint the switch is white either way, and on and off are hard
                // to tell apart.
                .tint(.highlight)
                .labelsHidden()
                .help(isOn.wrappedValue ? "Turn off to see the photo without these adjustments" : "Turn on")
                .accessibilityLabel(title)
        }
    }

    /// The card's gray, a step lighter than the canvas in the dark appearance and darker in the light.
    /// Neutral grays match in Display P3 and sRGB, like the canvas's own.
    nonisolated public static func fillGray(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.18 : 0.95
    }

    /// The card's gray in the iPhone sheet: a step darker than the sheet, and a little lighter
    /// than the canvas, so the cards don't read as holes in it.
    static var sheetFillGray: Double { 0.15 }
}

/// A control with its name above it, as the sliders have theirs, so every name in a card starts
/// at the same edge and reads down one column. `status` sits at the end of the name's line, such
/// as a spinner or a short note, so it never adds a line and moves what follows.
public struct InspectorField<Content: View, Status: View>: View {
    let title: String
    @ViewBuilder var status: () -> Status
    @ViewBuilder var content: () -> Content

    public init(_ title: String, @ViewBuilder status: @escaping () -> Status = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.status = status
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .inspectorLabelStyle()
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                status()
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
            }
            content()
        }
    }
}

public extension EnvironmentValues {
    /// Which cards are folded, for a panel whose titled cards can fold; `nil` where they can't.
    @Entry var foldedCards: Binding<FoldedCards>? = nil
}

public extension Library {
    /// A card's switch for `group`.
    func isOnBinding(_ group: AdjustmentGroup) -> Binding<Bool> {
        Binding(get: { self.isOn(group) }, set: { self.setOn(group, $0) })
    }
}

/// The inspector's cards in a scrolling column on the interface's dark gray, 16 pt from every edge.
public struct InspectorPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.isInspectorSheet) private var isInspectorSheet

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: InspectorCard<EmptyView>.spacing) {
                content()
            }
            .padding(16)
        }
        #if !os(macOS)
        // On iPad the panel is one column of several under the toolbar, and only it scrolls, so
        // the soft edge's blur of the cards showed over this column alone. The cards stop at the
        // bar instead, as the photo beside them does; the gray behind them still runs under it.
        .scrollEdgeEffectHidden(true, for: .top)
        .clipped()
        #endif
        .background((isInspectorSheet ? Color.sheetBackground : Color.interfaceBackground).ignoresSafeArea())
        #if !os(macOS)
        // iOS draws buttons, menus and the cards' headers in the app's accent color, the
        // highlight, which is for small marks of state only (decision 0041). White, not
        // `.primary`: the interface is always dark, and disabled buttons drew `.primary` as a
        // black fill with unreadable text. The switches set their own.
        .tint(.white)
        #endif
    }
}

#if !os(macOS)
/// The cards' Reset on iOS: a light capsule, as the bordered style is when enabled, whose text
/// dims while there is nothing to reset.
private struct ResetButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.24 : 0.12)))
            // About 30 points tall beside the card's title; taps reach it from 44.
            .minimumTouchTarget()
    }
}
#endif

public extension EnvironmentValues {
    /// Whether the inspector is a sheet below the photo, as on iPhone. There the panel and the
    /// cards swap grays: the sheet takes the cards' lighter gray, so it stands apart from the
    /// canvas above it, and the cards a darker gray near the canvas's.
    @Entry var isInspectorSheet = false
}
