import ProofKit
import SwiftUI

/// The export sheet's choices, in both apps: format and quality, size, color space and Remove
/// Location. Each app puts these sections in its own `Form`, with its own destinations and
/// buttons around them.
public struct ExportSettingsForm: View {
    @Binding var settings: ExportSettings

    public init(settings: Binding<ExportSettings>) {
        _settings = settings
    }

    public var body: some View {
        Section {
            Picker("Format", selection: $settings.format) {
                ForEach(ExportSettings.Format.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.format.hasQuality {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $settings.quality, in: 0.1...1, step: 0.05)
                            .tint(.sliderFill)
                        Text(settings.quality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } else {
                Text("16 bits per channel, uncompressed, for printing and further editing.")
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Picker("Size", selection: $settings.size) {
                Text("Original").tag(ExportSettings.Size.original)
                Text("Long Edge").tag(ExportSettings.Size.longEdge)
            }
            .pickerStyle(.segmented)
            if settings.size == .longEdge {
                LabeledContent("Long Edge") {
                    HStack {
                        TextField("Long Edge", value: $settings.longEdge, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .decimalKeyboard()
                        Picker("Unit", selection: $settings.unit) {
                            ForEach(ExportSettings.Unit.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if settings.unit.isPrintSize {
                    LabeledContent("Resolution") {
                        HStack {
                            TextField("Resolution", value: $settings.resolution, format: .number.precision(.fractionLength(0)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .decimalKeyboard()
                            Text("ppi")
                        }
                    }
                }
                Text(sizeSummary)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Picker("Color Space", selection: $settings.colorSpace) {
                ForEach(ExportSettings.ColorSpace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(colorHint)
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle("Remove Location", isOn: $settings.removesLocation)
                .toggleStyle(.switch)
                .tint(.highlight)
        }
    }

    /// The long edge in pixels, which a print size alone doesn't show.
    private var sizeSummary: String {
        guard settings.isValid, let pixels = settings.longEdgePixels else { return "Enter a size above 0." }
        let length = pixels.formatted()
        return settings.unit.isPrintSize
            ? "\(length) pixels on the long edge. Photos smaller than this keep their size."
            : "Photos smaller than this keep their size."
    }

    private var colorHint: String {
        switch settings.colorSpace {
        case .sRGB: "Looks the same everywhere. Best for social media, the web and most print labs."
        case .displayP3: "Wider color for iPhone, iPad and Mac screens."
        case .adobeRGB: "Wider color for printers and print services that ask for it."
        }
    }
}

private extension View {
    /// Numbers only, on a touch screen's keyboard.
    @ViewBuilder func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
