import ProofKit
import SwiftUI

/// The Info panel beside the grid in Browse: the selected photo's file, camera details and
/// description. It follows the selection; with several photos selected it shows none (#151).
struct InfoInspector: View {
    let library: Library
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let photo = library.infoPhoto, let url = library.url(ofPhoto: photo.name, in: photo.folder) {
            InspectorPanel {
                PhotoInfoView(library: library, photo: photo, url: url, style: .cards)
                    .id(photo)
            }
        } else {
            Group {
                if library.browse.selectedPhotos.count > 1 {
                    ContentUnavailableView("\(library.browse.selectedPhotos.count) Photos Selected", systemImage: "info.circle",
                                           description: Text("Select one photo to see its info."))
                } else {
                    ContentUnavailableView("No Photo Selected", systemImage: "info.circle",
                                           description: Text("Select a photo to see its info."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: PhotoCanvas.backdropGray(for: colorScheme)).ignoresSafeArea())
        }
    }
}

/// The Info card below the histogram in Edit: the same details, collapsed until opened.
struct InfoCard: View {
    let library: Library

    var body: some View {
        if let photo = library.browse.selectedPhoto, let url = library.selectedPhotoURL {
            InspectorCard {
                DisclosureGroup(isExpanded: Binding(get: { library.isInfoCardExpanded },
                                                    set: { library.isInfoCardExpanded = $0 })) {
                    PhotoInfoView(library: library, photo: photo, url: url, style: .sections)
                        .id(photo)
                        .padding(.top, InspectorCard<EmptyView>.controlSpacing)
                } label: {
                    Text("Info")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }
}

/// A photo's details, read-only, and its description, saved to its XMP sidecar when a field is
/// left or Return is pressed.
private struct PhotoInfoView: View {
    enum Style {
        /// A card for each section, for the Browse panel.
        case cards
        /// Sections with small headings inside one card, for the Edit inspector.
        case sections
    }

    private enum Field: Hashable {
        case title, caption, keywords, creator, copyright, sublocation, city, state, country
    }

    let library: Library
    let photo: PhotoReference
    let url: URL
    let style: Style

    @State private var info: PhotoInfo?
    @State private var draft = PhotoDescription.empty
    @State private var keywords = ""
    /// What the sidecar holds, so leaving an unchanged field writes nothing.
    @State private var saved: PhotoDescription?
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: style == .cards ? InspectorCard<EmptyView>.spacing : 20) {
            section("File") {
                row("Name", info?.fileName ?? photo.name)
                row("Folder", info?.folderPath)
                row("Size", info?.fileSize.map { Int64($0).formatted(.byteCount(style: .file)) })
                row("Dimensions", info?.formattedDimensions)
                row("Format", info?.format)
            }
            section("Capture") {
                row("Date", info?.captureDate.map {
                    $0.formatted(Date.FormatStyle(date: .abbreviated, time: .standard,
                                                  timeZone: info?.captureTimeZone ?? .gmt))
                })
                row("Camera", info?.camera)
                row("Lens", info?.lens)
                row("Focal Length", info?.settings.formattedFocalLength)
                row("Aperture", info?.settings.formattedAperture)
                row("Shutter Speed", info?.settings.formattedShutterSpeed)
                row("ISO", info?.settings.iso.map(String.init))
                row("Exposure", info?.formattedExposureBias)
                row("Flash", info?.flashFired.map { $0 ? "Fired" : "Did not fire" })
                row("GPS", info?.formattedPosition)
            }
            section("Description") {
                field("Title", .title, text: $draft.title)
                field("Caption", .caption, text: $draft.caption, isMultiline: true)
                field("Keywords", .keywords, text: $keywords, prompt: "Separated by commas")
            }
            section("Rights") {
                field("Creator", .creator, text: $draft.creator)
                field("Copyright", .copyright, text: $draft.copyright)
            }
            section("Location") {
                field("Sublocation", .sublocation, text: $draft.sublocation)
                field("City", .city, text: $draft.city)
                field("State or Province", .state, text: $draft.state)
                field("Country", .country, text: $draft.country)
            }
        }
        .disabled(saved == nil && info == nil)
        .onSubmit(save)
        .onChange(of: focus) { save() }
        .onDisappear(perform: save)
        .task {
            let url = url
            let (info, description) = await Task.detached {
                (PhotoInfo.read(from: url), PhotoDescription.read(for: url))
            }.value
            self.info = info
            draft = description
            keywords = description.keywords.joined(separator: ", ")
            saved = description
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        switch style {
        case .cards:
            InspectorCard(title: title, content: content)
        case .sections:
            VStack(alignment: .leading, spacing: InspectorCard<EmptyView>.controlSpacing) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
        }
    }

    /// A read-only value beside its name; a missing one shows a dash, so rows don't jump as the file is read.
    private func row(_ name: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .foregroundStyle(InspectorCard<EmptyView>.labelColor)
                .fixedSize()
            Spacer(minLength: 0)
            // Long values such as a folder path or lens name wrap rather than being cut off.
            Text(value ?? "–")
                .foregroundStyle(value == nil ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(value == nil ? "None" : "")
    }

    private func field(_ name: String, _ field: Field, text: Binding<String>, prompt: String? = nil,
                       isMultiline: Bool = false) -> some View {
        InspectorField(name) {
            TextField(name, text: text, prompt: prompt.map { Text($0) }, axis: isMultiline ? .vertical : .horizontal)
                .labelsHidden()
                .lineLimit(isMultiline ? 1...6 : 1...1)
                .focused($focus, equals: field)
                .accessibilityLabel(name)
        }
    }

    // MARK: Saving

    private func save() {
        guard let saved else { return }
        var description = draft
        description.keywords = PhotoDescription.keywords(from: keywords)
        description = description.normalized
        guard description != saved else { return }
        self.saved = description
        let library = library, photo = photo
        Task {
            if !(await library.saveDescription(description, of: photo)) {
                // Left as typed, so leaving the field again tries once more.
                self.saved = saved
            }
        }
    }
}
