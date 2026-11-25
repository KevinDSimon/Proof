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
