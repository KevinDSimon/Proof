import ProofKit
import SwiftUI

/// The crop tool's controls, which take the inspector's place while the tool is open.
public struct CropInspector: View {
    let library: Library
    /// Renders the photo for Auto to look for the horizon in.
    let renderer: RAWRenderer?
    /// Custom was chosen from the menu, so the ratio fields show even for a ratio the menu has.
    @State private var choseCustom = false
    @State private var customWidth = ""
    @State private var customHeight = ""

    public init(library: Library, renderer: RAWRenderer?) {
        self.library = library
        self.renderer = renderer
    }

    public var body: some View {
        InspectorPanel {
            // One card, without a switch: the tool already shows the whole photo, and Done or
            // Cancel is the comparison.
            InspectorCard(title: "Crop", canReset: library.canResetCropRectangle || canResetTurn,
                          reset: {
                              library.resetCropRectangle()
                              library.resetCropTurn()
                          }) {
                // Each control's name above it, as the sliders have theirs.
                InspectorField("Aspect Ratio") {
                    PopUpMenu(title: shownChoice.title, items: AspectChoice.allCases.flatMap { choice -> [PopUpMenu.Item] in
                        let item = PopUpMenu.Item.action(choice.title, isChecked: choice == shownChoice) { choose(choice) }
                        return choice == .freeform || choice == .original ? [item, .separator] : [item]
                    })
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Aspect Ratio")
                    if shownChoice == .custom {
                        HStack(spacing: 4) {
                            ratioField("Width", text: $customWidth)
                            Text(":").foregroundStyle(.secondary)
                            ratioField("Height", text: $customHeight)
                        }
                    }
                }
                InspectorField("Orientation") {
                    Button {
                        library.swapCropOrientation()
                    } label: {
                        Label("Swap", systemImage: "rectangle.portrait.rotate")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Switch the crop between landscape and portrait (X)")
                }
                AdjustmentSlider(
                    title: "Straighten",
                    value: Binding(get: { crop.angle }, set: { library.setStraighten($0) }),
                    range: Crop.angleRange, fineStep: 0.1, step: 0.5, coarseStep: 5, fractionDigits: 1,
                    showsSign: true, unit: "degrees",
                    reset: { library.setStraighten(0) },
                    isAdjusting: { adjusting in
                        library.isStraightening = adjusting
                        library.isAdjusting = adjusting
                    })
                InspectorField("Level") {
                    if library.foundNoHorizon { Text("No horizon found") }
                } content: {
                    HStack {
                        // As Guided Upright's Draw Guides: one button in and out of drawing, with
                        // Clear and Done on the photo while drawing.
                        Button {
                            library.isDrawingLevelLine.toggle()
                        } label: {
                            Text(library.isDrawingLevelLine ? "Done" : "Draw Line")
                                .frame(maxWidth: .infinity, maxHeight: Self.levelButtonHeight)
                        }
                        .help(library.isDrawingLevelLine ? "Stop drawing the level line (Esc)"
                              : "Drag along something in the photo that should be level or upright, then drag the line or its ends to adjust")
                        Button {
                            guard let renderer else { return }
                            Task { await library.autoStraighten(with: renderer) }
                        } label: {
                            Text("Auto").frame(maxWidth: .infinity, maxHeight: Self.levelButtonHeight)
                        }
                        .disabled(renderer == nil || library.isFindingHorizon)
                        .help("Straighten to the horizon found in the photo")
                    }
                }
                InspectorField("Rotate and Flip") {
                    HStack {
                        iconButton("Rotate Left", systemImage: "rotate.left", help: "Turn the photo a quarter turn counterclockwise (⌘[)") {
                            library.rotate(clockwise: false)
                        }
                        iconButton("Rotate Right", systemImage: "rotate.right", help: "Turn the photo a quarter turn clockwise (⌘])") {
                            library.rotate(clockwise: true)
                        }
                        iconButton("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                   help: "Mirror the photo left to right") {
                            library.flipHorizontally()
                        }
                        iconButton("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                   help: "Mirror the photo top to bottom") {
                            library.flipVertically()
                        }
                    }
                }
            }
            #if os(iOS)
            // A Mac button has a bezel of its own; on iOS a plain button is bare text.
            .buttonStyle(.bordered)
            #endif
        }
        // The photo's size comes from the file, read when it opens.
        .disabled(library.turnedPhotoSize == nil)
        .onAppear(perform: fillCustomFields)
        .onChange(of: crop.aspect) { fillCustomFields() }
    }

    private var canResetTurn: Bool {
        crop.rotation != 0 || crop.flipHorizontal || crop.flipVertical
    }

    private var crop: Crop { library.selectedCrop }

    /// The ruler and Auto buttons share one height, so they read as a pair: the ruler symbol
    /// alone would make its button taller than Auto's.
    private static let levelButtonHeight = 16.0

    /// The menu item for the locked ratio, in either orientation.
    private var shownChoice: AspectChoice {
        AspectChoice.shown(for: crop.aspect, original: library.originalAspect, choseCustom: choseCustom)
    }

    private func choose(_ choice: AspectChoice) {
        choseCustom = choice == .custom
        library.setCropAspect(choice)
    }

    private func ratioField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .labelsHidden()
            .multilineTextAlignment(.center)
            .monospacedDigit()
            #if os(iOS)
            // The decimal pad has no Return key to apply the ratio with.
            .keyboardType(.numbersAndPunctuation)
            .submitLabel(.done)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            #else
            .frame(width: 48)
            #endif
            .onSubmit(applyCustomRatio)
            .accessibilityLabel("Ratio \(title.lowercased())")
    }

    private func applyCustomRatio() {
        guard let width = Double(customWidth), let height = Double(customHeight), width > 0, height > 0 else {
            fillCustomFields()
            return
        }
        library.setCropAspect(AspectRatio(width, height))
    }

    private func fillCustomFields() {
        guard let aspect = crop.aspect else { return }
        customWidth = aspect.width.formatted(.number.precision(.fractionLength(0...2)))
        customHeight = aspect.height.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func iconButton(_ title: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        // The frame goes on the label so the bezel itself stretches, not only the space around it.
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .help(help)
    }
}
