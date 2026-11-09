import ProofKit
import SwiftUI

/// The crop tool's controls, which take the inspector's place while the tool is open.
struct CropInspector: View {
    let library: Library
    /// Renders the photo for Auto to look for the horizon in.
    let renderer: RAWRenderer?
    /// Custom was chosen from the menu, so the ratio fields show even for a ratio the menu has.
    @State private var choseCustom = false
    @State private var customWidth = ""
    @State private var customHeight = ""

    var body: some View {
        Form {
            Section {
                Picker("Aspect Ratio", selection: Binding(get: { shownChoice }, set: choose)) {
                    ForEach(AspectChoice.allCases, id: \.self) { choice in
                        Text(choice.title)
                        if choice == .freeform || choice == .original { Divider() }
                    }
                }
                if shownChoice == .custom {
                    LabeledContent("Ratio") {
                        HStack(spacing: 4) {
                            ratioField("Width", text: $customWidth)
                            Text(":").foregroundStyle(.secondary)
                            ratioField("Height", text: $customHeight)
                        }
                    }
                }
                LabeledContent("Orientation") {
                    Button("Swap", systemImage: "rectangle.portrait.rotate") { library.swapCropOrientation() }
                        .labelStyle(.titleAndIcon)
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
                LabeledContent {
                    HStack {
                        Toggle(isOn: Binding(get: { library.isDrawingLevelLine }, set: { library.isDrawingLevelLine = $0 })) {
                            Label("Draw Line", systemImage: "ruler")
                                .labelStyle(.iconOnly)
                                .frame(width: Self.levelButtonWidth)
                        }
                        .toggleStyle(.button)
                        .help("Drag along something in the photo that should be level or upright")
                        Button {
                            guard let renderer else { return }
                            Task { await library.autoStraighten(with: renderer) }
                        } label: {
                            Text("Auto").frame(width: Self.levelButtonWidth)
                        }
                        .disabled(renderer == nil || library.isFindingHorizon)
                        .help("Straighten to the horizon found in the photo")
                    }
                } label: {
                    Text("Level")
                    if library.foundNoHorizon {
                        Text("No horizon found")
                    }
                }
            } header: {
                SectionHeader(title: "Crop", canReset: library.canResetCropRectangle) {
                    library.resetCropRectangle()
                }
            }
            Section {
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
                .frame(maxWidth: .infinity)
            } header: {
                SectionHeader(title: "Rotate and Flip",
                              canReset: crop.rotation != 0 || crop.flipHorizontal || crop.flipVertical) {
                    library.resetCropTurn()
                }
            }
        }
        .inspectorForm()
        // The photo's size comes from the file, read when it opens.
        .disabled(library.turnedPhotoSize == nil)
        .onAppear(perform: fillCustomFields)
        .onChange(of: crop.aspect) { fillCustomFields() }
    }

    private var crop: Crop { library.selectedCrop }

    /// The ruler and Auto buttons share one width, so they read as a pair.
    private static let levelButtonWidth = 36.0

    /// The menu item for the locked ratio, in either orientation.
    private var shownChoice: AspectChoice {
        guard let aspect = crop.aspect else { return .freeform }
        if choseCustom { return .custom }
        if let original = library.originalAspect, aspect.matches(original) || aspect.matches(original.swapped) {
            return .original
        }
        return AspectChoice.allCases.first { $0.ratio.map { aspect.matches($0) || aspect.matches($0.swapped) } ?? false } ?? .custom
    }

    private func choose(_ choice: AspectChoice) {
        choseCustom = choice == .custom
        let portrait = library.selectedCropFrame.map { $0.size.height > $0.size.width } ?? false
        switch choice {
        case .freeform: library.setCropAspect(nil)
        case .original: library.setCropAspect(library.originalAspect)
        case .custom:
            // Starts from the rectangle's own shape, rounded to something that can be typed.
            let shape = crop.aspect ?? library.selectedCropFrame.map { AspectRatio($0.size.width, $0.size.height) }
            if let shape { library.setCropAspect(AspectRatio((shape.value * 100).rounded() / 100, 1)) }
        default: library.setCropAspect(choice.ratio?.oriented(portrait: portrait))
        }
    }

    private func ratioField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .labelsHidden()
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: 48)
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
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .help(help)
            .frame(maxWidth: .infinity)
    }
}

/// The aspect ratio menu, in its order.
enum AspectChoice: CaseIterable {
    case freeform, original, square, fourFive, fiveSeven, threeTwo, sixteenNine, custom

    var title: String {
        switch self {
        case .freeform: "Freeform"
        case .original: "Original"
        case .square: "1:1"
        case .fourFive: "4:5"
        case .fiveSeven: "5:7"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .custom: "Custom"
        }
    }

    /// The preset's shape, `nil` for those that depend on the photo or the person.
    var ratio: AspectRatio? {
        switch self {
        case .square: AspectRatio(1, 1)
        case .fourFive: AspectRatio(4, 5)
        case .fiveSeven: AspectRatio(5, 7)
        case .threeTwo: AspectRatio(3, 2)
        case .sixteenNine: AspectRatio(16, 9)
        case .freeform, .original, .custom: nil
        }
    }
}

extension View {
    /// The inspector's form: grouped cards on the canvas's own gray, spaced away from the panel's edges.
    func inspectorForm() -> some View {
        modifier(InspectorForm())
    }
}

private struct InspectorForm: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            // More room than the grouped form's default, which reads as tight beside the photo.
            // Sections are spaced apart by their headers' top padding: macOS has no
            // `listSectionSpacing`.
            // Added to the grouped form's own 10 pt inset, so the cards sit 16 pt from the panel's edges.
            .contentMargins(.horizontal, 6, for: .scrollContent)
            .contentMargins(.vertical, 8, for: .scrollContent)
            .background(Color(white: PhotoCanvas.backdropGray(for: colorScheme)).ignoresSafeArea())
    }
}
