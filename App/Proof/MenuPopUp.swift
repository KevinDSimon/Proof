import AppKit
import SwiftUI

/// A full-width pop-up button, as in Finder's settings: a filled control with up and down arrows,
/// showing `title`, whose menu can hold submenus. SwiftUI's pickers and menus in an inspector form
/// draw as plain text with a chevron instead, so this is AppKit's `NSPopUpButton`.
struct MenuPopUp: NSViewRepresentable {
    /// An item in the menu: a command, a checked choice, a submenu, or a separator.
    indirect enum Item {
        case action(String, isChecked: Bool = false, perform: () -> Void)
        case submenu(String, [Item])
        case separator
    }

    let title: String
    let items: [Item]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        // Shows `title` rather than the chosen item, which may be inside a submenu or absent.
        (button.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        // Lets SwiftUI stretch it across the row.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let menu = NSMenu()
        context.coordinator.actions = []
        for item in items { menu.addItem(context.coordinator.menuItem(for: item)) }
        button.menu = menu
        (button.cell as? NSPopUpButtonCell)?.menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityValue(title)
    }

    @MainActor
    final class Coordinator: NSObject {
        var actions: [() -> Void] = []

        func menuItem(for item: Item) -> NSMenuItem {
            switch item {
            case .separator:
                return .separator()
            case .action(let title, let isChecked, let perform):
                let menuItem = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = actions.count
                menuItem.state = isChecked ? .on : .off
                actions.append(perform)
                return menuItem
            case .submenu(let title, let items):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                for item in items { submenu.addItem(self.menuItem(for: item)) }
                menuItem.submenu = submenu
                return menuItem
            }
        }

        @objc func run(_ sender: NSMenuItem) {
            actions[sender.tag]()
        }
    }
}
