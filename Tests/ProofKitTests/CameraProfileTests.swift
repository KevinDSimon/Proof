import CoreImage
import Foundation
import ImageIO
import Testing
@testable import ProofKit

struct CameraProfileTests {
    /// The Leica M11's profile as ImageIO reads it: two color matrices, identity calibrations and
    /// a look table that changes nothing.
    static var m11: [String: Any] {[
        kCGImagePropertyDNGColorMatrix1 as String: [0.58, -0.13, -0.02, -0.61, 1.54, 0.07, -0.08, 0.22, 0.63],
        kCGImagePropertyDNGColorMatrix2 as String: [0.42, -0.08, -0.05, -0.57, 1.32, 0.26, -0.08, 0.17, 0.62],
        kCGImagePropertyDNGProfileLookTableData as String: Array(repeating: [0.0, 1.0, 1.0], count: 6).flatMap { $0 },
        kCGImagePropertyDNGDefaultCropSize as String: [9528, 6328],
    ]}

    @Test("A profile of color matrices and a look table that changes nothing is applied in full")
    func matricesAreAppliedInFull() {
        #expect(CameraProfiles.isAppliedInFull(Self.m11))
        #expect(CameraProfiles.embeddedSize(Self.m11) == CGSize(width: 9528, height: 6328))
    }

    @Test("A profile with forward matrices, a hue/sat map or a look table that changes colors is not applied in full",
          arguments: [kCGImagePropertyDNGForwardMatrix1, kCGImagePropertyDNGForwardMatrix2,
                      kCGImagePropertyDNGProfileHueSatMapData1, kCGImagePropertyDNGProfileHueSatMapData2].map { $0 as String })
    func ignoredTagsKeepApple(tag: String) {
        var dng = Self.m11
        dng[tag] = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(!CameraProfiles.isAppliedInFull(dng))
        #expect(CameraProfiles.embeddedSize(dng) == nil)
    }

    @Test("A look table that shifts a hue, or scales saturation or value, is not applied in full")
    func lookTableThatChangesColors() {
        for change in [(0, 5.0), (1, 1.2), (2, 0.9)] {
            var table = Array(repeating: [0.0, 1.0, 1.0], count: 6).flatMap { $0 }
            table[9 + change.0] = change.1
            var dng = Self.m11
            dng[kCGImagePropertyDNGProfileLookTableData as String] = table
            #expect(!CameraProfiles.isAppliedInFull(dng))
        }
    }

    @Test("A DNG without color matrices has no embedded profile to offer")
    func noMatrices() {
        #expect(!CameraProfiles.isAppliedInFull([kCGImagePropertyDNGDefaultCropSize as String: [100, 100]]))
    }

    @Test("The embedded profile uses the newest .dng decoder version")
    func newestDNGDecoder() {
        #expect(CameraProfiles.newestDNGDecoder(in: ["6.dng", "7", "7.dng", "8", "8.dng", "9.dng"]) == "9.dng")
        #expect(CameraProfiles.newestDNGDecoder(in: ["9.dng", "10.dng", "8"]) == "10.dng")
        #expect(CameraProfiles.newestDNGDecoder(in: ["7", "8"]) == nil)
    }

    @Test("Labels name whose profile it is")
    func labels() {
        let leica = CameraProfiles(model: "LEICA M11", embeddedDecoder: "9.dng", isEmbeddedOnly: false)
        #expect(leica.offersChoice)
        #expect(leica.label(for: .embedded) == "LEICA M11 (embedded)")
        #expect(leica.label(for: .apple) == "Apple")
        let iPhone = CameraProfiles(model: "iPhone 16 Pro", embeddedDecoder: nil, isEmbeddedOnly: true)
        #expect(!iPhone.offersChoice)
        #expect(iPhone.label(for: .embedded) == "iPhone 16 Pro (embedded)")
        #expect(iPhone.label(for: .apple) == "iPhone 16 Pro (embedded)")
        let sony = CameraProfiles(model: "ILCE-7M4", embeddedDecoder: nil, isEmbeddedOnly: false)
        #expect(sony.label(for: .embedded) == "Apple · ILCE-7M4")
        #expect(sony.label(for: .apple) == "Apple · ILCE-7M4")
    }

    @Test("A photo with one profile uses it whatever the edit asks for")
    func resolvesToTheOnlyProfile() {
        let iPhone = CameraProfiles(model: nil, embeddedDecoder: nil, isEmbeddedOnly: true)
        let sony = CameraProfiles(model: nil, embeddedDecoder: nil, isEmbeddedOnly: false)
        let leica = CameraProfiles(model: nil, embeddedDecoder: "9.dng", isEmbeddedOnly: false)
        for profile in CameraProfile.allCases {
            #expect(iPhone.resolved(profile) == .embedded)
            #expect(sony.resolved(profile) == .apple)
            #expect(leica.resolved(profile) == profile)
        }
    }

    // MARK: Recipe

    @Test("A new edit starts with the embedded profile at process version 2")
    func newEditIsEmbedded() throws {
        let recipe = EditRecipe()
        #expect(recipe.profile == .embedded && recipe.processVersion == 2)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        #expect(object?["profile"] as? String == "embedded")
    }

    @Test("An edit saved at process version 1 keeps Apple's profile, as it always rendered")
    func processVersion1KeepsApple() throws {
        let json = #"{"formatVersion": 3, "processVersion": 1, "basic": {"exposure": 0.5}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.profile == .apple)
        #expect(recipe.processVersion == 1)
        let again = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(again == recipe)
    }

    @Test("A process version 2 edit's profile survives a round trip")
    func profileRoundTrip() throws {
        for profile in CameraProfile.allCases {
            let recipe = EditRecipe(profile: profile)
            #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)).profile == profile)
        }
        let json = #"{"formatVersion": 3, "processVersion": 2}"#
        #expect(try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8)).profile == .embedded)
    }

    @Test("Apple's profile is a change from where the photo starts, and Show Original keeps it")
    func appleIsNotNeutral() {
        var recipe = EditRecipe()
        #expect(recipe.isNeutral)
        recipe.profile = .apple
        #expect(!recipe.isNeutral)
        #expect(recipe.original.profile == .apple)
        #expect(recipe.changeLabel(from: EditRecipe()) == "Profile: Apple")
    }

    @Test("Profile is copied by default")
    func copiedByDefault() {
        #expect(SettingsItem.defaultItems.contains(.profile))
        let pasted = EditRecipe().pasting(CopiedSettings(from: EditRecipe(profile: .apple), items: [.profile]))
        #expect(pasted.profile == .apple)
    }

    // MARK: Sample photo

    @Test("The Leica M11 sample offers its embedded profile and Apple's, each with its own frame and colors",
          .enabled(if: sampleDNG != nil))
    func sampleOffersBoth() async throws {
        let url = try #require(sampleDNG)
        let profiles = try #require(CameraProfiles.of(url))
        #expect(profiles.offersChoice)
        #expect(profiles.label(for: .embedded) == "LEICA M11 (embedded)")
        #expect(profiles.defaults(for: .embedded)?.orientedSize == CGSize(width: 9528, height: 6328))
        #expect(profiles.defaults(for: .apple)?.orientedSize == CGSize(width: 9504, height: 6320))

        let renderer = try RAWRenderer()
        try await renderer.open(url)
        let size = CGSize(width: 400, height: 400)
        let embedded = try await renderer.render(fitting: size, recipe: EditRecipe(profile: .embedded))
        let apple = try await renderer.render(fitting: size, recipe: EditRecipe(profile: .apple))
        #expect(embedded.photoSize == CGSize(width: 9528, height: 6328))
        #expect(apple.photoSize == CGSize(width: 9504, height: 6320))
        // Switching back renders Apple's profile exactly as a renderer that never switched.
        let fresh = try RAWRenderer()
        try await fresh.open(url)
        let again = try await fresh.render(fitting: size, recipe: EditRecipe(profile: .apple))
        #expect(try pixels(apple, renderer) == pixels(again, fresh))
        #expect(try pixels(apple, renderer) != pixels(embedded, renderer))
    }

    @Test("A thumbnail follows the edit's profile", .enabled(if: sampleDNG != nil))
    func thumbnailFollowsProfile() async throws {
        let url = try #require(sampleDNG)
        let renderer = try RAWRenderer()
        let embedded = try await renderer.thumbnail(of: url, recipe: EditRecipe(profile: .embedded), maxPixelSize: 256)
        let apple = try await renderer.thumbnail(of: url, recipe: EditRecipe(profile: .apple), maxPixelSize: 256)
        #expect(embedded.dataProvider?.data as Data? != apple.dataProvider?.data as Data?)
    }

    private func pixels(_ photo: RenderedPhoto, _ renderer: RAWRenderer) throws -> [UInt8] {
        let image = try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
                           colorSpace: RAWRenderer.colorSpace)
        return bytes
    }
}

extension EditRecipe {
    /// Whether the edit is neutral apart from its profile: edits saved at process version 1 read
    /// as Apple's profile, which isn't where a photo that offers a choice starts.
    var isNeutralButProfile: Bool {
        var recipe = self
        recipe.profile = .embedded
        return recipe.isNeutral
    }
}
