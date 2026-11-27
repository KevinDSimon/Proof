import CoreGraphics
import Foundation
import Testing
@testable import ProofKit

struct LUTLibraryTests {
    let root: URL
    let library: LUTLibrary

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LUTLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LUTLibrary(directory: root.appendingPathComponent("LUTs"))
    }

    /// A 2-per-side 3D table that maps each corner to `corner * scale`.
    static func cubeText(scale: Float = 1) -> String {
        var lines = ["LUT_3D_SIZE 2"]
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { lines.append("\(Float(r) * scale) \(Float(g) * scale) \(Float(b) * scale)") } } }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    func makeFile(_ name: String, _ text: String = cubeText()) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("A library that has never been imported into is empty")
    func emptyAtFirst() {
        #expect(library.names().isEmpty)
    }

    @Test("Importing copies the file into the library and leaves the original")
    func importCopies() async throws {
        let original = try makeFile("Portra.cube")
        let name = try await library.importFile(at: original)
        #expect(name == "Portra.cube")
        #expect(library.names() == ["Portra.cube"])
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: library.directory.appendingPathComponent(name)) == Data(contentsOf: original))
    }

    @Test("A file the parser refuses isn't added, and the error is the parser's")
    func importRejectsInvalid() async throws {
        let url = try makeFile("Broken.cube", "LUT_3D_SIZE 2\n0 0 0\n")
        await #expect(throws: LUTImportError(fileName: "Broken.cube", reason: .invalid(.wrongEntryCount(expected: 8, found: 1)))) {
            try await library.importFile(at: url)
        }
        #expect(library.names().isEmpty)
    }

    @Test("A file that isn't a .cube file isn't added")
    func importRejectsOtherFiles() async throws {
        let url = try makeFile("Portra.txt")
        await #expect(throws: LUTImportError(fileName: "Portra.txt", reason: .notCube)) {
            try await library.importFile(at: url)
        }
        #expect(library.names().isEmpty)
    }

    @Test("Importing the same file twice adds it once; another file with its name is numbered")
    func importNames() async throws {
        let first = try makeFile("Portra.cube")
        #expect(try await library.importFile(at: first) == "Portra.cube")
        #expect(try await library.importFile(at: first) == "Portra.cube")

        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let second = other.appendingPathComponent("Portra.cube")
        try Data(Self.cubeText(scale: 0.5).utf8).write(to: second)
        #expect(try await library.importFile(at: second) == "Portra 2.cube")
        #expect(library.names() == ["Portra.cube", "Portra 2.cube"])
    }

    @Test("Names are listed as the Finder sorts them, and only .cube files")
    func namesSorted() async throws {
        for name in ["Look 10.cube", "look 2.CUBE", "Look 1.cube"] {
            _ = try await library.importFile(at: try makeFile(name))
        }
        try Data().write(to: library.directory.appendingPathComponent("notes.txt"))
        #expect(library.names() == ["Look 1.cube", "look 2.CUBE", "Look 10.cube"])
    }

    @Test("A LUT is loaded by its name; a missing one, or a name leading out of the library, is nil")
    func loadsByName() async throws {
        _ = try await library.importFile(at: try makeFile("Portra.cube"))
        #expect(await library.lut(named: "Portra.cube")?.size == 2)
        #expect(await library.lut(for: Look(lut: "Portra.cube"))?.size == 2)
        #expect(await library.lut(for: nil) == nil)
        #expect(await library.lut(named: "Gone.cube") == nil)
        try makeFile("Outside.cube")
        #expect(await library.lut(named: "../Outside.cube") == nil)
    }

    @Test("Importing a folder keeps its name and subfolders, and leaves out other files")
    func importFolder() async throws {
        let portra = root.appendingPathComponent("Portra")
        try FileManager.default.createDirectory(at: portra.appendingPathComponent("Pushed"), withIntermediateDirectories: true)
        try makeFile("Portra/400.cube")
        try makeFile("Portra/800.cube")
        try makeFile("Portra/Pushed/1600.cube")
        try makeFile("Portra/Broken.cube", "LUT_3D_SIZE 2\n0 0 0\n")
        try makeFile("Portra/readme.txt", "Notes")

        let (names, failures) = await library.importItem(at: portra)
        #expect(Set(names) == ["Portra/400.cube", "Portra/800.cube", "Portra/Pushed/1600.cube"])
        #expect(failures == [LUTImportError(fileName: "Portra/Broken.cube",
                                            reason: .invalid(.wrongEntryCount(expected: 8, found: 1)))])
        #expect(library.names() == ["Portra/Pushed/1600.cube", "Portra/400.cube", "Portra/800.cube"])
        #expect(await library.lut(named: "Portra/Pushed/1600.cube")?.size == 2)
        // Importing it again adds nothing.
        _ = await library.importItem(at: portra)
        #expect(library.names().count == 3)
    }

    @Test("A folder without .cube files isn't added")
    func importEmptyFolder() async throws {
        let empty = root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try makeFile("Empty/readme.txt", "Notes")
        let (names, failures) = await library.importItem(at: empty)
        #expect(names.isEmpty)
        #expect(failures == [LUTImportError(fileName: "Empty", reason: .noLUTs)])
    }

    @Test("Folders are listed before the LUTs beside them, each followed by its contents")
    func foldersFirst() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Portra"), withIntermediateDirectories: true)
        try makeFile("Portra/400.cube")
        _ = await library.importItem(at: root.appendingPathComponent("Portra"))
        _ = try await library.importFile(at: try makeFile("Agfa.cube"))
        _ = try await library.importFile(at: try makeFile("Zeiss.cube"))
        #expect(library.names() == ["Portra/400.cube", "Agfa.cube", "Zeiss.cube"])
    }

    @Test("Looks are grouped by the folder that holds them, not by their subfolders")
    func groupedByFolder() {
        let names = ["Portra/Pushed/1600.cube", "Portra/400.cube", "Portra/800.cube", "Agfa.cube"]
        #expect(LUTLibrary.folders(in: names) == ["Portra/Pushed", "Portra", ""])
        #expect(LUTLibrary.names(names, in: "Portra") == ["Portra/400.cube", "Portra/800.cube"])
        #expect(LUTLibrary.names(names, in: "") == ["Agfa.cube"])
        #expect(LUTLibrary.folder(of: "Portra/Pushed/1600.cube") == "Portra/Pushed")
        #expect(LUTLibrary.folder(of: "Agfa.cube") == "")
    }

    @Test("The folder menu lists the folders below each folder, including ones that hold only folders")
    func childFolders() {
        let folders = LUTLibrary.folders(in: ["Film/Kodak/Portra.cube", "Film/Fuji/Velvia.cube",
                                              "Film/Kodak/Old/Ektachrome.cube", "Teal.cube", "Mono/Grey.cube"])
        #expect(folders == ["Film/Kodak", "Film/Fuji", "Film/Kodak/Old", "", "Mono"])
        #expect(LUTLibrary.childFolders(of: "", in: folders) == ["Film", "Mono"])
        #expect(LUTLibrary.childFolders(of: "Film", in: folders) == ["Film/Kodak", "Film/Fuji"])
        #expect(LUTLibrary.childFolders(of: "Film/Kodak", in: folders) == ["Film/Kodak/Old"])
        #expect(LUTLibrary.childFolders(of: "Mono", in: folders).isEmpty)
        // A folder whose name only starts with another's isn't below it.
        #expect(LUTLibrary.childFolders(of: "Fil", in: folders).isEmpty)
    }

    @Test("A file is read through a file coordinator, and a missing one can't be read")
    func coordinatedRead() throws {
        let url = try makeFile("Portra.cube")
        #expect(LUTLibrary.coordinatedData(at: url) == Data(Self.cubeText().utf8))
        #expect(LUTLibrary.coordinatedData(at: root.appendingPathComponent("Missing.cube")) == nil)
    }

    @Test("A look saved with a file name only, before folders, still loads; paths can't leave the library")
    func pathsAndPlainNames() async throws {
        _ = try await library.importFile(at: try makeFile("Portra.cube"))
        let saved = try JSONDecoder().decode(Look.self, from: Data(#"{"lut": "Portra.cube", "strength": 0.5}"#.utf8))
        #expect(await library.lut(for: saved)?.size == 2)
        for name in ["Portra/../../Outside.cube", "/Portra.cube", "Portra//400.cube", ".hidden/Portra.cube"] {
            #expect(await library.lut(named: name) == nil)
        }
    }

    @Test("A LUT's version changes with its file, and is nil when the file is missing or outside the library")
    func versions() async throws {
        #expect(library.version(of: "Portra.cube") == nil)
        _ = try await library.importFile(at: try makeFile("Portra.cube"))
        let first = try #require(library.version(of: "Portra.cube"))
        try Data(Self.cubeText(scale: 0.5).utf8).write(to: library.directory.appendingPathComponent("Portra.cube"))
        #expect(library.version(of: "Portra.cube") != first)
        try makeFile("Outside.cube")
        #expect(library.version(of: "../Outside.cube") == nil)
    }

    @Test("Over the memory limit, the least recently used LUT is let go")
    func evictsLeastRecentlyUsed() async throws {
        // A 2-per-side table prepares to 8 entries of 16 bytes.
        let library = LUTLibrary(directory: root.appendingPathComponent("Small"), memoryLimit: 256)
        for name in ["A.cube", "B.cube", "C.cube"] {
            _ = try await library.importFile(at: try makeFile(name))
        }
        _ = await library.lut(named: "A.cube")
        _ = await library.lut(named: "B.cube")
        _ = await library.lut(named: "A.cube")
        _ = await library.lut(named: "C.cube")
        #expect(await library.cachedNames == ["A.cube", "C.cube"])
        // A LUT that was let go loads again.
        #expect(await library.lut(named: "B.cube")?.size == 2)
    }

    @Test("A look preview applies the LUT to a thumbnail in full")
    func lookPreview() async throws {
        let width = 4
        let context = try #require(CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: RAWRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for (x, gray) in [0.0, 0.25, 0.5, 1].enumerated() {
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 1))
        }
        let thumbnail = try #require(context.makeImage())
        let renderer = try RAWRenderer()

        let identity = try await renderer.applying(PreparedLUT(LUTStageTests.identity), to: thumbnail)
        let inverted = try await renderer.applying(PreparedLUT(LUTStageTests.invert), to: thumbnail)
        #expect(identity.width == width && identity.height == 1)
        let before = try Self.reds(of: thumbnail), same = try Self.reds(of: identity), flipped = try Self.reds(of: inverted)
        for x in 0..<width {
            #expect(abs(Int(same[x]) - Int(before[x])) <= 2)
            #expect(abs(Int(flipped[x]) - (255 - Int(before[x]))) <= 3)
        }
    }

    /// The red channel of each pixel in a one-row image, in Display P3.
    static func reds(of image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: 1, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: RAWRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: 1))
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
    }

    // MARK: Renaming and removing

    /// Imports a folder "Portra" holding "400.cube" and "800.cube".
    func importPortra() async throws {
        let folder = root.appendingPathComponent("Portra")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeFile("Portra/400.cube")
        try makeFile("Portra/800.cube", Self.cubeText(scale: 0.5))
        _ = await library.importItem(at: folder)
    }

    @Test("Renaming a LUT keeps it in its folder and adds .cube when the name leaves it out")
    func renameLUT() async throws {
        try await importPortra()
        let renamed = try await library.rename("Portra/400.cube", to: "400 Warm")
        #expect(renamed == "Portra/400 Warm.cube")
        #expect(library.names() == ["Portra/400 Warm.cube", "Portra/800.cube"])
        #expect(await library.lut(named: "Portra/400 Warm.cube") != nil)
    }

    @Test("A renamed LUT is no longer found by its old path, even once it was prepared")
    func renameForgetsOldPath() async throws {
        try await importPortra()
        #expect(await library.lut(named: "Portra/400.cube") != nil)
        _ = try await library.rename("Portra/400.cube", to: "Gold")
        #expect(await library.lut(named: "Portra/400.cube") == nil)
        #expect(await !library.cachedNames.contains("Portra/400.cube"))
    }

    @Test("Renaming a folder moves the LUTs in it")
    func renameFolder() async throws {
        try await importPortra()
        let renamed = try await library.rename("Portra", to: "Kodak")
        #expect(renamed == "Kodak")
        #expect(library.names() == ["Kodak/400.cube", "Kodak/800.cube"])
    }

    @Test("A name another LUT beside it has, or one that leads out of the folder, is refused")
    func renameRefusesTakenAndInvalidNames() async throws {
        try await importPortra()
        await #expect(throws: LUTLibraryError.nameTaken("800")) { try await library.rename("Portra/400.cube", to: "800") }
        for name in ["", "  ", ".hidden", "../Up", "a/b", ".cube"] {
            await #expect(throws: LUTLibraryError.invalidName) { try await library.rename("Portra/400.cube", to: name) }
        }
        await #expect(throws: LUTLibraryError.notFound) { try await library.rename("Portra/200.cube", to: "Gold") }
        #expect(library.names() == ["Portra/400.cube", "Portra/800.cube"])
    }

    @Test("Changing only the case of a name renames the file")
    func renameCase() async throws {
        try await importPortra()
        let renamed = try await library.rename("Portra", to: "PORTRA")
        #expect(renamed == "PORTRA")
        #expect(library.names() == ["PORTRA/400.cube", "PORTRA/800.cube"])
    }

    @Test("Removing a LUT deletes the library's copy and leaves the imported original")
    func removeLUT() async throws {
        try await importPortra()
        #expect(await library.lut(named: "Portra/400.cube") != nil)
        try await library.remove("Portra/400.cube")
        #expect(library.names() == ["Portra/800.cube"])
        #expect(await library.lut(named: "Portra/400.cube") == nil)
        #expect(library.version(of: "Portra/400.cube") == nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Portra/400.cube").path))
    }

    @Test("Removing a folder removes every LUT in it")
    func removeFolder() async throws {
        try await importPortra()
        try await library.remove("Portra")
        #expect(library.names().isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Portra/800.cube").path))
    }

    @Test("A path that leads out of the library is never removed")
    func removeRefusesPathsOutside() async throws {
        try makeFile("Outside.cube")
        await #expect(throws: LUTLibraryError.notFound) { try await library.remove("../Outside.cube") }
        await #expect(throws: LUTLibraryError.notFound) { try await library.remove("") }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Outside.cube").path))
    }

}
