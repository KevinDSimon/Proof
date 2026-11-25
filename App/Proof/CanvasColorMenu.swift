import AppKit
import ProofKit
import ProofUI
import SwiftUI

/// View › Canvas Color (#42): the presets with the current one checked, then Custom…, which opens
/// the system color panel.
struct CanvasColorMenu: View {
    let library: Library

    var body: some View {
        Menu("Canvas Color") {
            ForEach(CanvasColor.presets, id: \.self) { color in
                Toggle(color.title, isOn: Binding(get: { library.canvasColor == color },
                                                  set: { _ in library.canvasColor = color }))
            }
            Divider()
            Toggle("Custom…", isOn: Binding(get: { library.canvasColor.isCustom },
                                            set: { _ in CanvasColorPanel.shared.show(for: library) }))
        }
    }
}

/// Connects the shared system color panel to the canvas color while it is open from Custom….
@MainActor
final class CanvasColorPanel: NSObject {
    static let shared = CanvasColorPanel()
    private weak var library: Library?

    func show(for library: Library) {
        self.library = library
        let panel = NSColorPanel.shared
        // Detached while its color is set, so opening the panel doesn't change the canvas.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        let color = library.canvasColor.components
        panel.color = NSColor(displayP3Red: color.red, green: color.green, blue: color.blue, alpha: 1)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let color = panel.color.usingColorSpace(.displayP3) else { return }
        library?.canvasColor = .custom(red: Double(color.redComponent), green: Double(color.greenComponent),
                                       blue: Double(color.blueComponent))
    }
}
