import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Small previews of photos, kept on local disk so a folder on a network share shows its
/// thumbnails without reading the share again. The cache is disposable: deleting the directory
/// only means thumbnails are made again. It keeps to a size limit by removing the thumbnails read
/// least recently (decision 0057).
///
/// A thumbnail is made from the embedded JPEG preview that cameras and DNG converters store in a
/// RAW file, so the RAW data itself isn't decoded. Only a file with no embedded preview is decoded
/// in full. An edited photo's thumbnail is rendered with its edit instead, so it matches the
/// photo in Edit. So is an unedited photo whose camera saved a crop or perspective correction in
/// the file (see `CameraSettings`), which it opens with. Originals are only read.
public final class ThumbnailCache: Sendable {
    /// Renders `url` with `edit` at no more than `maxPixelSize` on the long edge.
    public typealias RenderEdit = @Sendable (_ url: URL, _ edit: EditRecipe) async -> CGImage?
    /// A string that changes whenever the LUT a look names does, or `nil` if it's missing.
    public typealias LUTVersion = @Sendable (_ lut: String) -> String?
    /// Whether `url` is in iCloud with no copy on this device, read from its attributes only.
    public typealias IsInCloud = @Sendable (_ url: URL) -> Bool
    /// The system's thumbnail of a file that isn't downloaded, at no more than `maxPixelSize`.
    public typealias CloudThumbnail = @Sendable (_ url: URL, _ maxPixelSize: Int) async -> CGImage?

    /// Long edge of a stored thumbnail, in pixels: sharp in a Retina grid cell, small on disk.
    public static let maxPixelSize = 512

    /// Where the cache is kept unless told otherwise. On iPad and iPhone it is in Caches, which iOS
    /// doesn't back up and can clear when space runs low; on the Mac, in Application Support.
    public static var defaultDirectory: URL {
        #if os(iOS)
        .cachesDirectory.appendingPathComponent("Proof/Thumbnails")
        #else
        .applicationSupportDirectory.appendingPathComponent("Proof/Thumbnails")
        #endif
    }

    /// The default size limit, in bytes. A thumbnail is usually 50 KB to 300 KB, so this keeps
    /// several thousand on iOS and tens of thousands on the Mac.
    public static var defaultMaxBytes: Int {
        #if os(iOS)
        500_000_000
        #else
        2_000_000_000
        #endif
    }

    public let directory: URL
    /// When the stored thumbnails add up to more than this, the least recently read are removed.
    public let maxBytes: Int
    private let maxConcurrentReads: Int
    private let renderEdit: RenderEdit?
    private let lutVersion: LUTVersion?
    private let isInCloud: IsInCloud
    private let cloudThumbnail: CloudThumbnail

    /// `directory` is created when the first thumbnail is stored. `maxConcurrentReads` limits how
    /// many photos are read at once when making thumbnails, so a NAS isn't asked for a whole
    /// folder in parallel. Without `renderEdit`, edited photos show their embedded preview.
    /// With `lutVersion`, a thumbnail is made again when the LUT its look names changes, and a look
    /// whose LUT is missing is left out, as the canvas leaves it out.
    /// A file in iCloud that isn't downloaded is never opened, since that would download it
    /// (decision 0050): its thumbnail is `cloudThumbnail`'s, unstored.
    /// When the cache grows past `maxBytes`, the thumbnails read least recently are removed until
    /// it is back under 90% of the limit.
    public init(directory: URL = ThumbnailCache.defaultDirectory, maxBytes: Int = ThumbnailCache.defaultMaxBytes,
                maxConcurrentReads: Int = 4, renderEdit: RenderEdit? = nil, lutVersion: LUTVersion? = nil,
                isInCloud: @escaping IsInCloud = { !CloudDownload.isDownloaded($0) },
                cloudThumbnail: @escaping CloudThumbnail = CloudDownload.systemThumbnail(of:maxPixelSize:)) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxConcurrentReads = maxConcurrentReads
        self.renderEdit = renderEdit
        self.lutVersion = lutVersion
        self.isInCloud = isInCloud
        self.cloudThumbnail = cloudThumbnail
    }

    /// The thumbnail of `url` showing `edit`, read from the cache or rendered and stored. With no
    /// edit, or the one the photo opens with, it shows the photo as it opens, with any camera
    /// settings. Blocks on file I/O and rendering.
    public func thumbnail(for url: URL, edit: EditRecipe?) async -> CGImage? {
        if isInCloud(url) { return await cloudThumbnail(url, Self.maxPixelSize) }
        let shown = shown(edit, of: url)
        guard let entry = entry(for: url, showing: shown) else { return nil }
        if let image = readStored(entry) { return image }
        return await makeThumbnail(of: url, showing: shown, storingAs: entry)
    }

    /// The thumbnail of `url` with no edit, read from the cache or made and stored if the cache has
    /// none for the file's current size and modification date. A photo with camera settings gets
    /// its preview without them, unstored, since only `thumbnail(for:edit:)` renders them. `nil` if
    /// the file can't be read as an image. Blocks on file I/O, so call it off the main thread.
    public func thumbnail(for url: URL) -> CGImage? {
        guard !isInCloud(url), let entry = entry(for: url, showing: .asShot) else { return nil }
        if let image = readStored(entry) { return image }
        guard let image = Self.makeThumbnail(of: url) else { return nil }
        if EditRecipe(asShot: CameraSettings(contentsOf: url)).isNeutral { store(image, as: entry) }
        return image
    }

    /// The cached thumbnail of `url`, or `nil` if there is none for the file as it is now.
    /// Never reads more of `url` than its size and modification date.
    public func cachedThumbnail(for url: URL) -> CGImage? {
        guard let entry = entry(for: url, showing: .asShot) else { return nil }
        return readStored(entry)
    }

    /// The cached thumbnail of `url` showing `edit`, or `nil` if none is stored for the file as it
    /// is now and that edit. Never renders. It reads no more of `url` than its size and
    /// modification date, and its metadata when the edit changes only the crop and perspective,
    /// so it is quick enough to show while the photo itself is rendered.
    public func cachedThumbnail(for url: URL, edit: EditRecipe?) -> CGImage? {
        guard !isInCloud(url), let entry = entry(for: url, showing: shown(edit, of: url)) else { return nil }
        return readStored(entry)
    }

    /// Thumbnails for `urls`. Cached thumbnails arrive first, then the rest as they are made, a few
    /// at a time. Each URL arrives once; its image is `nil` if the file can't be read. Photos in
    /// `edited` have their sidecar read and show their edit. Cancelling the consuming task stops
    /// making thumbnails.
    public func thumbnails(for urls: [URL], edited: Set<URL> = []) -> AsyncStream<(url: URL, image: CGImage?)> {
        AsyncStream { continuation in
            let task = Task.detached { [self] in
                // Files that aren't downloaded get the system's thumbnail and are never opened.
                let inCloud = Set(urls.filter(isInCloud))
                await withTaskGroup(of: (URL, CGImage?).self) { group in
                    for url in urls where inCloud.contains(url) {
                        group.addTask { (url, await self.cloudThumbnail(url, Self.maxPixelSize)) }
                    }
                    for await (url, image) in group { continuation.yield((url, image)) }
                }
                let urls = urls.filter { !inCloud.contains($0) }
                var missing: [(url: URL, shown: Shown, entry: Entry?)] = []
                await withTaskGroup(of: (URL, Shown, Entry?, CGImage?).self) { group in
                    var next = 0
                    func addNext() {
                        guard next < urls.count else { return }
                        let url = urls[next]
                        next += 1
                        group.addTask {
                            // A sidecar that can't be read shows the original, as Edit does.
                            let edit = edited.contains(url) ? (try? Sidecar.read(for: url))??.recipe ?? EditRecipe() : nil
                            let shown = self.shown(edit, of: url)
                            let entry = self.entry(for: url, showing: shown)
                            return (url, shown, entry, entry.flatMap { self.readStored($0) })
                        }
                    }
                    // Checking the cache costs one metadata lookup per file, which on a share is
                    // a round trip, so these run in parallel too.
                    for _ in 0..<maxConcurrentReads * 4 { addNext() }
                    for await (url, shown, entry, image) in group {
                        if let image {
                            continuation.yield((url, image))
                        } else {
                            missing.append((url, shown, entry))
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
                        let (url, shown, entry) = missing[next]
                        next += 1
                        group.addTask {
                            guard let entry else { return (url, nil) }
                            return (url, await self.makeThumbnail(of: url, showing: shown, storingAs: entry))
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

    /// An edited photo's entry is also named from its edit, so every change to the edit misses
    /// the cache and the photo keeps one thumbnail at a time.
    func entry(for url: URL, showing shown: Shown) -> Entry? {
        // Asks the file system each time. A URL keeps the resource values it has already read,
        // so a file changed since then would otherwise still match its old thumbnail.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let folder = directory.appendingPathComponent(Self.hash(url.standardizedFileURL.path), isDirectory: true)
        var version = "\(size) \(modified.timeIntervalSinceReferenceDate)"
        switch shown {
        case .asShot: break
        case .original: version += " original"
        case .edit(let edit):
            guard let data = try? Self.editEncoder.encode(edit) else { break }
            version += " " + String(decoding: data, as: UTF8.self)
            if let look = edit.look, let lut = lutVersion?(look.lut) { version += " " + lut }
        }
        version = Self.hash(version)
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
        guard (try? (data as Data).write(to: entry.file, options: .atomic)) != nil else { return }
        noteStored(bytes: data.length)
    }

    /// A stored thumbnail, marked as just read. The file's modification date records when it was
    /// last read, which is the order thumbnails are removed in; the access date isn't reliable,
    /// since APFS doesn't update it on every read.
    private func readStored(_ entry: Entry) -> CGImage? {
        guard let image = Self.readImage(at: entry.file, embeddedOnly: false) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.file.path)
        return image
    }

    // MARK: Size limit

    private struct Usage {
        /// An estimate of the bytes stored, or `nil` until the directory has been measured.
        var bytes: Int?
        var trimming = false
        /// Bytes stored while a trim measured the directory, which it may not have counted.
        var storedWhileTrimming = 0
    }

    private let usage = OSAllocatedUnfairLock(initialState: Usage())

    /// Adds a stored thumbnail to the estimate and trims the cache when it passes the limit. The
    /// first store after launch measures the directory. A replaced thumbnail's bytes stay in the
    /// estimate, which errs high, so a trim measures the directory again before removing anything.
    private func noteStored(bytes: Int) {
        let shouldTrim = usage.withLock { usage -> Bool in
            guard !usage.trimming else {
                usage.storedWhileTrimming += bytes
                return false
            }
            if let known = usage.bytes {
                usage.bytes = known + bytes
                guard known + bytes > maxBytes else { return false }
            }
            usage.trimming = true
            return true
        }
        if shouldTrim { trim() }
    }

    /// Measures the cache and, if it is over the limit, removes the photos' folders whose
    /// thumbnails were read least recently until it is under 90% of the limit, so it isn't trimmed
    /// again on the next store.
    private func trim() {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var folders: [(url: URL, bytes: Int, used: Date)] = []
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in contents {
            var bytes = 0
            var used = Date.distantPast
            for file in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? [] {
                guard let values = try? file.resourceValues(forKeys: keys) else { continue }
                bytes += values.fileSize ?? 0
                used = max(used, values.contentModificationDate ?? .distantPast)
            }
            folders.append((folder, bytes, used))
        }
        var total = folders.reduce(0) { $0 + $1.bytes }
        if total > maxBytes {
            let target = maxBytes / 10 * 9
            for folder in folders.sorted(by: { $0.used < $1.used }) where total > target {
                guard (try? fileManager.removeItem(at: folder.url)) != nil else { continue }
                total -= folder.bytes
            }
        }
        let measured = total
        usage.withLock { usage in
            usage.bytes = measured + usage.storedWhileTrimming
            usage.storedWhileTrimming = 0
            usage.trimming = false
        }
    }

    private static let editEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// What a thumbnail shows.
    enum Shown: Sendable {
        /// The photo as it opens with no edit: the original, with any camera settings.
        case asShot
        /// The original without the camera's settings: a neutral edit of a photo that has some.
        case original
        case edit(EditRecipe)
    }

    /// What a thumbnail of `url` with `edit` shows, without a look whose LUT is missing. An edit
    /// that only sets the crop and perspective may be the one the photo opens with, so only then
    /// is the file's metadata read, to share that thumbnail.
    func shown(_ edit: EditRecipe?, of url: URL) -> Shown {
        guard var edit else { return .asShot }
        if let look = edit.look, let lutVersion, lutVersion(look.lut) == nil { edit.look = nil }
        if edit.isNeutral || edit == EditRecipe(asShot: CameraSettings(crop: edit.crop, transform: edit.transform)) {
            if edit.isAsShot(EditRecipe(asShot: CameraSettings(contentsOf: url))) { return .asShot }
            if edit.isNeutral { return .original }
        }
        return .edit(edit)
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Reading images

    /// Renders an edited photo, or one with camera settings, or reads an unedited one's preview,
    /// and stores the result. An edit that can't be rendered falls back to the original's preview,
    /// which isn't stored as the edit's.
    private func makeThumbnail(of url: URL, showing shown: Shown, storingAs entry: Entry) async -> CGImage? {
        var edit: EditRecipe?
        switch shown {
        case .asShot:
            let asShot = EditRecipe(asShot: CameraSettings(contentsOf: url))
            if !asShot.isNeutral { edit = asShot }
        case .original: break
        case .edit(let shownEdit): edit = shownEdit
        }
        if let edit, let renderEdit {
            if let image = await renderEdit(url, edit) {
                store(image, as: entry)
                return image
            }
            return Self.makeThumbnail(of: url)
        }
        guard let image = Self.makeThumbnail(of: url) else { return nil }
        if edit == nil { store(image, as: entry) }
        return image
    }

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
