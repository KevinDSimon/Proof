import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ProofKit

/// XMP the way each app writes it, trimmed to the tags Proof reads.
enum XMPSamples {
    static func wrap(_ description: String) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          \(description)
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    static func rating(_ stars: Int) -> String {
        wrap(#"<rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="\#(stars)"/>"#)
    }

    /// Photomator writes each tag as an element rather than an attribute.
    static let photomator = wrap("""
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
         <xmp:CreatorTool>2.2.1</xmp:CreatorTool>
         <xmp:Rating>5</xmp:Rating>
        </rdf:Description>
        """)

    static func lightroom(rating: Int, pick: Int, good: String?, label: String) -> String {
        let good = good.map { #" xmpDM:good="\#($0)""# } ?? ""
        return wrap("""
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
              xmp:Rating="\(rating)" xmp:Label="\(label)" xmpDM:pick="\(pick)"\(good)/>
            """)
    }

    static let bridgeReject = rating(-1)

    static let captureOne = wrap("""
        <rdf:Description rdf:about=""
          xmlns:xmp="http://ns.adobe.com/xap/1.0/"
          xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
          xmp:Rating="4" xmp:Label="Orange" photoshop:Urgency="2"/>
        """)

    static let darktable = wrap("""
        <rdf:Description rdf:about=""
          xmlns:xmp="http://ns.adobe.com/xap/1.0/"
          xmlns:darktable="http://darktable.sf.net/"
          xmp:Rating="-1">
         <darktable:colorlabels><rdf:Seq><rdf:li>0</rdf:li></rdf:Seq></darktable:colorlabels>
        </rdf:Description>
        """)

    /// A small image with `xmp` embedded, standing in for a DNG that Lightroom wrote into.
    static func writeImage(to url: URL, xmp: String) throws {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let metadata = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

struct PhotoMetadataTests {
    func read(_ xmp: String) -> PhotoMetadata? {
        PhotoMetadata(xmp: Data(xmp.utf8))
    }

    @Test("Photomator's sidecars, with tags written as elements, give their stars")
    func photomator() {
        #expect(read(XMPSamples.photomator) == PhotoMetadata(rating: 5))
    }

    @Test("Lightroom's pick flag marks a photo flagged, unflagged or rejected")
    func lightroomFlags() {
        #expect(read(XMPSamples.lightroom(rating: 3, pick: 1, good: "true", label: "Red"))
                == PhotoMetadata(rating: 3, flag: .flagged, label: "Red"))
        #expect(read(XMPSamples.lightroom(rating: 2, pick: 0, good: nil, label: "Green"))?.flag == .unflagged)
        #expect(read(XMPSamples.lightroom(rating: 5, pick: -1, good: "false", label: "Blue"))
                == PhotoMetadata(rating: 5, flag: .rejected, label: "Blue"))
    }

    @Test("xmpDM:good stands in for the flag when xmpDM:pick is missing")
    func goodWithoutPick() {
        let flagged = XMPSamples.wrap(#"<rdf:Description rdf:about="" xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/" xmpDM:good="True"/>"#)
        let rejected = XMPSamples.wrap(#"<rdf:Description rdf:about="" xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/" xmpDM:good="False"/>"#)
        #expect(read(flagged)?.flag == .flagged)
        #expect(read(rejected)?.flag == .rejected)
    }

    @Test("A rating of -1, written by Bridge and darktable, means rejected with no stars")
    func ratingMinusOne() {
        #expect(read(XMPSamples.bridgeReject) == PhotoMetadata(rating: 0, flag: .rejected))
        #expect(read(XMPSamples.darktable) == PhotoMetadata(rating: 0, flag: .rejected))
    }

    @Test("Capture One's orange and pink labels are recognized as colors")
    func captureOne() {
        let metadata = read(XMPSamples.captureOne)
        #expect(metadata == PhotoMetadata(rating: 4, label: "Orange"))
        #expect(metadata?.color == .orange)
        #expect(PhotoMetadata(label: "pink").color == .pink)
    }

    @Test("A renamed or translated label is kept as written but has no color")
    func customLabel() {
        let metadata = read(XMPSamples.lightroom(rating: 1, pick: 0, good: nil, label: "Rot"))
        #expect(metadata?.label == "Rot")
        #expect(metadata?.color == nil)
    }

    @Test("Tags are found by namespace whatever prefix the app chose")
    func otherPrefix() {
        let xmp = XMPSamples.wrap("""
            <rdf:Description rdf:about="" xmlns:a="http://ns.adobe.com/xap/1.0/"
              xmlns:dm="http://ns.adobe.com/xmp/1.0/DynamicMedia/" a:Rating="2" dm:pick="1"/>
            """)
        #expect(read(xmp) == PhotoMetadata(rating: 2, flag: .flagged))
    }

    @Test("Decimal ratings are rounded and ratings out of range count as no stars")
    func unusualRatings() {
        let decimal = XMPSamples.wrap(#"<rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3.0"/>"#)
        #expect(read(decimal)?.rating == 3)
        #expect(read(XMPSamples.rating(7)) == PhotoMetadata.unrated)
        #expect(read(XMPSamples.rating(-2)) == PhotoMetadata.unrated)
    }

    @Test("Data that isn't XMP gives no metadata")
    func notXMP() {
        #expect(read("not xmp") == nil)
    }
}
