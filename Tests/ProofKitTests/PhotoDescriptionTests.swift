import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ProofKit

struct PhotoDescriptionTests {
    /// The description fields as Lightroom Classic writes them to a sidecar.
    static let lightroom = XMPSamples.wrap("""
        <rdf:Description rdf:about=""
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
          xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
          photoshop:City="Berlin"
          photoshop:State="Berlin"
          photoshop:Country="Germany"
          Iptc4xmpCore:Location="Tempelhof">
          <dc:title>
           <rdf:Alt>
            <rdf:li xml:lang="de">Feld</rdf:li>
            <rdf:li xml:lang="x-default">Field</rdf:li>
           </rdf:Alt>
          </dc:title>
          <dc:description>
           <rdf:Alt>
            <rdf:li xml:lang="x-default">Kites over the runway</rdf:li>
           </rdf:Alt>
          </dc:description>
          <dc:creator>
           <rdf:Seq>
            <rdf:li>Ana Ruiz</rdf:li>
            <rdf:li>Sam Lee</rdf:li>
           </rdf:Seq>
          </dc:creator>
          <dc:rights>
           <rdf:Alt>
            <rdf:li xml:lang="x-default">© 2026 Ana Ruiz</rdf:li>
           </rdf:Alt>
          </dc:rights>
          <dc:subject>
           <rdf:Bag>
            <rdf:li>kites</rdf:li>
            <rdf:li>Berlin</rdf:li>
           </rdf:Bag>
          </dc:subject>
        </rdf:Description>
        """)

    static let field = PhotoDescription(
        title: "Field", caption: "Kites over the runway", keywords: ["kites", "Berlin"], creator: "Ana Ruiz; Sam Lee",
        copyright: "© 2026 Ana Ruiz", sublocation: "Tempelhof", city: "Berlin", state: "Berlin", country: "Germany")

    @Test("Every field is read from a Lightroom sidecar, with the title in the default language")
    func readsLightroom() {
        #expect(PhotoDescription(xmp: Data(Self.lightroom.utf8)) == Self.field)
    }

    @Test("A sidecar without description fields reads as empty")
    func readsEmpty() {
        #expect(PhotoDescription(xmp: Data(XMPSamples.rating(3).utf8))?.isEmpty == true)
    }

    @Test("Saving trims fields and drops blank and repeated keywords")
    func normalizes() {
        let typed = PhotoDescription(title: "  Field ", keywords: ["kites", " ", "kites", "Berlin "], creator: "Ana; ; Sam")
        #expect(typed.normalized == PhotoDescription(title: "Field", keywords: ["kites", "Berlin"], creator: "Ana; Sam"))
    }

    @Test("Keywords typed in one field are separated by commas")
    func keywordsFromText() {
        #expect(PhotoDescription.keywords(from: "kites, Berlin,,  runway ") == ["kites", "Berlin", "runway"])
    }

    @Test("A photo without XMP shows the artist and copyright its camera recorded")
    func cameraArtist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tif")
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        let properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Ana Ruiz",
                                                           kCGImagePropertyTIFFCopyright: "© Ana Ruiz"]]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let description = PhotoDescription.read(for: url)
        #expect(description.creator == "Ana Ruiz")
        #expect(description.copyright == "© Ana Ruiz")
    }
}
