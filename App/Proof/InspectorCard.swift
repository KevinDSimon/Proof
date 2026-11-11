import ProofKit
import SwiftUI

/// One group of the inspector as a card with its title inside, as Pixelmator Pro lays out its
/// adjustments on iPhone and iPad. Reset sits beside an optional switch; turning the switch off
/// closes the card, and what that means for the photo is up to the caller. The cards are laid out
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

    var body: some View {
        VStack(alignment: .leading, spacing: Self.controlSpacing) {
            if let title { header(title) }
            if isOn?.wrappedValue ?? true {
                content()
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color(white: Self.fillGray(for: colorScheme))))
    }

    private func header(_ title: String) -> some View {
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
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!canReset)
                    .accessibilityLabel("Reset \(title)")
            }
            if let isOn {
                Toggle(title, isOn: Binding(get: { isOn.wrappedValue },
                                            set: { value in withAnimation(.snappy(duration: 0.2)) { isOn.wrappedValue = value } }))
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
    }

    /// The card's gray, a step lighter than the canvas in the dark appearance and darker in the light.
    /// Neutral grays match in Display P3 and sRGB, like the canvas's own.
    static func fillGray(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.18 : 0.95
    }
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
