import ProofKit
import SwiftUI

/// File › Export…: the format, size, color space and metadata of the export, then a folder to
/// export to. The settings are remembered for the next export, in place of presets (decision 0031).
struct ExportSheet: View {
    let library: Library
    let photos: [PhotoReference]
    @Environment(\.dismiss) private var dismiss
    /// The last export's settings, as JSON. Empty until the first export.
    @AppStorage("exportSettings") private var storedSettings = Data()
    /// The folder last exported to, where the open panel starts.
    @AppStorage("exportFolderPath") private var lastFolderPath = ""
    @State private var settings = ExportSettings()
    @State private var isChoosingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            Text(photos.count == 1 ? "Export Photo" : "Export \(photos.count) Photos")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    Picker("Format", selection: $settings.format) {
                        ForEach(ExportSettings.Format.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if settings.format.hasQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $settings.quality, in: 0.1...1, step: 0.05)
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
                        .tint(.green)
                }
            }
            .formStyle(.grouped)
            // The sheet's own background, so the title above and the buttons below sit on the same surface.
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { isChoosingFolder = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            storedSettings = (try? JSONEncoder().encode(settings)) ?? Data()
            lastFolderPath = folder.path
            library.export(photos, settings: settings, to: folder)
            dismiss()
        }
        .fileDialogDefaultDirectory(lastFolderPath.isEmpty ? nil : URL(fileURLWithPath: lastFolderPath))
        .fileDialogMessage(Text(photos.count == 1 ? "Choose a folder for the photo." : "Choose a folder for the \(photos.count) photos."))
        .fileDialogConfirmationLabel(Text("Export"))
        .onAppear {
            if let saved = try? JSONDecoder().decode(ExportSettings.self, from: storedSettings) { settings = saved }
        }
    }

    private var isValid: Bool {
        settings.size == .original || (settings.longEdge > 0 && (!settings.unit.isPrintSize || settings.resolution > 0))
    }

    /// The long edge in pixels, which a print size alone doesn't show.
    private var sizeSummary: String {
        guard isValid, let pixels = settings.longEdgePixels else { return "Enter a size above 0." }
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
