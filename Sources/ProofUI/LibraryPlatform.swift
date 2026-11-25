import Foundation
import SwiftUI

/// The few things `Library` needs from the system that differ between macOS and iOS. Each app
/// passes its own when it makes the library, so `ProofUI` never imports AppKit or UIKit.
public struct LibraryPlatform: Sendable {
    /// A change in the system that the library follows.
    public enum Event: Sendable {
        /// A drive or share connected or disconnected.
        case volumesChanged
        /// Proof became the active app.
        case becameActive
        /// Proof is about to quit.
        case willTerminate
    }

    /// The modifier keys of the click being handled.
    public var clickModifiers: @MainActor () -> EventModifiers
    /// Signals that an action couldn't be done.
    public var beep: @MainActor () -> Void
    /// Shows the files in the system's file browser, selected.
    public var revealFiles: @MainActor ([URL]) -> Void
    /// Opens a folder in the system's file browser.
    public var openFolder: @MainActor (URL) -> Void
    /// Puts text on the pasteboard.
    public var copyString: @MainActor (String) -> Void
    /// Starts calling the handler with each `Event`, on the main thread.
    public var observe: @MainActor (_ handler: @escaping @MainActor (Event) -> Void) -> Void

    public init(clickModifiers: @escaping @MainActor () -> EventModifiers,
                beep: @escaping @MainActor () -> Void,
                revealFiles: @escaping @MainActor ([URL]) -> Void,
                openFolder: @escaping @MainActor (URL) -> Void,
                copyString: @escaping @MainActor (String) -> Void,
                observe: @escaping @MainActor (_ handler: @escaping @MainActor (Event) -> Void) -> Void) {
        self.clickModifiers = clickModifiers
        self.beep = beep
        self.revealFiles = revealFiles
        self.openFolder = openFolder
        self.copyString = copyString
        self.observe = observe
    }
}
