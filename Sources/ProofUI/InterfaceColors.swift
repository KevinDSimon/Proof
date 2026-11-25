import ProofKit
import SwiftUI

public extension Color {
    /// The window's own gray behind the sidebar, grid and inspector (#42): the 13% gray of the
    /// default canvas, so in Edit the panels and the photo read as one surface until another canvas
    /// color is chosen.
    static let interfaceBackground = Color(white: CanvasColor.darkGray.components.red)

    /// The one color in the interface, #FFD52E (#192). It marks small things only: switches that
    /// are on and the selection outline. The focused sidebar selection uses a darker version, the
    /// `AccentColor` asset, so its white text stays readable. Large areas and anything
    /// beside the photo stay gray, so it doesn't bias how the photo's colors are judged.
    static let highlight = Color(.sRGB, red: 1, green: 0xD5 / 255, blue: 0x2E / 255)

    /// The filled part of a slider without its own track. The app's accent color is the
    /// highlight, so a slider left untinted would fill in yellow.
    static let sliderFill = Color(white: 0.4)
}
