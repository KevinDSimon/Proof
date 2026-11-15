import ProofKit
import SwiftUI

/// One group of the inspector as a card with its title inside, as Pixelmator Pro lays out its
/// adjustments on iPhone and iPad. Reset sits beside an optional switch; turning the switch off
/// closes the card, and what that means for the photo is up to the caller. In a panel that sets
/// `foldedCards`, a titled card also has a disclosure arrow that folds it. The cards are laid out
/// by hand rather than as a grouped `Form`, which on macOS removes the filled background from
/// pop-up buttons inside it.
struct InspectorCard<Content: View>: View {
    /// Space between cards.
    static var spacing: CGFloat { 16 }
    /// Space between the controls inside a card, and around them.
    static var controlSpacing: CGFloat { 14 }
    static var padding: CGFloat { 16 }
    /// About the grouped form's cards on macOS 26, which these replace.
    static var cornerRadius: CGFloat { 14 }
    /// The names of controls inside a card: between the primary and secondary label colors, which
    /// macOS has no stop for, so the card's title reads first but the names don't look dull.
    static var labelColor: Color { Color.primary.opacity(0.75) }

    var title: String?
    var isOn: Binding<Bool>?
    var canReset = false
    var reset: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.foldedCards) private var foldedCards

    var body: some View {
        Group {
            if let title, let foldedCards {
                // The same disclosure arrow as the Info card. It folds the card apart from the
                // switch; unfolding a card that is off turns it on, since an off card shows nothing.
                let isExpanded = Binding(
                    get: { foldedCards.wrappedValue.isExpanded(title, isOn: isOn?.wrappedValue ?? true) },
                    set: { expanded in
                        withAnimation(.snappy(duration: 0.2)) {
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
            .fill(Color(white: Self.fillGray(for: colorScheme))))
    }

    /// `fold`, when given, runs on a click anywhere in the row but Reset and the switch, so the
    /// title and the space beside it fold the card as well as the small arrow does.
    private func header(_ title: String, fold: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                // One line, ahead of the buttons, so "White Balance" doesn't wrap beside Reset.
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let reset {
                // A small bordered button, so it reads as a control beside the title and the switch.
                Button("Reset", action: reset)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!canReset)
                    .accessibilityLabel("Reset \(title)")
            }
            if let isOn {
                Toggle(title, isOn: Binding(get: { isOn.wrappedValue },
                                            set: { value in
                                                withAnimation(.snappy(duration: 0.2)) {
                                                    isOn.wrappedValue = value
                                                    // Turning a card on opens it, so its controls show.
                                                    if value { foldedCards?.wrappedValue.setFolded(title, false) }
                                                }
                                            }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    // Green, as on iPhone and iPad: without a tint the switch is white either
                    // way, and on and off are hard to tell apart.
                    .tint(.green)
                    .labelsHidden()
                    .help(isOn.wrappedValue ? "Turn off to see the photo without these adjustments" : "Turn on")
                    .accessibilityLabel(title)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { fold?() }
    }

    /// The card's gray, a step lighter than the canvas in the dark appearance and darker in the light.
    /// Neutral grays match in Display P3 and sRGB, like the canvas's own.
    static func fillGray(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.18 : 0.95
    }
}

/// A control with its name above it, as the sliders have theirs, so every name in a card starts
/// at the same edge and reads down one column. `status` sits at the end of the name's line, such
/// as a spinner or a short note, so it never adds a line and moves what follows.
struct InspectorField<Content: View, Status: View>: View {
    let title: String
    @ViewBuilder var status: () -> Status
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder status: @escaping () -> Status = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.status = status
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(InspectorCard<EmptyView>.labelColor)
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

extension EnvironmentValues {
    /// Which cards are folded, for a panel whose titled cards can fold; `nil` where they can't.
    @Entry var foldedCards: Binding<FoldedCards>? = nil
}

extension Library {
    /// A card's switch for `group`.
    func isOnBinding(_ group: AdjustmentGroup) -> Binding<Bool> {
        Binding(get: { self.isOn(group) }, set: { self.setOn(group, $0) })
    }
}

/// The inspector's cards in a scrolling column on the canvas's own gray, 16 pt from every edge,
/// so the panel and the photo read as one surface.
struct InspectorPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: InspectorCard<EmptyView>.spacing) {
                content()
            }
            .padding(16)
        }
        .background(Color(white: PhotoCanvas.backdropGray(for: colorScheme)).ignoresSafeArea())
    }
}
