import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small previews of photos, kept on local disk so a folder on a network share shows its
/// thumbnails without reading the share again. The cache is disposable: deleting the directory
/// only means thumbnails are made again.
///
/// A thumbnail is made from the embedded JPEG preview that cameras and DNG converters store in a
/// RAW file, so the RAW data itself isn't decoded. Only a file with no embedded preview is decoded
/// in full. Originals are only read.
public final class ThumbnailCache: Sendable {
    /// Long edge of a stored thumbnail, in pixels: sharp in a Retina grid cell, small on disk.
    public static let maxPixelSize = 512

    public let directory: URL
    private let maxConcurrentReads: Int

    /// `directory` is created when the first thumbnail is stored. `maxConcurrentReads` limits how
    /// many photos are read at once when making thumbnails, so a NAS isn't asked for a whole
    /// folder in parallel.
    public init(directory: URL = .applicationSupportDirectory.appendingPathComponent("Proof/Thumbnails"),
                maxConcurrentReads: Int = 4) {
        self.directory = directory
        self.maxConcurrentReads = maxConcurrentReads
    }

    /// The thumbnail of `url`, read from the cache or made and stored if the cache has none for
    /// the file's current size and modification date. `nil` if the file can't be read as an image.
    /// Blocks on file I/O, so call it off the main thread.
    public func thumbnail(for url: URL) -> CGImage? {
        guard let entry = entry(for: url) else { return nil }
        if let image = Self.readImage(at: entry.file, embeddedOnly: false) { return image }
        guard let image = Self.makeThumbnail(of: url) else { return nil }
        store(image, as: entry)
        return image
    }

    /// The cached thumbnail of `url`, or `nil` if there is none for the file as it is now.
    /// Never reads more of `url` than its size and modification date.
    public func cachedThumbnail(for url: URL) -> CGImage? {
        guard let entry = entry(for: url) else { return nil }
        return Self.readImage(at: entry.file, embeddedOnly: false)
    }

    /// Thumbnails for `urls`. Cached thumbnails arrive first, then the rest as they are made, a few
    /// at a time. Each URL arrives once; its image is `nil` if the file can't be read. Cancelling
    /// the consuming task stops making thumbnails.
    public func thumbnails(for urls: [URL]) -> AsyncStream<(url: URL, image: CGImage?)> {
        AsyncStream { continuation in
            let task = Task.detached { [self] in
                var missing: [(url: URL, entry: Entry?)] = []
                await withTaskGroup(of: (URL, Entry?, CGImage?).self) { group in
                    var next = 0
                    func addNext() {
                        guard next < urls.count else { return }
                        let url = urls[next]
                        next += 1
                        group.addTask {
                            let entry = self.entry(for: url)
                            return (url, entry, entry.flatMap { Self.readImage(at: $0.file, embeddedOnly: false) })
                        }
                    }
                    // Checking the cache costs one metadata lookup per file, which on a share is
                    // a round trip, so these run in parallel too.
                    for _ in 0..<maxConcurrentReads * 4 { addNext() }
                    for await (url, entry, image) in group {
                        if let image {
                            continuation.yield((url, image))
                        } else {
                            missing.append((url, entry))
                        }
                        addNext()
                    }
                }

                let order = Dictionary(urls.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                missing.sort { order[$0.url, default: 0] < order[$1.url, default: 0] }
                await withTaskGroup(of: (URL, CGImage?).self) { group in
                    var next = 0
                    func addNext() {
                        guard next < missing.count, !Task.isCancelled else { return }
                        let (url, entry) = missing[next]
                        next += 1
                        group.addTask {
                            guard let entry, let image = Self.makeThumbnail(of: url) else { return (url, nil) }
                            self.store(image, as: entry)
                            return (url, image)
                        }
                    }
                    for _ in 0..<maxConcurrentReads { addNext() }
                    for await (url, image) in group {
                        continuation.yield((url, image))
                        addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Storage

    /// Where the thumbnail of one version of a file is stored. Each photo has its own folder, named
    /// from its path, and the file inside is named from its size and modification date. A changed
    /// file therefore misses the cache, and storing its new thumbnail removes the old one.
    struct Entry: Sendable {
        var folder: URL
        var file: URL
    }

    func entry(for url: URL) -> Entry? {
        // Asks the file system each time. A URL keeps the resource values it has already read,
        // so a file changed since then would otherwise still match its old thumbnail.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let folder = directory.appendingPathComponent(Self.hash(url.standardizedFileURL.path), isDirectory: true)
        let version = Self.hash("\(size) \(modified.timeIntervalSinceReferenceDate)")
        return Entry(folder: folder, file: folder.appendingPathComponent(version + ".jpg"))
    }

    private func store(_ image: CGImage, as entry: Entry) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        // A failed write only means the thumbnail is made again next time.
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: entry.folder)
        try? fileManager.createDirectory(at: entry.folder, withIntermediateDirectories: true)
        try? (data as Data).write(to: entry.file, options: .atomic)
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reading images

    private static func makeThumbnail(of url: URL) -> CGImage? {
        readImage(at: url, embeddedOnly: true) ?? readImage(at: url, embeddedOnly: false, decode: true)
    }

    /// With `embeddedOnly`, only a preview stored in the file is used. With `decode`, a file
    /// without one is decoded in full and scaled down, which for a RAW file is slow.
    private static func readImage(at url: URL, embeddedOnly: Bool, decode: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !embeddedOnly,
            kCGImageSourceCreateThumbnailFromImageAlways: decode,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
