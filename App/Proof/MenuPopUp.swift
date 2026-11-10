import AppKit
import SwiftUI

/// A full-width pull-down button showing `title`, whose menu can hold submenus. SwiftUI's `Menu`
/// in an inspector form sizes to its title; AppKit's `NSPopUpButton` stretches across the row.
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
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        // Lets SwiftUI stretch it across the row.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let menu = NSMenu()
        // A pull-down's first item is the title it shows, not a choice.
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        context.coordinator.actions = []
        for item in items { menu.addItem(context.coordinator.menuItem(for: item)) }
        button.menu = menu
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
