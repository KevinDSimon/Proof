import SwiftUI

/// A full-width menu button showing `title`, whose menu can hold checked choices, submenus and
/// separators. SwiftUI's menus in a Mac inspector draw as plain text with a chevron, so the Mac
/// app draws AppKit's pop-up button through `\.popUpMenu`; elsewhere this is a standard `Menu`.
public struct PopUpMenu: View {
    /// An item in the menu: a command, a checked choice, a submenu, or a separator.
    public indirect enum Item {
        case action(String, isChecked: Bool = false, perform: @MainActor () -> Void)
        case submenu(String, [Item])
        case separator
    }

    let title: String
    let items: [Item]
    @Environment(\.popUpMenu) private var platformMenu

    public init(title: String, items: [Item]) {
        self.title = title
        self.items = items
    }

    public var body: some View {
        if let platformMenu {
            platformMenu(title, items)
        } else {
            Menu {
                Self.content(items)
            } label: {
                HStack {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityValue(title)
        }
    }

    private static func content(_ items: [Item]) -> AnyView {
        AnyView(ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .separator:
                Divider()
            case .action(let title, let isChecked, let perform):
                // A toggle, so the chosen item has the system's checkmark.
                Toggle(title, isOn: Binding(get: { isChecked }, set: { _ in perform() }))
            case .submenu(let title, let items):
                Menu(title) { content(items) }
            }
        })
    }
}

/// The keys a selected item in the inspector answers to, such as a point on the curve.
public enum EditKey: Sendable {
    case delete, left, right, up, down
}

/// Watches the keyboard, and clicks outside a frame, while something in the inspector is
/// selected. On the Mac a custom view only takes keyboard focus by click with keyboard navigation
/// turned on, so the Mac app watches AppKit's events instead; elsewhere nothing is watched.
public struct EditKeyWatch: Sendable {
    /// Starts watching, and returns what stops it. `frame` is the selected view's frame in the
    /// window; a click outside it calls `clickOutside`. `key` returns whether it used the key,
    /// with whether Shift was held.
    public var start: @MainActor @Sendable (
        _ frame: @escaping @MainActor () -> CGRect,
        _ clickOutside: @escaping @MainActor () -> Void,
        _ key: @escaping @MainActor (EditKey, _ shift: Bool) -> Bool
    ) -> @MainActor () -> Void

    public init(start: @escaping @MainActor @Sendable (
        _ frame: @escaping @MainActor () -> CGRect,
        _ clickOutside: @escaping @MainActor () -> Void,
        _ key: @escaping @MainActor (EditKey, _ shift: Bool) -> Bool
    ) -> @MainActor () -> Void) {
        self.start = start
    }

    public static let none = EditKeyWatch { _, _, _ in {} }
}

public extension EnvironmentValues {
    /// The Mac's pop-up button for `PopUpMenu`; `nil` for SwiftUI's `Menu`.
    @Entry var popUpMenu: (@MainActor @Sendable (String, [PopUpMenu.Item]) -> AnyView)? = nil
    @Entry var editKeyWatch = EditKeyWatch.none
    /// Shows or hides the pointer that says a dragged item will be removed when released. Touch
    /// has no pointer; the item disappears from under the finger instead.
    @Entry var showsRemovalPointer: @MainActor @Sendable (Bool) -> Void = { _ in }
}
