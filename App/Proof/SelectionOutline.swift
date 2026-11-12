import AppKit
import SwiftUI

/// The selection style shared by the grid, the filmstrip, the Looks card and the navigator: a
/// thin rounded outline a few points outside the photo, like a card. It is light gray in the
/// light appearance and white in the dark, so no color competes with the photo.
enum SelectionOutline {
    /// Thumbnails' own corners, small enough that the photo still reads as a rectangle.
    static let photoCornerRadius: CGFloat = 4
    static let lineWidth: CGFloat = 1

    static let color = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : NSColor(white: 0.77, alpha: 1)
    })

    /// Keeps the outline's corners concentric with the photo's, whatever the padding.
    static func cornerRadius(padding: CGFloat) -> CGFloat { photoCornerRadius + padding }
}

/// The parts of a cell its outline wraps, such as the photo and its name, when the cell is
/// larger than they are: a landscape photo in a square cell would otherwise leave an empty band
/// inside the card.
private struct OutlinedPartsKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

extension View {
    /// Marks this view as one the enclosing `selectionOutline` wraps. Without any marked part,
    /// the outline wraps the whole cell.
    func outlined() -> some View {
        anchorPreference(key: OutlinedPartsKey.self, value: .bounds) { [$0] }
    }

    /// Outlines this view when it is selected. The padding is kept whether or not it is, so
    /// selecting a thumbnail doesn't move it.
    func selectionOutline(_ isSelected: Bool, padding: CGFloat = 6) -> some View {
        self.padding(padding)
            .overlayPreferenceValue(OutlinedPartsKey.self) { parts in
                if isSelected {
                    GeometryReader { proxy in
                        let whole = CGRect(origin: .zero, size: proxy.size)
                        let frame = parts.isEmpty ? whole
                            : parts.map { proxy[$0] }.reduce(CGRect.null) { $0.union($1) }
                                .insetBy(dx: -padding, dy: -padding).intersection(whole)
                        RoundedRectangle(cornerRadius: SelectionOutline.cornerRadius(padding: padding))
                            .strokeBorder(SelectionOutline.color, lineWidth: SelectionOutline.lineWidth)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
    }
}
