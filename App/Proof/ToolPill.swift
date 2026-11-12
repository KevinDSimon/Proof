import SwiftUI

/// The pill at the top of the photo while a tool draws on it, such as Guided Upright's guides
/// and the crop tool's level line: what to do, then the tool's own buttons, then Done. Return
/// and Esc are Done too. Material and the label color keep it gray in either appearance.
struct ToolPill<Actions: View>: View {
    let message: String
    let doneHelp: String
    let done: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .monospacedDigit()
            actions
            Button("Done", action: done)
                .keyboardShortcut(.return, modifiers: [])
                .help(doneHelp)
                .background {
                    Button("", action: done)
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 12)
    }
}
