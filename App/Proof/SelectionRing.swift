import SwiftUI

extension View {
    /// Marks a selected thumbnail with a ring that follows the photo's own shape, a small gap
    /// away from it. The ring is black in the light appearance and white in the dark: Proof keeps
    /// its own interface neutral so no color competes with the photo.
    func selectionRing(_ isSelected: Bool, lineWidth: CGFloat = 2.5, gap: CGFloat = 3) -> some View {
        padding(gap + lineWidth)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: gap + lineWidth)
                        .strokeBorder(.primary, lineWidth: lineWidth)
                }
            }
    }
}
