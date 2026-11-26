import ProofKit
import SwiftUI

/// The tools in the inspector that work on the photo itself, which each app draws over it.
public struct OnPhotoTools: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The White Balance card's eyedropper.
    public static let eyedropper = OnPhotoTools(rawValue: 1 << 0)
    /// Guided Upright's guides.
    public static let guides = OnPhotoTools(rawValue: 1 << 1)
    public static let all: OnPhotoTools = [.eyedropper, .guides]
}

public extension AdjustmentsInspector where Looks == EmptyView {
    init(library: Library, renderer: RAWRenderer?, tools: OnPhotoTools) {
        self.init(library: library, renderer: renderer, tools: tools) { EmptyView() }
    }
}

/// The White Balance card's eyedropper button. While the eyedropper is open it is inverted, as
/// selection is marked throughout Proof, rather than tinted.
struct EyedropperButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Label("White Balance Selector", systemImage: "eyedropper")
                .labelStyle(.iconOnly)
        }
        .help("Click something neutral gray in the photo to set the white balance (W)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        if isOn {
            button.buttonStyle(.borderedProminent).tint(.primary)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// Reads the histogram in its own body, so a new one redraws only the graph, not the inspector.
private struct SelectedHistogram: View {
    let library: Library

    var body: some View {
        HistogramView(histogram: library.selectedHistogram)
            .equatable()
    }
}

/// The adjustments for the photo being edited, in the trailing inspector. It sits on the same
/// plain color as the photo's canvas, so the panel and the photo read as one surface.
///
/// `looks` is the Looks section, which only the Mac has until #232. `tools` are the tools that
/// work on the photo itself, which iPad and iPhone get with touch in #231.
public struct AdjustmentsInspector<Looks: View>: View {
    let library: Library
    let renderer: RAWRenderer?
    let tools: OnPhotoTools
    let looks: Looks
    /// Whether Transform's Aspect, Scale and Offset are shown; `nil` follows whether the photo
    /// uses them. Back to `nil` for each photo.
    @State private var showsMoreTransform: Bool?

    public init(library: Library, renderer: RAWRenderer?, tools: OnPhotoTools, @ViewBuilder looks: () -> Looks) {
        self.library = library
        self.renderer = renderer
        self.tools = tools
        self.looks = looks()
    }

    public var body: some View {
        InspectorPanel {
            InspectorCard(title: "Histogram") {
                SelectedHistogram(library: library)
                CaptureSettingsLine(settings: library.selectedEdit?.captureSettings)
                // The decoder's profile sets the colors every adjustment starts from. It sits with
                // the capture settings, in a card without a switch, since it isn't compared on and off.
                ProfileRow(library: library)
            }
            InfoCard(library: library)
            // Looks next, as Lightroom's Profile: a look is where an edit starts (decision 0034).
            looks
            InspectorCard(title: "White Balance", isOn: library.isOnBinding(.whiteBalance),
                          canReset: basic.whiteBalance != .asShot,
                          reset: { library.changeEdit { $0.basic.resetWhiteBalance() } }) {
                // The eyedropper after the pop-up; Custom is listed only while it is chosen.
                HStack {
                    PopUpMenu(title: basic.whiteBalance.title,
                              items: WhiteBalancePreset.allCases
                                  .filter { $0 != .custom || basic.whiteBalance == .custom }
                                  .map { preset in
                                      .action(preset.title, isChecked: preset == basic.whiteBalance) {
                                          if preset == .auto {
                                              guard let renderer else { return }
                                              Task { await library.autoWhiteBalance(with: renderer) }
                                          } else {
                                              library.changeEdit { $0.basic.choose(preset) }
                                          }
                                      }
                                  })
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("White Balance Preset")
                    if tools.contains(.eyedropper) {
                        EyedropperButton(isOn: library.isPickingWhiteBalance) { library.toggleWhiteBalancePicker() }
                            .disabled(renderer == nil)
                    }
                }
                AdjustmentSlider(
                    title: "Temperature",
                    value: Binding(get: { shown.temperature },
                                   set: { kelvin in library.changeEdit { $0.basic.setTemperature(kelvin) } }),
                    range: WhiteBalance.temperatureRange, fineStep: 1, step: 10, coarseStep: 100, fractionDigits: 0,
                    unit: "Kelvin", track: AdjustmentSlider.temperatureTrack,
                    position: WhiteBalance.sliderPosition(forTemperature:),
                    valueAtPosition: WhiteBalance.temperature(atSliderPosition:),
                    reset: { library.changeEdit { $0.basic.resetTemperature() } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Tint",
                    value: Binding(get: { shown.tint },
                                   set: { tint in library.changeEdit { $0.basic.setTint(tint) } }),
                    range: WhiteBalance.tintRange, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.tintTrack,
                    reset: { library.changeEdit { $0.basic.resetTint() } },
                    isAdjusting: { library.isAdjusting = $0 })
            }
            // White balance can't be shown until the camera's has been read from the photo.
            .disabled(library.selectedEdit?.asShot == nil)
            InspectorCard(title: "Basic", isOn: library.isOnBinding(.basic),
                          canReset: basic.exposure != 0 || basic.contrast != 0 || basic.texture != 0
                              || basic.clarity != 0 || basic.dehaze != 0 || basic.highlights != 0 || basic.shadows != 0
                              || basic.whites != 0 || basic.blacks != 0,
                          reset: {
                              library.changeEdit(label: "Reset Basic") {
                                  $0.basic.exposure = 0
                                  $0.basic.contrast = 0
                                  $0.basic.texture = 0
                                  $0.basic.clarity = 0
                                  $0.basic.dehaze = 0
                                  $0.basic.highlights = 0
                                  $0.basic.shadows = 0
                                  $0.basic.whites = 0
                                  $0.basic.blacks = 0
                              }
                          }) {
                // Grouped and ordered as in Lightroom's Basic panel, with Auto on the Tone row as there.
                HStack {
                    sectionHeading("Tone")
                    Spacer()
                    Button("Auto") {
                        guard let renderer else { return }
                        Task { await library.autoTone(with: renderer) }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(renderer == nil || library.isAutoAdjusting)
                    .help("Set Exposure, Contrast, Highlights, Shadows, Whites and Blacks from the photo")
                    .accessibilityLabel("Auto Tone")
                }
                AdjustmentSlider(
                    title: "Exposure",
                    value: Binding(get: { basic.exposure },
                                   set: { value in library.changeEdit { $0.basic.exposure = value } }),
                    range: -5...5, fineStep: 0.01, step: 0.1, coarseStep: 1, fractionDigits: 2,
                    showsSign: true, unit: "stops", track: AdjustmentSlider.exposureTrack,
                    reset: { library.changeEdit { $0.basic.exposure = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Contrast",
                    value: Binding(get: { basic.contrast },
                                   set: { value in library.changeEdit { $0.basic.contrast = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.contrastTrack,
                    reset: { library.changeEdit { $0.basic.contrast = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Highlights",
                    value: Binding(get: { basic.highlights },
                                   set: { value in library.changeEdit { $0.basic.highlights = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.highlightsTrack,
                    reset: { library.changeEdit { $0.basic.highlights = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Shadows",
                    value: Binding(get: { basic.shadows },
                                   set: { value in library.changeEdit { $0.basic.shadows = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.shadowsTrack,
                    reset: { library.changeEdit { $0.basic.shadows = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Whites",
                    value: Binding(get: { basic.whites },
                                   set: { value in library.changeEdit { $0.basic.whites = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.whitesTrack,
                    reset: { library.changeEdit { $0.basic.whites = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Blacks",
                    value: Binding(get: { basic.blacks },
                                   set: { value in library.changeEdit { $0.basic.blacks = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.blacksTrack,
                    reset: { library.changeEdit { $0.basic.blacks = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                sectionHeading("Presence")
                    .padding(.top, 6)
                AdjustmentSlider(
                    title: "Texture",
                    value: Binding(get: { basic.texture },
                                   set: { value in library.changeEdit { $0.basic.texture = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.textureTrack,
                    reset: { library.changeEdit { $0.basic.texture = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Clarity",
                    value: Binding(get: { basic.clarity },
                                   set: { value in library.changeEdit { $0.basic.clarity = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.clarityTrack,
                    reset: { library.changeEdit { $0.basic.clarity = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Dehaze",
                    value: Binding(get: { basic.dehaze },
                                   set: { value in library.changeEdit { $0.basic.dehaze = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: AdjustmentSlider.dehazeTrack,
                    reset: { library.changeEdit { $0.basic.dehaze = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                // Each treatment shows only the sliders that change it; the other's keep their values.
                Picker("Treatment", selection: Binding(get: { blackAndWhite.isOn },
                                                       set: { isOn in library.changeEdit { $0.blackAndWhite.isOn = isOn } })) {
                    Text("Color").tag(false)
                    Text("Black & White").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Flexible segments span the row, as the Curve card's channel picker does.
                .buttonSizing(.flexible)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                if blackAndWhite.isOn {
                    // Custom is listed only while it is chosen, as in the White Balance menu.
                    PopUpMenu(title: blackAndWhite.filter?.title ?? "Custom",
                              items: BlackAndWhite.Filter.allCases.map { filter in
                                  .action(filter.title, isChecked: filter == blackAndWhite.filter) {
                                      library.changeEdit { $0.blackAndWhite.choose(filter) }
                                  }
                              } + (blackAndWhite.filter == nil ? [.action("Custom", isChecked: true) {}] : []))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Filter")
                    mixSlider("Red", \.red, hue: 0, help: "Lightens or darkens reds, oranges and skin, as a red filter does on film")
                    mixSlider("Green", \.green, hue: 120, help: "Lightens or darkens greens and foliage, as a green filter does on film")
                    mixSlider("Blue", \.blue, hue: 240, help: "Lightens or darkens blue skies and water, as a blue filter does on film")
                } else {
                    AdjustmentSlider(
                        title: "Vibrance",
                        value: Binding(get: { basic.vibrance },
                                       set: { value in library.changeEdit { $0.basic.vibrance = value } }),
                        range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                        showsSign: true, track: AdjustmentSlider.vibranceTrack,
                        reset: { library.changeEdit { $0.basic.vibrance = 0 } },
                        isAdjusting: { library.isAdjusting = $0 })
                    AdjustmentSlider(
                        title: "Saturation",
                        value: Binding(get: { basic.saturation },
                                       set: { value in library.changeEdit { $0.basic.saturation = value } }),
                        range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                        showsSign: true, track: AdjustmentSlider.saturationTrack,
                        reset: { library.changeEdit { $0.basic.saturation = 0 } },
                        isAdjusting: { library.isAdjusting = $0 })
                }
            }
            .disabled(library.selectedEdit == nil)
            InspectorCard(title: "Curve", isOn: library.isOnBinding(.curve),
                          canReset: !(library.selectedEdit?.recipe.curve.isIdentity ?? true),
                          reset: { library.changeEdit { $0.curve = ToneCurve() } }) {
                CurveEditor(library: library)
            }
            .disabled(library.selectedEdit == nil)
            SelectiveColorCard(library: library)
            detailCard
            lensCard
            transformCard
            effectsCard
            if let unsaved = library.selectedEdit?.unsaved {
                InspectorCard {
                    Text(Self.message(for: unsaved))
                        .foregroundStyle(.secondary)
                    if unsaved == .noAccess {
                        Button("Grant Access…") { library.grantWriteAccessForSelectedPhoto() }
                    }
                }
            } else if let photo = library.browse.selectedPhoto, library.unsavedMetadata.contains(photo) {
                InspectorCard {
                    Text("Rating and flag not saved. Proof needs permission to save in this photo's folder.")
                        .foregroundStyle(.secondary)
                    Button("Grant Access…") { library.grantWriteAccessForSelectedPhoto() }
                }
            }
        }
        // Every titled card here can fold; the crop tool's single card can't.
        .environment(\.foldedCards, Binding(get: { library.foldedCards }, set: { library.foldedCards = $0 }))
    }

    private var basic: BasicAdjustments { library.selectedEdit?.recipe.basic ?? BasicAdjustments() }
    private var blackAndWhite: BlackAndWhite { library.selectedEdit?.recipe.blackAndWhite ?? BlackAndWhite() }

    /// One channel of the black-and-white mix. Its track runs from that channel's color in shadow
    /// to the color lit, as the channel goes from darkening to lightening it.
    private func mixSlider(_ title: String, _ keyPath: WritableKeyPath<BlackAndWhite, Double>,
                           hue: Double, help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(get: { blackAndWhite[keyPath: keyPath] },
                           set: { value in library.changeEdit { $0.blackAndWhite[keyPath: keyPath] = value } }),
            range: BlackAndWhite.range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            showsSign: true, track: SelectiveColorCard.brightnessTrack(hue: hue),
            reset: { library.changeEdit { $0.blackAndWhite[keyPath: keyPath] = 0 } },
            isAdjusting: { library.isAdjusting = $0 })
            .help(help)
    }

    /// Sharpening and noise reduction, which `CIRAWFilter` applies as it decodes. The sliders
    /// start at the camera's values; Reset returns to them, and the switch off shows them.
    private var detailCard: some View {
        let detail = library.selectedEdit?.recipe.detail ?? DetailAdjustments()
        let shown = shownDetail
        return InspectorCard(title: "Detail", isOn: library.isOnBinding(.detail), canReset: !detail.isNeutral,
                             reset: { library.changeEdit { $0.detail = DetailAdjustments() } }) {
            // Grouped as in Lightroom's Detail panel, so Detail reads as part of noise reduction
            // rather than as the card's own control.
            sectionHeading("Sharpening")
            detailSlider("Amount", spoken: "Sharpening Amount", \.sharpening,
                         help: "Shows at 100% zoom, or when the photo is shown at more than half its size")
            sectionHeading("Noise Reduction")
                .padding(.top, 6)
            detailSlider("Luminance", spoken: "Luminance Noise Reduction", \.noiseReduction,
                         help: "Smooths brightness noise. The camera's amount follows the photo's ISO")
            detailSlider("Detail", spoken: "Noise Reduction Detail", \.noiseReductionDetail,
                         help: "How much fine detail luminance noise reduction keeps. No effect while Luminance is 0")
                // `CIRAWFilter` ignores it without luminance noise reduction to temper.
                .disabled((shown?.noiseReduction ?? 0) == 0)
            detailSlider("Color", spoken: "Color Noise Reduction", \.colorNoiseReduction,
                         help: "Smooths colored speckles")
        }
        // The sliders can't show the camera's values until they have been read from the photo.
        .disabled(shown == nil)
    }

    /// The lens the photo was taken with, its correction profile, which `CIRAWFilter` applies as
    /// it decodes, and Remove Chromatic Aberration, which Proof measures. Many RAW files carry no
    /// profile, such as Leica M files; the card then says so in place of the profile's switch.
    private var lensCard: some View {
        let edit = library.selectedEdit
        let lens = edit?.cameraLens
        let corrections = edit?.recipe.lens ?? LensCorrections()
        return InspectorCard(title: "Lens Corrections", isOn: library.isOnBinding(.lens), canReset: !corrections.isNeutral,
                             reset: { library.changeEdit { $0.lens = LensCorrections() } }) {
            if let lens {
                lensRow("Lens", value: lens.name ?? "Not recorded")
            }
            lensSwitch("Remove Chromatic Aberration", isOn: Binding(
                get: { corrections.chromaticAberration != nil || library.isMeasuringChromaticAberration },
                set: { value in
                    guard let renderer else { return }
                    Task { await library.setRemovesChromaticAberration(value, with: renderer) }
                }),
                isBusy: library.isMeasuringChromaticAberration,
                help: "Lines up the red and blue fringes along edges, measured from this photo")
                .disabled(renderer == nil || library.isAutoAdjusting)
            // A photo without a profile says so instead of showing a switch that can't turn on.
            if let lens, lens.hasProfile {
                lensSwitch("Profile Corrections", isOn: Binding(
                    get: { corrections.appliesProfile(for: lens) },
                    set: { value in
                        // Back to the decoder's default rather than a saved value when they match,
                        // so the edit stays neutral.
                        library.changeEdit { $0.lens.profile = value == lens.profileIsOnByDefault ? nil : value }
                    }),
                    help: "Corrects the lens's distortion and darkened corners with the profile in the photo")
            } else if let lens {
                lensRow("Profile", value: "None for this photo")
                    .help(lens.name == nil ? "The photo carries no lens correction data"
                                           : "The photo carries no correction data for this lens")
            }
            // Manual corrections, for lenses without a profile, grouped as in Lightroom's Manual tab.
            sectionHeading("Distortion")
                .padding(.top, 6)
            lensSlider("Amount", spoken: "Distortion Amount", range: LensCorrections.distortionRange,
                       value: corrections.distortion ?? 0,
                       set: { value, lens in lens.distortion = value == 0 ? nil : value },
                       showsGrid: true,
                       help: "Straightens lines that bow outward, or inward with negative values. The photo fills the frame")
            sectionHeading("Vignetting")
                .padding(.top, 6)
            let vignetting = corrections.vignetting ?? LensVignetting()
            lensSlider("Amount", spoken: "Lens Vignetting Amount", range: LensVignetting.amountRange,
                       value: vignetting.amount, track: AdjustmentSlider.vignetteAmountTrack,
                       set: { value, lens in Self.setVignetting(&lens) { $0.amount = value } },
                       help: "Brightens the corners the lens darkened, or darkens them")
            // The midpoint does nothing without an amount, as in Lightroom.
            lensSlider("Midpoint", spoken: "Lens Vignetting Midpoint", range: LensVignetting.midpointRange,
                       value: vignetting.midpoint, showsSign: false, defaultValue: 50,
                       set: { value, lens in Self.setVignetting(&lens) { $0.midpoint = value } },
                       help: "How far toward the center the correction reaches")
                .disabled(vignetting.amount == 0)
        }
        .disabled(edit == nil)
    }

    /// Perspective correction, as in Lightroom's Transform panel: Upright sets the sliders from
    /// lines in the photo, or from guides drawn on it, and the sliders stay editable.
    private var transformCard: some View {
        let edit = library.selectedEdit
        let transform = edit?.recipe.transform ?? PerspectiveTransform()
        return InspectorCard(title: "Transform", isOn: library.isOnBinding(.transform), canReset: !transform.isNeutral || !transform.guides.isEmpty,
                             reset: {
                                 library.isDrawingGuides = false
                                 library.changeEdit { $0.transform = PerspectiveTransform() }
                             }) {
            // A pop-up, as Lightroom's Geometry panel has it, with its name above, as the sliders
            // have theirs. What Upright is doing shows on the name's line, so nothing below moves.
            InspectorField("Upright") {
                uprightStatus
            } content: {
                // The chosen mode at once, while Upright looks for lines for it.
                let shownMode = library.isFindingLines ? library.findingMode : transform.upright
                PopUpMenu(title: Self.title(of: shownMode), items: Array(uprightGroups.map { group in
                    group.map { mode -> PopUpMenu.Item in
                        .action(Self.title(of: mode), isChecked: mode == transform.upright) {
                            guard let renderer else { return }
                            Task { await library.setUpright(mode, with: renderer) }
                        }
                    }
                }.joined(separator: [.separator])))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Upright")
                .disabled(renderer == nil || library.isFindingLines)
            }
            .help("Auto balances level and perspective. Guided follows lines you draw. Level turns the photo level, Vertical also makes upright lines parallel, Full also makes level lines parallel. Choose a mode again to undo changes to its sliders")
            if transform.upright == .guided && !library.isFindingLines && tools.contains(.guides) { guidedButtons(transform) }
            // Under Upright, as in Lightroom Classic: Upright's corrections are the ones that leave
            // empty edges, and it sets how every slider below comes out.
            lensSwitch("Constrain Crop", isOn: Binding(
                get: { transform.constrainCrop },
                set: { value in library.changeEdit { $0.transform.constrainCrop = value } }),
                help: "Enlarges the corrected photo so it fills the frame, with no empty edges")
            // The sliders Upright sets, and the ones most often nudged by hand.
            transformSlider("Vertical", \.vertical, range: PerspectiveTransform.tiltRange,
                            help: "Tilts the photo top to bottom. Negative values straighten a building that leans back")
            transformSlider("Horizontal", \.horizontal, range: PerspectiveTransform.tiltRange,
                            help: "Tilts the photo side to side, to face a wall square on")
            transformSlider("Rotate", \.rotate, range: PerspectiveTransform.rotateRange, step: 0.1, fractionDigits: 1,
                            unit: "degrees", help: "Turns the photo, in degrees clockwise")
            // Rarely needed, so closed unless the photo uses them.
            let usesMore = transform.aspect != 0 || transform.scale != 100 || transform.xOffset != 0 || transform.yOffset != 0
            let showsMore = Binding(get: { showsMoreTransform ?? usesMore },
                                    set: { showsMoreTransform = $0 })
            DisclosureGroup(isExpanded: showsMore) {
                VStack(alignment: .leading, spacing: InspectorCard<EmptyView>.controlSpacing) {
                    transformSlider("Aspect", \.aspect, range: PerspectiveTransform.aspectRange,
                                    help: "Stretches the photo across, or upward with negative values, to undo the stretch a correction leaves")
                    transformSlider("Scale", \.scale, range: PerspectiveTransform.scaleRange, defaultValue: 100, showsSign: false,
                                    unit: "percent", help: "Enlarges or shrinks the photo about its center")
                    transformSlider("X Offset", \.xOffset, range: PerspectiveTransform.offsetRange,
                                    help: "Moves the photo right, or left with negative values")
                    transformSlider("Y Offset", \.yOffset, range: PerspectiveTransform.offsetRange,
                                    help: "Moves the photo up, or down with negative values")
                }
                .padding(.top, 6)
            } label: {
                // The whole row opens it, as the cards' headers do, not just the arrow.
                Text("Aspect, Scale and Offset")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) { showsMore.wrappedValue.toggle() }
                    }
            }
            .foregroundStyle(InspectorCard<EmptyView>.labelColor)
        }
        .disabled(edit == nil)
        .onChange(of: library.browse.selectedPhoto) { showsMoreTransform = nil }
    }

    /// Upright's menu, grouped as in Lightroom: Off, then Auto and Guided, then the fixed
    /// corrections from least to most. Guided is drawn on the photo, so it's left out without
    /// the guide tool, unless the photo already uses it.
    private var uprightGroups: [[UprightMode?]] {
        let guided = tools.contains(.guides) || library.selectedEdit?.recipe.transform.upright == .guided
        return [[nil], guided ? [.auto, .guided] : [.auto], [.level, .vertical, .full]]
    }

    private static func title(of mode: UprightMode?) -> String {
        switch mode {
        case nil: "Off"
        case .auto: "Auto"
        case .guided: "Guided"
        case .level: "Level"
        case .vertical: "Vertical"
        case .full: "Full"
        }
    }

    /// What Upright is doing, beside its name: looking for lines, or having found none.
    @ViewBuilder
    private var uprightStatus: some View {
        if library.isFindingLines {
            ProgressView()
                .accessibilityLabel("Finding lines")
            Text("Finding lines…")
        } else if library.foundNoLines {
            Text("No straight lines found")
        }
    }

    /// Guided's way in and out of drawing, with Clear All while drawing, so nothing covers the
    /// photo but the guides.
    private func guidedButtons(_ transform: PerspectiveTransform) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    library.isDrawingGuides.toggle()
                } label: {
                    Text(library.isDrawingGuides ? "Done" : transform.guides.isEmpty ? "Draw Guides" : "Edit Guides")
                        .frame(maxWidth: .infinity)
                }
                .help(library.isDrawingGuides ? "Stop drawing guides (Return or Esc)"
                                              : "Draw along edges that should be upright or level. Two each way set every slider")
                if library.isDrawingGuides {
                    Button {
                        library.clearGuides()
                    } label: {
                        Text("Clear All").frame(maxWidth: .infinity)
                    }
                    .disabled(transform.guides.isEmpty)
                    .accessibilityLabel("Clear All Guides")
                }
            }
        }
    }

    private func transformSlider(_ title: String, _ keyPath: WritableKeyPath<PerspectiveTransform, Double>,
                                 range: ClosedRange<Double>, step: Double = 1, fractionDigits: Int = 0,
                                 defaultValue: Double = 0, showsSign: Bool = true, unit: String = "",
                                 help: String) -> some View {
        let transform = library.selectedEdit?.recipe.transform ?? PerspectiveTransform()
        return AdjustmentSlider(
            title: title,
            spokenTitle: "Transform \(title)",
            value: Binding(get: { transform[keyPath: keyPath] },
                           set: { new in library.changeEdit { $0.transform[keyPath: keyPath] = new } }),
            range: range, fineStep: step, step: step, coarseStep: step * 10, fractionDigits: fractionDigits,
            showsSign: showsSign, unit: unit,
            reset: { library.changeEdit { $0.transform[keyPath: keyPath] = defaultValue } },
            isAdjusting: { adjusting in
                library.isAdjusting = adjusting
                library.isAdjustingGeometry = adjusting
            })
            .help(help)
    }

    /// Changes the lens vignetting, back to `nil` at its defaults so the edit stays neutral.
    private static func setVignetting(_ lens: inout LensCorrections, _ change: (inout LensVignetting) -> Void) {
        var vignetting = lens.vignetting ?? LensVignetting()
        change(&vignetting)
        lens.vignetting = vignetting == LensVignetting() ? nil : vignetting
    }

    private func lensSlider(_ title: String, spoken: String, range: ClosedRange<Double>, value: Double,
                            showsSign: Bool = true, track: [Color] = [], defaultValue: Double = 0,
                            set: @escaping (Double, inout LensCorrections) -> Void, showsGrid: Bool = false,
                            help: String) -> some View {
        AdjustmentSlider(
            title: title,
            spokenTitle: spoken,
            value: Binding(get: { value }, set: { new in library.changeEdit { set(new, &$0.lens) } }),
            range: range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            showsSign: showsSign, track: track,
            reset: { library.changeEdit { set(defaultValue, &$0.lens) } },
            isAdjusting: { adjusting in
                library.isAdjusting = adjusting
                if showsGrid { library.isAdjustingGeometry = adjusting }
            })
            .help(help)
    }

    /// A switch on the card's trailing edge, lined up with the cards' own, with its name ahead of
    /// it, and a spinner beside it while `isBusy`.
    private func lensSwitch(_ title: String, isOn: Binding<Bool>, isBusy: Bool = false, help: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(InspectorCard<EmptyView>.labelColor)
                .accessibilityHidden(true)
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Measuring")
            }
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                // The highlight, as the cards' own switches are.
                .tint(.highlight)
                .labelsHidden()
        }
        .help(help)
    }

    /// A name and its value, the value on the card's trailing edge like the switches.
    private func lensRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(InspectorCard<EmptyView>.labelColor)
                .fixedSize()
            Spacer(minLength: 12)
            // Wraps rather than truncates: a lens name is often longer than the space beside its label.
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    /// Vignette, then the film effects, under one switch as in Lightroom's Effects panel. The
    /// vignette is Lightroom's post-crop one: it centers on the cropped frame and follows any crop.
    private var effectsCard: some View {
        let recipe = library.selectedEdit?.recipe ?? EditRecipe()
        return InspectorCard(title: "Effects", isOn: library.isOnBinding(.effects), canReset: !recipe.hasNoEffects,
                             reset: { library.changeEdit { $0.removeEffects() } }) {
            sectionHeading("Vignette")
            effectSlider("Amount", spoken: "Vignette Amount", \.vignette.amount, range: VignetteAdjustments.amountRange,
                         showsSign: true, track: AdjustmentSlider.vignetteAmountTrack,
                         help: "Darkens the edges of the photo, or lightens them")
            // Each effect's other sliders do nothing without an amount, as in Lightroom.
            Group {
                effectSlider("Midpoint", spoken: "Vignette Midpoint", \.vignette.midpoint, range: VignetteAdjustments.midpointRange,
                             help: "How far toward the center the vignette reaches")
                effectSlider("Roundness", spoken: "Vignette Roundness", \.vignette.roundness, range: VignetteAdjustments.roundnessRange,
                             showsSign: true, help: "From the frame's rectangle to a circle")
                effectSlider("Feather", spoken: "Vignette Feather", \.vignette.feather, range: VignetteAdjustments.featherRange,
                             help: "How gradually the vignette fades in. At 0 it has a hard edge")
            }
            .disabled(recipe.vignette.amount == 0)
            sectionHeading("Grain")
            effectSlider("Amount", spoken: "Grain Amount", \.grain.amount, range: GrainAdjustments.amountRange,
                         help: "Adds film grain. Judge it at 100%; smaller views show it as a shrunk export would")
            Group {
                effectSlider("Size", spoken: "Grain Size", \.grain.size, range: GrainAdjustments.sizeRange,
                             help: "How large the grains are, relative to the photo")
                effectSlider("Roughness", spoken: "Grain Roughness", \.grain.roughness, range: GrainAdjustments.roughnessRange,
                             help: "From soft, even grain to a mix of finer, sharper grains")
            }
            .disabled(recipe.grain.amount == 0)
            sectionHeading("Halation")
            effectSlider("Amount", spoken: "Halation Amount", \.halation.amount, range: GlowAdjustments.amountRange,
                         help: "A red glow around bright lights, as film shows where light reflects off its base")
            effectSlider("Size", spoken: "Halation Size", \.halation.size, range: GlowAdjustments.sizeRange,
                         help: "How far the glow spreads from the lights")
                .disabled(recipe.halation.amount == 0)
            sectionHeading("Bloom")
            effectSlider("Amount", spoken: "Bloom Amount", \.bloom.amount, range: GlowAdjustments.amountRange,
                         help: "A soft glow around highlights, as a diffusion filter gives")
            effectSlider("Size", spoken: "Bloom Size", \.bloom.size, range: GlowAdjustments.sizeRange,
                         help: "How far the glow spreads from the highlights")
                .disabled(recipe.bloom.amount == 0)
        }
        .disabled(library.selectedEdit == nil)
    }

    private func effectSlider(_ title: String, spoken: String, _ keyPath: WritableKeyPath<EditRecipe, Double>,
                              range: ClosedRange<Double>, showsSign: Bool = false, track: [Color] = [],
                              help: String) -> some View {
        AdjustmentSlider(
            title: title,
            spokenTitle: spoken,
            value: Binding(get: { library.selectedEdit?.recipe[keyPath: keyPath] ?? EditRecipe()[keyPath: keyPath] },
                           set: { value in library.changeEdit { $0[keyPath: keyPath] = value } }),
            range: range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            showsSign: showsSign, track: track,
            reset: { library.changeEdit { $0[keyPath: keyPath] = EditRecipe()[keyPath: keyPath] } },
            isAdjusting: { library.isAdjusting = $0 })
            .help(help)
    }

    /// A heading over a group of sliders inside a card, as in Lightroom's panels.
    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// The detail amounts the photo shows, the camera's where the edit has none; `nil` until the
    /// camera's have been read.
    private var shownDetail: DetailAdjustments? {
        guard let edit = library.selectedEdit else { return nil }
        return edit.cameraDetail.map { edit.recipe.detail.shown(camera: $0) }
    }

    private func detailSlider(_ title: String, spoken: String, _ keyPath: WritableKeyPath<DetailAdjustments, Double?>,
                              help: String) -> some View {
        AdjustmentSlider(
            title: title,
            spokenTitle: spoken,
            // Read from the edit on each call, not from a copy taken when the card was drawn: the
            // slider reads the value back right after setting it, to show the number.
            value: Binding(get: { shownDetail?[keyPath: keyPath] ?? 0 },
                           set: { value in library.changeEdit { $0.detail[keyPath: keyPath] = value } }),
            range: DetailAdjustments.range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            reset: { library.changeEdit { $0.detail[keyPath: keyPath] = nil } },
            isAdjusting: { library.isAdjusting = $0 })
            .help(help)
    }

    /// The white balance the photo shows, the camera's where it hasn't been changed.
    private var shown: WhiteBalance {
        basic.whiteBalance(asShot: library.selectedEdit?.asShot ?? WhiteBalance(temperature: 5500, tint: 0))
    }

    private static func message(for unsaved: PhotoEdit.Unsaved) -> String {
        switch unsaved {
        case .noAccess: "Not saved. Proof needs permission to save edits in this photo's folder."
        case .unreadable: "This photo's edit file couldn't be read, so changes aren't saved."
        case .failed: "The last change couldn't be saved."
        }
    }
}
