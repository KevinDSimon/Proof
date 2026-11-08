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
