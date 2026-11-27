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
    /// Touch: adds to the view a drag that starts only when the finger moves sideways, leaving
    /// drags up and down to the scroll view around it. SwiftUI's own drag gestures stop a scroll
    /// view from scrolling, and telling the two apart needs UIKit. `nil` where there's no touch.
    public var sidewaysDrag: (@MainActor (AnyView, SidewaysDragActions) -> AnyView)?
    /// Whether the system's Reduce Motion setting is on. Views read it from their environment;
    /// this is for the library's own animations, such as opening a stack from a menu.
    public var reducesMotion: @MainActor () -> Bool
    /// iPhone: a tap in the grid selects a photo and shows its toolbar instead of opening it in
    /// Edit (#292). iPad opens the photo, as the Mac's double-click does.
    public var tapSelectsPhoto: @MainActor () -> Bool
    /// iOS: names a folder for Info the way the Files app does (`FolderLocation`), as its path is
    /// inside the app's storage (#274). `nil` shows the path, as the Mac does.
    public var folderName: (@MainActor (URL) -> String)?

    public init(clickModifiers: @escaping @MainActor () -> EventModifiers,
                beep: @escaping @MainActor () -> Void,
                revealFiles: @escaping @MainActor ([URL]) -> Void,
                openFolder: @escaping @MainActor (URL) -> Void,
                copyString: @escaping @MainActor (String) -> Void,
                observe: @escaping @MainActor (_ handler: @escaping @MainActor (Event) -> Void) -> Void,
                sidewaysDrag: (@MainActor (AnyView, SidewaysDragActions) -> AnyView)? = nil,
                reducesMotion: @escaping @MainActor () -> Bool = { false },
                tapSelectsPhoto: @escaping @MainActor () -> Bool = { false },
                folderName: (@MainActor (URL) -> String)? = nil) {
        self.clickModifiers = clickModifiers
        self.beep = beep
        self.revealFiles = revealFiles
        self.openFolder = openFolder
        self.copyString = copyString
        self.observe = observe
        self.sidewaysDrag = sidewaysDrag
        self.reducesMotion = reducesMotion
        self.tapSelectsPhoto = tapSelectsPhoto
        self.folderName = folderName
    }
}

/// What a sideways drag reports, with points in `coordinateSpace`.
public struct SidewaysDragActions {
    /// While off, the drag never starts.
    public var isEnabled: Bool
    public var coordinateSpace: NamedCoordinateSpace
    public var began: @MainActor (_ start: CGPoint) -> Void
    public var changed: @MainActor (CGPoint) -> Void

    public init(isEnabled: Bool, coordinateSpace: NamedCoordinateSpace, began: @escaping @MainActor (CGPoint) -> Void,
                changed: @escaping @MainActor (CGPoint) -> Void) {
        self.isEnabled = isEnabled
        self.coordinateSpace = coordinateSpace
        self.began = began
        self.changed = changed
    }
}
