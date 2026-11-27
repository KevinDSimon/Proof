import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ProofKit

struct ThumbnailCacheTests {
    let root: URL
    let cache: ThumbnailCache

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache = ThumbnailCache(directory: root.appendingPathComponent("Cache"))
    }

    /// A PNG stands in for a RAW file, since RAW files can't be committed. It has no embedded
    /// preview, so it also covers the fallback that decodes the whole image.
    @discardableResult
    func makePhoto(_ name: String, width: Int = 2000, height: Int = 1000) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = root.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func storedFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: cache.directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jpg" }
    }

    @Test("A thumbnail is scaled to 512 pixels on its long edge and stored for the next visit")
    func storesThumbnail() throws {
        let photo = try makePhoto("A.DNG")
        #expect(cache.cachedThumbnail(for: photo) == nil)

        let image = try #require(cache.thumbnail(for: photo))
        #expect(image.width == 512)
        #expect(image.height == 256)

        let cached = try #require(cache.cachedThumbnail(for: photo))
        #expect(cached.width == 512)
        #expect(storedFiles().count == 1)
    }

    @Test("Making a thumbnail doesn't change the original")
    func originalUntouched() throws {
        let photo = try makePhoto("A.DNG")
        let before = try Data(contentsOf: photo)
        let modified = try photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = cache.thumbnail(for: photo)
        #expect(try Data(contentsOf: photo) == before)
        #expect(try photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }

    @Test("A changed modification date misses the cache, and the new thumbnail replaces the old one")
    func modificationDateInvalidates() throws {
        let photo = try makePhoto("A.DNG")
        _ = cache.thumbnail(for: photo)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: photo.path)
        #expect(cache.cachedThumbnail(for: photo) == nil)

        _ = try #require(cache.thumbnail(for: photo))
        #expect(cache.cachedThumbnail(for: photo) != nil)
        #expect(storedFiles().count == 1)
    }

    @Test("A changed file size misses the cache")
    func sizeInvalidates() throws {
        let photo = try makePhoto("A.DNG")
        _ = cache.thumbnail(for: photo)
        let modified = try #require(photo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        let size = { try FileManager.default.attributesOfItem(atPath: photo.path)[.size] as? Int }
        let sizeBefore = try size()
        try makePhoto("A.DNG", width: 800, height: 1600)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: photo.path)
        try #require(try size() != sizeBefore)
        #expect(cache.cachedThumbnail(for: photo) == nil)

        let image = try #require(cache.thumbnail(for: photo))
        #expect(image.width == 256)
        #expect(image.height == 512)
    }

    @Test("Photos with the same name in different folders get their own thumbnails")
    func pathsKeptApart() throws {
        let first = try makePhoto("A.DNG")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Other"), withIntermediateDirectories: true)
        let second = try makePhoto("Other/A.DNG", width: 1000, height: 2000)
        _ = cache.thumbnail(for: first)
        _ = cache.thumbnail(for: second)
        #expect(cache.cachedThumbnail(for: first)?.width == 512)
        #expect(cache.cachedThumbnail(for: second)?.width == 256)
    }

    @Test("A folder's thumbnails arrive once each, cached ones first, and an unreadable file doesn't stop the rest")
    func folderStream() async throws {
        let photos = try ["1.DNG", "2.DNG", "3.DNG"].map { try makePhoto($0) }
        let broken = root.appendingPathComponent("broken.DNG")
        try Data("not a photo".utf8).write(to: broken)
        let missing = root.appendingPathComponent("gone.DNG")
        _ = cache.thumbnail(for: photos[2])

        var arrived: [(url: URL, image: CGImage?)] = []
        for await result in cache.thumbnails(for: photos + [broken, missing]) {
            arrived.append(result)
        }

        #expect(arrived.count == 5)
        #expect(Set(arrived.map(\.url)) == Set(photos + [broken, missing]))
        #expect(arrived.first?.url == photos[2])
        #expect(arrived.filter { $0.image == nil }.map(\.url).sorted { $0.path < $1.path } == [broken, missing])
        for photo in photos { #expect(cache.cachedThumbnail(for: photo) != nil) }
    }

    /// Stands in for `RAWRenderer`: a 100-pixel-wide image per exposure, counting renders.
    final class FakeRenderer: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _looks: [Look?] = []
        var count: Int { lock.withLock { _count } }
        /// The look of each edit rendered, in order.
        var looks: [Look?] { lock.withLock { _looks } }

        func render(_ url: URL, _ edit: EditRecipe) -> CGImage? {
            lock.withLock {
                _count += 1
                _looks.append(edit.look)
            }
            let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.setFillColor(CGColor(gray: min(1, max(0, 0.5 + edit.basic.exposure / 10)), alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
            return context?.makeImage()
        }
    }

    func edit(exposure: Double) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.exposure = exposure
        return recipe
    }

    @Test("An edited photo's thumbnail is rendered with its edit, stored, and rendered again when the edit changes")
    func editedThumbnail() async throws {
        let photo = try makePhoto("A.DNG")
        let renderer = FakeRenderer()
        let cache = ThumbnailCache(directory: root.appendingPathComponent("Cache"),
                                   renderEdit: { renderer.render($0, $1) })

        let edited = try #require(await cache.thumbnail(for: photo, edit: edit(exposure: 1)))
        #expect(edited.width == 100)
        _ = await cache.thumbnail(for: photo, edit: edit(exposure: 1))
        #expect(renderer.count == 1)

        _ = await cache.thumbnail(for: photo, edit: edit(exposure: 2))
        #expect(renderer.count == 2)
        #expect(storedFiles().count == 1)
    }

    @Test("A neutral edit shows the original's thumbnail without rendering")
    func neutralEditShowsOriginal() async throws {
        let photo = try makePhoto("A.DNG")
        let renderer = FakeRenderer()
        let cache = ThumbnailCache(directory: root.appendingPathComponent("Cache"),
                                   renderEdit: { renderer.render($0, $1) })
        let image = try #require(await cache.thumbnail(for: photo, edit: EditRecipe()))
        #expect(image.width == 512)
        #expect(renderer.count == 0)
    }

    @Test("Looking up the preview of a photo opening in Edit finds only a thumbnail of its current edit, and never renders one")
    func cachedEditedThumbnail() async throws {
        let photo = try makePhoto("A.DNG")
        let renderer = FakeRenderer()
        let cache = ThumbnailCache(directory: root.appendingPathComponent("Cache"),
                                   renderEdit: { renderer.render($0, $1) })
        #expect(cache.cachedThumbnail(for: photo, edit: edit(exposure: 1)) == nil)
        #expect(renderer.count == 0)

        _ = await cache.thumbnail(for: photo, edit: edit(exposure: 1))
        let cached = try #require(cache.cachedThumbnail(for: photo, edit: edit(exposure: 1)))
        #expect(cached.width == 100)
        #expect(cache.cachedThumbnail(for: photo, edit: edit(exposure: 2)) == nil)
        #expect(renderer.count == 1)

        _ = cache.thumbnail(for: photo)
        #expect(cache.cachedThumbnail(for: photo, edit: EditRecipe())?.width == 512)
    }

    @Test("A look whose LUT is missing is left out, and the thumbnail is made again when the LUT appears or changes")
    func lookFollowsItsLUT() async throws {
        let photo = try makePhoto("A.DNG")
        let renderer = FakeRenderer()
        let library = LUTLibrary(directory: root.appendingPathComponent("LUTs"))
        let cache = ThumbnailCache(directory: root.appendingPathComponent("Cache"),
                                   renderEdit: { renderer.render($0, $1) },
                                   lutVersion: { library.version(of: $0) })
        var looked = edit(exposure: 1)
        looked.look = Look(lut: "Warm.cube")

        // Missing: rendered without the look, and the same thumbnail as the edit without one.
        _ = await cache.thumbnail(for: photo, edit: looked)
        _ = await cache.thumbnail(for: photo, edit: edit(exposure: 1))
        #expect(renderer.count == 1)
        #expect(renderer.looks == [nil])

        let lut = root.appendingPathComponent("Warm.cube")
        try Data(LUTLibraryTests.cubeText().utf8).write(to: lut)
        _ = try await library.importFile(at: lut)
        _ = await cache.thumbnail(for: photo, edit: looked)
        #expect(renderer.count == 2)
        #expect(renderer.looks.last == Look(lut: "Warm.cube"))

        // The same name with other contents, as when a file is replaced in the Finder.
        try Data(LUTLibraryTests.cubeText(scale: 0.5).utf8).write(to: library.directory.appendingPathComponent("Warm.cube"))
        _ = await cache.thumbnail(for: photo, edit: looked)
        #expect(renderer.count == 3)
    }

    @Test("Photos listed as edited show the edit in their sidecar")
    func streamReadsSidecars() async throws {
        let edited = try makePhoto("A.DNG")
        let plain = try makePhoto("B.DNG")
        try Sidecar.save(edit(exposure: 1), for: edited, over: nil)
        let renderer = FakeRenderer()
        let cache = ThumbnailCache(directory: root.appendingPathComponent("Cache"),
                                   renderEdit: { renderer.render($0, $1) })

        var widths: [String: Int] = [:]
        for await (url, image) in cache.thumbnails(for: [edited, plain], edited: [edited]) {
            widths[url.lastPathComponent] = image?.width
        }
        #expect(widths == ["A.DNG": 100, "B.DNG": 512])
        #expect(renderer.count == 1)
    }

    // MARK: Size limit

    /// The size of one stored thumbnail of a photo made by `makePhoto`, which all have the same
    /// pixels and so the same JPEG.
    func thumbnailBytes() throws -> Int {
        let probe = ThumbnailCache(directory: root.appendingPathComponent("Probe"))
        #expect(probe.thumbnail(for: try makePhoto("Probe.png")) != nil)
        let file = try #require(FileManager.default.enumerator(at: probe.directory, includingPropertiesForKeys: nil)?
            .allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "jpg" })
        return try #require(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    func storedBytes(in cache: ThumbnailCache) -> Int {
        let enumerator = FileManager.default.enumerator(at: cache.directory, includingPropertiesForKeys: [.fileSizeKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jpg" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    @Test("The cache stays under its size limit as thumbnails are stored")
    func staysUnderLimit() throws {
        let bytes = try thumbnailBytes()
        let cache = ThumbnailCache(directory: root.appendingPathComponent("Limited"), maxBytes: bytes * 7 / 2)
        for index in 0..<8 {
            #expect(cache.thumbnail(for: try makePhoto("IMG_\(index).png")) != nil)
            #expect(storedBytes(in: cache) <= cache.maxBytes)
        }
        // Trimming goes to 90% of the limit, so three thumbnails remain after each trim.
        #expect(storedBytes(in: cache) >= bytes * 3)
    }

    @Test("The thumbnails read least recently are removed first")
    func removesLeastRecentlyRead() throws {
        let bytes = try thumbnailBytes()
        let cache = ThumbnailCache(directory: root.appendingPathComponent("Limited"), maxBytes: bytes * 7 / 2)
        let a = try makePhoto("A.png"), b = try makePhoto("B.png"), c = try makePhoto("C.png")
        for photo in [a, b, c] { #expect(cache.thumbnail(for: photo) != nil) }
        // Stored in the order A, B, C, an hour apart, so A is the oldest.
        for (hours, photo) in [(3.0, a), (2, b), (1, c)] {
            let file = try #require(cache.entry(for: photo, showing: .asShot)).file
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -hours * 3600)],
                                                  ofItemAtPath: file.path)
        }

        // Reading A makes B the least recently read, so a fourth thumbnail removes B.
        #expect(cache.cachedThumbnail(for: a) != nil)
        #expect(cache.thumbnail(for: try makePhoto("D.png")) != nil)
        #expect(cache.cachedThumbnail(for: b) == nil)
        #expect(cache.cachedThumbnail(for: a) != nil)
        #expect(cache.cachedThumbnail(for: c) != nil)
    }

    @Test("A cache that is already too large is trimmed when the next thumbnail is stored")
    func trimsExistingCacheOnFirstStore() throws {
        let bytes = try thumbnailBytes()
        let directory = root.appendingPathComponent("Shared")
        let unlimited = ThumbnailCache(directory: directory)
        for index in 0..<6 { #expect(unlimited.thumbnail(for: try makePhoto("IMG_\(index).png")) != nil) }

        let limited = ThumbnailCache(directory: directory, maxBytes: bytes * 7 / 2)
        #expect(limited.thumbnail(for: try makePhoto("New.png")) != nil)
        #expect(storedBytes(in: limited) <= limited.maxBytes)
        #expect(limited.cachedThumbnail(for: root.appendingPathComponent("New.png")) != nil)
    }

    #if os(macOS)
    @Test("On the Mac the cache stays in Application Support")
    func macDirectory() {
        #expect(ThumbnailCache.defaultDirectory == URL.applicationSupportDirectory.appendingPathComponent("Proof/Thumbnails"))
    }
    #endif
}

/// Times thumbnails for a whole folder, for issue #7. Runs only when `PROOF_SAMPLE_FOLDER` names a
/// folder of RAW photos, such as a copy on the NAS:
/// `PROOF_SAMPLE_FOLDER=/Volumes/photo/Trip swift test --filter ThumbnailTimingTests`.
/// The first visit starts from an empty cache; the second must finish in under a second.
@Suite(.serialized, .enabled(if: timingFolder != nil))
struct ThumbnailTimingTests {
    @Test("Folder thumbnail timings, first and second visit")
    func folderTimings() async throws {
        let folder = try #require(timingFolder)
        let urls = try FolderContents.read(at: folder).photos.map { folder.appendingPathComponent($0.name) }
        let cache = ThumbnailCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailTimingTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        var second: Double = 0
        for visit in ["First visit", "Second visit"] {
            let start = ContinuousClock.now
            var made = 0
            var sizes: Set<String> = []
            for await (_, image) in cache.thumbnails(for: urls) {
                if let image {
                    made += 1
                    sizes.insert("\(image.width)×\(image.height)")
                }
            }
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            print("\(visit): \(made) of \(urls.count) thumbnails in \(Int(ms)) ms, sizes \(sizes.sorted())")
            #expect(made == urls.count)
            second = ms
        }
        #expect(second < 1000)
    }
}

private let timingFolder = ProcessInfo.processInfo.environment["PROOF_SAMPLE_FOLDER"].map(URL.init(fileURLWithPath:))

/// Decision 0050: browsing never opens a photo in iCloud that isn't on the device.
struct ThumbnailCacheCloudTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailCacheCloudTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func marker() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try #require(context.makeImage())
    }

    /// A cache that treats `cloud` as not downloaded. The file doesn't exist, so opening it
    /// couldn't give an image: only the system thumbnail can.
    func cache(cloud: URL, marker: CGImage) -> ThumbnailCache {
        ThumbnailCache(directory: root.appendingPathComponent("Cache"),
                       isInCloud: { $0 == cloud },
                       cloudThumbnail: { url, _ in url == cloud ? marker : nil })
    }

    @Test("A photo that isn't downloaded gets the system thumbnail and nothing is stored")
    func cloudPhotoUsesSystemThumbnail() async throws {
        let marker = try Self.marker()
        let cloud = root.appendingPathComponent("IMG_1.DNG")
        let cache = cache(cloud: cloud, marker: marker)

        #expect(await cache.thumbnail(for: cloud, edit: nil)?.width == 4)
        #expect(cache.thumbnail(for: cloud) == nil)
        #expect(cache.cachedThumbnail(for: cloud, edit: nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }

    @Test("Browsing a folder gives photos that aren't downloaded their system thumbnail")
    func streamUsesSystemThumbnail() async throws {
        let marker = try Self.marker()
        let cloud = root.appendingPathComponent("IMG_1.DNG")
        let cache = cache(cloud: cloud, marker: marker)

        var results: [URL: CGImage?] = [:]
        for await (url, image) in cache.thumbnails(for: [cloud]) { results[url] = image }
        #expect(results.count == 1)
        #expect(results[cloud]??.width == 4)
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }
}
