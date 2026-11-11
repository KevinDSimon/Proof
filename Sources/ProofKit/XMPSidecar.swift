import Foundation

/// Saves the star rating and flag set in Proof to the photo's XMP sidecar, where Photomator,
/// Lightroom, Capture One and others read them (decision 0022). Originals are never written to.
///
/// An existing sidecar is changed as text rather than parsed and written out again, so every other
/// tag, namespace, comment and the file's choice of attributes or elements stays as it was. Only
/// `xmp:Rating`, `xmpDM:pick` and `xmpDM:good` change.
public enum XMPSidecar {
    public enum SaveError: Error, LocalizedError, Equatable {
        /// The sidecar isn't laid out as XMP usually is, so it was left alone.
        case unrecognized

        public var errorDescription: String? {
            "The photo's XMP file is laid out in a way Proof doesn't recognize, so it wasn't changed."
        }
    }

    /// The sidecar Proof reads for `photo`, by its name on disk: the most recently modified of
    /// `IMG.xmp` and `IMG.DNG.xmp`, in any capitalization. `nil` when there is none. Blocks on file I/O.
    public static func existing(for photo: URL) -> URL? {
        let folder = photo.deletingLastPathComponent()
        let keys = Set(PhotoMetadata.sidecarKeys(for: photo.lastPathComponent))
        // Listed rather than checked by name, so a sidecar written as `.XMP` keeps its name
        // on disks that ignore case.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return FolderContents.newestSidecar(of: entries.filter { keys.contains($0.lastPathComponent.lowercased()) })
    }

    /// Where a new sidecar goes: `IMG.xmp`, as Photomator, Lightroom and Capture One name it.
    public static func newURL(for photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Writes `metadata`'s rating and flag to `photo`'s sidecar with `NSFileCoordinator`, creating
    /// `IMG.xmp` when there is none. A new sidecar also keeps the label, from `metadata` or from
    /// the XMP inside the photo, since the sidecar takes the place of that XMP in other apps.
    /// Returns the sidecar's URL. Blocks on file I/O.
    @discardableResult
    public static func save(_ metadata: PhotoMetadata, for photo: URL) throws -> URL {
        let url = existing(for: photo) ?? newURL(for: photo)
        var result: Result<Void, Error> = .success(())
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordinatorError) { url in
            result = Result {
                let data: Data
                if FileManager.default.fileExists(atPath: url.path) {
                    let original = try Data(contentsOf: url)
                    data = try updated(original, to: metadata)
                    guard data != original else { return }
                } else {
                    var metadata = metadata
                    if metadata.label == nil { metadata.label = PhotoMetadata.embedded(in: photo)?.label }
                    data = new(metadata)
                }
                try data.write(to: url, options: .atomic)
            }
        }
        if let coordinatorError { throw coordinatorError }
        try result.get()
        return url
    }

    // MARK: Contents

    /// `xmp` with its rating and flag set to `metadata`'s and nothing else changed. Throws
    /// `unrecognized`, rather than return anything, when the result wouldn't read back as intended.
    static func updated(_ xmp: Data, to metadata: PhotoMetadata) throws -> Data {
        guard let text = String(data: xmp, encoding: .utf8), let before = PhotoMetadata(xmp: xmp) else {
            throw SaveError.unrecognized
        }
        var editor = Editor(text: text)
        try editor.set(Namespace.xmp, "Rating", to: String(metadata.rating))
        try editor.set(Namespace.xmpDM, "pick", to: pick(metadata.flag))
        try editor.set(Namespace.xmpDM, "good", to: good(metadata.flag))
        let data = Data(editor.text.utf8)
        let expected = PhotoMetadata(rating: metadata.rating, flag: metadata.flag, label: before.label)
        guard PhotoMetadata(xmp: data) == expected else { throw SaveError.unrecognized }
        return data
    }

    /// A sidecar holding only the rating, the flag and, if there is one, the label.
    static func new(_ metadata: PhotoMetadata) -> Data {
        var properties = [#"xmp:Rating="\#(metadata.rating)""#]
        if let label = metadata.label { properties.append(#"xmp:Label="\#(escaped(label))""#) }
        properties.append(#"xmpDM:pick="\#(pick(metadata.flag))""#)
        if let good = good(metadata.flag) { properties.append(#"xmpDM:good="\#(good)""#) }
        return Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="\(Namespace.rdf)">
              <rdf:Description rdf:about=""
                xmlns:xmp="\(Namespace.xmp)"
                xmlns:xmpDM="\(Namespace.xmpDM)"
                \(properties.joined(separator: "\n    "))/>
             </rdf:RDF>
            </x:xmpmeta>

            """.utf8)
    }

    /// Lightroom Classic 13.2 and later, and Photomator, write the flag this way (decision 0005).
    private static func pick(_ flag: PhotoMetadata.Flag) -> String {
        switch flag {
        case .flagged: "1"
        case .unflagged: "0"
        case .rejected: "-1"
        }
    }

    /// `xmpDM:good` for the flag, as an XMP Boolean; an unflagged photo has none.
    private static func good(_ flag: PhotoMetadata.Flag) -> String? {
        switch flag {
        case .flagged: "True"
        case .unflagged: nil
        case .rejected: "False"
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    enum Namespace {
        static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        static let xmp = "http://ns.adobe.com/xap/1.0/"
        static let xmpDM = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"

        /// The prefix written when a sidecar has none for the namespace.
        static func preferredPrefix(for uri: String) -> String {
            switch uri {
            case xmp: "xmp"
            case xmpDM: "xmpDM"
            default: "ns"
            }
        }
    }

    /// Changes simple XMP properties in place. Prefixes are looked up by namespace URI, since
    /// apps choose their own. A property is changed where it is, as an attribute
    /// (`xmp:Rating="3"`, Lightroom) or an element (`<xmp:Rating>3</xmp:Rating>`, Photomator).
    /// A missing one is added to the first `rdf:Description` in the form that description uses.
    struct Editor {
        var text: String

        /// Sets the property, or removes it when `value` is `nil`.
        mutating func set(_ namespace: String, _ name: String, to value: String?) throws {
            for prefix in prefixes(for: namespace) {
                let qualified = Self.escapedForRegex(prefix + ":" + name)
                let attribute = try Regex(#"\s+\#(qualified)\s*=\s*("[^"]*"|'[^']*')"#)
                if let match = text.firstMatch(of: attribute) {
                    if let value {
                        let quoted = match.output[1].substring!
                        let quote = String(quoted.first!)
                        text.replaceSubrange(quoted.startIndex..<quoted.endIndex, with: quote + value + quote)
                    } else {
                        text.removeSubrange(match.range)
                    }
                    return
                }
                let element = try Regex(#"(?:\r?\n[ \t]*)?<\#(qualified)(?:\s[^<>]*)?>([^<]*)</\#(qualified)\s*>"#)
                if let match = text.firstMatch(of: element) {
                    if let value {
                        let content = match.output[1].substring!
                        text.replaceSubrange(content.startIndex..<content.endIndex, with: value)
                    } else {
                        text.removeSubrange(match.range)
                    }
                    return
                }
            }
            guard let value else { return }
            try add(namespace, name, value)
        }

        private mutating func add(_ namespace: String, _ name: String, _ value: String) throws {
            guard let start = try descriptionStart() else { throw SaveError.unrecognized }
            var attributes = start.attributes
            var insertions = ""
            let prefix: String
            if let existing = prefixes(for: namespace).first {
                prefix = existing
            } else {
                prefix = unusedPrefix(for: namespace)
                insertions += Self.separator(in: attributes) + #"xmlns:\#(prefix)="\#(namespace)""#
            }
            // Photomator's descriptions hold only namespaces and properties as elements. Any other
            // description, including Lightroom's, which mixes both, takes another attribute.
            let usesElements = !start.isEmpty && !Self.hasPropertyAttributes(attributes)
            if !usesElements {
                insertions += Self.separator(in: attributes) + #"\#(prefix):\#(name)="\#(value)""#
            }
            attributes.append(contentsOf: insertions)
            text.replaceSubrange(start.attributeRange, with: attributes)
            if usesElements {
                // Re-found, since the attributes may have grown.
                guard let start = try descriptionStart() else { throw SaveError.unrecognized }
                let indent = text[start.end...].firstMatch(of: /^\r?\n[ \t]*/).map { String($0.output) }
                    ?? "\n" + start.indent + " "
                text.insert(contentsOf: "\(indent)<\(prefix):\(name)>\(value)</\(prefix):\(name)>", at: start.end)
            }
        }

        /// The first `rdf:Description` start tag: its attributes, whether it is empty (`/>`),
        /// where it ends and the indentation of its line.
        private func descriptionStart() throws -> (attributeRange: Range<String.Index>, attributes: String,
                                                   isEmpty: Bool, end: String.Index, indent: String)? {
            let rdf = Self.escapedForRegex(prefixes(for: Namespace.rdf).first ?? "rdf")
            let tag = try Regex(#"<\#(rdf):Description((?:\s+[^\s=/>]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(/?)>"#)
            guard let match = text.firstMatch(of: tag) else { return nil }
            let attributes = match.output[1].substring!
            let lineStart = text[..<match.range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let indent = text[lineStart..<match.range.lowerBound].prefix { $0 == " " || $0 == "\t" }
            return (attributes.startIndex..<attributes.endIndex, String(attributes),
                    match.output[2].substring == "/", match.range.upperBound, String(indent))
        }

        /// The prefixes bound to `namespace` anywhere in the file, in order of appearance.
        private func prefixes(for namespace: String) -> [String] {
            var found: [String] = []
            for match in text.matches(of: /xmlns:([A-Za-z_][\w.\-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/) {
                let uri = match.output.2 ?? match.output.3
                let prefix = String(match.output.1)
                if uri.map(String.init) == namespace, !found.contains(prefix) { found.append(prefix) }
            }
            return found
        }

        private func unusedPrefix(for namespace: String) -> String {
            let preferred = Namespace.preferredPrefix(for: namespace)
            var candidate = preferred
            var number = 1
            while text.contains("xmlns:\(candidate)=") {
                candidate = preferred + String(number)
                number += 1
            }
            return candidate
        }

        /// Whether a start tag has attributes other than namespaces and RDF's own.
        private static func hasPropertyAttributes(_ attributes: String) -> Bool {
            attributes.matches(of: /\s+([^\s=]+)\s*=/).contains { match in
                let name = match.output.1
                return name != "xmlns" && !name.hasPrefix("xmlns:") && !name.hasPrefix("rdf:")
            }
        }

        /// The whitespace before the last attribute, so an added one lines up with the others.
        private static func separator(in attributes: String) -> String {
            attributes.matches(of: /(\s+)[^\s=]+\s*=/).last.map { String($0.output.1) } ?? " "
        }

        private static func escapedForRegex(_ text: String) -> String {
            text.map { #"\^$.|?*+()[]{}-"#.contains($0) ? "\\" + String($0) : String($0) }.joined()
        }
    }
}
