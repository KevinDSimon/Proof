import AppKit
import ProofUI
import SwiftUI

extension LibraryPlatform {
    /// The library's system calls on the Mac, through AppKit.
    static let mac = LibraryPlatform(
        clickModifiers: {
            // The click's own modifiers, rather than the keys held now, which can differ by the
            // time a tap gesture ends.
            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            var modifiers: EventModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            return modifiers
        },
        beep: { NSSound.beep() },
        revealFiles: { NSWorkspace.shared.activateFileViewerSelecting($0) },
        openFolder: { NSWorkspace.shared.open($0) },
        copyString: { string in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        },
        observe: { handler in
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { handler(.volumesChanged) }
                }
            }
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(.becameActive) }
            }
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(.willTerminate) }
            }
        }
    )
}

extension DoubleClickCheck {
    /// The click count of the press AppKit is handling, and the person's double-click speed.
    static let mac = DoubleClickCheck(interval: NSEvent.doubleClickInterval) {
        NSApp.currentEvent.map { $0.type == .leftMouseDown && $0.clickCount == 2 } ?? false
    }
}

extension EditKeyWatch {
    /// A local event monitor rather than keyboard focus: a custom view on the Mac only takes focus
    /// by click with keyboard navigation turned on, so focus-based key handling doesn't reach it
    /// for most people. Keys typed into a text field pass through.
    static let mac = EditKeyWatch { frame, clickOutside, key in
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            if event.type == .leftMouseDown {
                if let content = event.window?.contentView {
                    let location = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                    if !frame().contains(location) { clickOutside() }
                }
                return event
            }
            guard event.window?.firstResponder as? NSText == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let shift = event.modifierFlags.contains(.shift)
            let editKey: EditKey? = switch event.keyCode {
            case 51, 117: .delete
            case 123: .left
            case 124: .right
            case 125: .down
            case 126: .up
            default: nil
            }
            guard let editKey else { return event }
            return key(editKey, shift) ? nil : event
        }
        return { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension View {
    /// The Mac's own controls for the shared inspector and crop tool: AppKit's pop-up buttons, its
    /// click count, the keys a selected curve point answers to, the pointer that says a point
    /// will go, and the pointer that turns the photo outside a crop corner.
    func macInspectorControls() -> some View {
        environment(\.doubleClickCheck, .mac)
            .environment(\.rotatePointer) { corner in Image(nsImage: RotateCursor.image(for: corner)) }
            .environment(\.editKeyWatch, .mac)
            .environment(\.popUpMenu) { title, items in AnyView(MenuPopUp(title: title, items: items)) }
            .environment(\.showsRemovalPointer) { removing in
                if removing { NSCursor.disappearingItem.push() } else { NSCursor.pop() }
            }
    }
}
