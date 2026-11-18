import AppKit

/// Keeps typing in an inspector field from holding on to the keyboard (#203).
///
/// A click outside the field ends the typing, keeping what was typed, so the photo's tools get
/// the keys again. The canvas and the curve aren't responders, so AppKit would leave the field
/// editor in place for a click on them.
///
/// While a tool is open, Return and Esc are its Done and Close or Cancel, and they reach those
/// buttons even from a field being typed in. There, Return keeps the typed value and Esc puts
/// back the text from before typing started; each leaves the field, and only a second press
/// reaches the tool. Sheets and alerts keep their own Return and Esc.
@MainActor
enum TextFieldKeys {
    private static var eventMonitor: Any?
    private static var endObserver: NSObjectProtocol?
    /// The field's text when the first key of this round of typing went down.
    private static var original: String?

    /// Starts watching for the rest of the app's life. `isToolOpen` says whether Return and Esc
    /// would reach a tool's buttons.
    static func watch(isToolOpen: @escaping @MainActor () -> Bool) {
        guard eventMonitor == nil else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: NSText.didEndEditingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { original = nil }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            guard let window = event.window, window.sheetParent == nil, !(window is NSPanel),
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor
            else { return event }
            if event.type == .leftMouseDown {
                if !isInField(editor, event.locationInWindow) {
                    // Committed before the click is handled: a click on another mask selects it,
                    // and the value would go to that one otherwise.
                    if isToolOpen() { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
                    window.makeFirstResponder(nil)
                }
                return event
            }
            // The monitor sees each key before the field does, so the first one finds the
            // text as it was.
            if original == nil { original = editor.string }
            guard isToolOpen(),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return event }
            switch event.keyCode {
            case 36, 76: // Return, Enter
                // As the field's own Return, so it commits what was typed.
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            case 53: // Esc
                if let original, original != editor.string {
                    // Through the text view's own editing, so the field's binding hears it.
                    let all = NSRange(location: 0, length: (editor.string as NSString).length)
                    if editor.shouldChangeText(in: all, replacementString: original) {
                        editor.replaceCharacters(in: all, with: original)
                        editor.didChangeText()
                    }
                }
            default:
                return event
            }
            window.makeFirstResponder(nil)
            original = nil
            return nil
        }
    }

    /// Whether a click is in the field being typed in, such as to move the insertion point. The
    /// field editor sits inside the field, which can be larger.
    private static func isInField(_ editor: NSTextView, _ point: NSPoint) -> Bool {
        var field: NSView = editor
        var view = editor.superview
        while let current = view {
            if current is NSTextField { field = current; break }
            view = current.superview
        }
        return field.convert(field.bounds, to: nil).contains(point)
    }
}
