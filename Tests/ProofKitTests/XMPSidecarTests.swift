import Foundation
import Testing
@testable import ProofKit

struct XMPSidecarTests {
    /// The layout ImageIO writes, as Photomator does: each property an element.
    static let photomator = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
           <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                    xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
                    xmlns:dc="http://purl.org/dc/elements/1.1/">
                 <xmp:Rating>5</xmp:Rating>
                 <xmpDM:pick>1</xmpDM:pick>
                 <xmpDM:good>True</xmpDM:good>
                 <xmp:CreatorTool>Photomator</xmp:CreatorTool>
                 <dc:subject>
                    <rdf:Bag>
                       <rdf:li>Leica</rdf:li>
                    </rdf:Bag>
                 </dc:subject>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

    /// The layout Lightroom writes: simple properties as attributes, structures as elements.
    static let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           xmp:Rating="2"
           xmp:Label="Red"
           xmpDM:pick="0"
           crs:Exposure2012="+0.35">
           <crs:ToneCurvePV2012>
            <rdf:Seq>
             <rdf:li>0, 0</rdf:li>
             <rdf:li>255, 255</rdf:li>
            </rdf:Seq>
           </crs:ToneCurvePV2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """

    func updated(_ xmp: String, _ metadata: PhotoMetadata) throws -> String {
        String(decoding: try XMPSidecar.updated(Data(xmp.utf8), to: metadata), as: UTF8.self)
    }

    @Test("A Photomator sidecar keeps its elements and every other tag when the rating and flag change")
    func photomatorRoundTrip() throws {
        let rejected = try updated(Self.photomator, PhotoMetadata(rating: 2, flag: .rejected))
        #expect(rejected == Self.photomator
            .replacingOccurrences(of: "<xmp:Rating>5<", with: "<xmp:Rating>2<")
            .replacingOccurrences(of: "<xmpDM:pick>1<", with: "<xmpDM:pick>-1<")
            .replacingOccurrences(of: "<xmpDM:good>True<", with: "<xmpDM:good>False<"))
        #expect(PhotoMetadata(xmp: Data(rejected.utf8)) == PhotoMetadata(rating: 2, flag: .rejected))

        let unflagged = try updated(Self.photomator, PhotoMetadata(rating: 5, flag: .unflagged))
        #expect(unflagged == Self.photomator
            .replacingOccurrences(of: "<xmpDM:pick>1<", with: "<xmpDM:pick>0<")
            .replacingOccurrences(of: "\n         <xmpDM:good>True</xmpDM:good>", with: ""))
    }

    @Test("A Lightroom sidecar keeps its attributes and every other tag when the rating and flag change")
    func lightroomRoundTrip() throws {
        let flagged = try updated(Self.lightroom, PhotoMetadata(rating: 4, flag: .flagged, label: "Red"))
        #expect(flagged == Self.lightroom
            .replacingOccurrences(of: #"xmp:Rating="2""#, with: #"xmp:Rating="4""#)
            .replacingOccurrences(of: #"xmpDM:pick="0""#, with: #"xmpDM:pick="1""#)
            .replacingOccurrences(of: #"crs:Exposure2012="+0.35""#, with: "crs:Exposure2012=\"+0.35\"\n   xmpDM:good=\"True\""))
        #expect(PhotoMetadata(xmp: Data(flagged.utf8)) == PhotoMetadata(rating: 4, flag: .flagged, label: "Red"))

        let unflagged = try updated(flagged, PhotoMetadata(rating: 4, flag: .unflagged))
        #expect(unflagged == Self.lightroom.replacingOccurrences(of: #"xmp:Rating="2""#, with: #"xmp:Rating="4""#))
    }

    @Test("Missing tags are added in the description's form, with their namespace")
    func addsMissingTags() throws {
        let elements = try updated(XMPSamples.photomator, PhotoMetadata(rating: 3, flag: .flagged))
        #expect(elements.contains(#"xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/""#))
        #expect(elements.contains("<xmpDM:pick>1</xmpDM:pick>"))
        #expect(elements.contains("<xmp:CreatorTool>2.2.1</xmp:CreatorTool>"))
        #expect(PhotoMetadata(xmp: Data(elements.utf8)) == PhotoMetadata(rating: 3, flag: .flagged))

        let attributes = try updated(XMPSamples.captureOne, PhotoMetadata(rating: 1, flag: .rejected, label: "Orange"))
        #expect(attributes.contains(#"photoshop:Urgency="2" xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/" xmpDM:pick="-1" xmpDM:good="False"/>"#))
        #expect(PhotoMetadata(xmp: Data(attributes.utf8)) == PhotoMetadata(rating: 1, flag: .rejected, label: "Orange"))
    }

    @Test("A Bridge rejection, a rating of -1, gives way to the stars and flag set in Proof")
    func bridgeReject() throws {
        let xmp = try updated(XMPSamples.bridgeReject, PhotoMetadata(rating: 0, flag: .flagged))
        #expect(PhotoMetadata(xmp: Data(xmp.utf8)) == PhotoMetadata(rating: 0, flag: .flagged))
    }

    @Test("Tags are changed under whatever prefix the sidecar uses")
    func otherPrefix() throws {
        let xmp = XMPSamples.wrap("""
            <rdf:Description rdf:about="" xmlns:a="http://ns.adobe.com/xap/1.0/"
              xmlns:dm="http://ns.adobe.com/xmp/1.0/DynamicMedia/" a:Rating="2" dm:pick="1"/>
            """)
        let result = try updated(xmp, PhotoMetadata(rating: 5, flag: .rejected))
        #expect(result.contains(#"a:Rating="5" dm:pick="-1" dm:good="False"/>"#))
        #expect(!result.contains("xmlns:xmp="))
    }

    @Test("A file that isn't XMP is left alone")
    func notXMP() {
        #expect(throws: XMPSidecar.SaveError.unrecognized) {
            try XMPSidecar.updated(Data("not xmp".utf8), to: PhotoMetadata(rating: 3))
        }
    }

    // MARK: Files

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Without a sidecar, IMG.xmp is created with only the rating and flag, and the photo is untouched")
    func createsSidecar() throws {
        let folder = try folder()
        let photo = folder.appendingPathComponent("IMG_1.DNG")
        let original = Data("raw bytes".utf8)
        try original.write(to: photo)

        let url = try XMPSidecar.save(PhotoMetadata(rating: 4, flag: .flagged), for: photo)
        #expect(url.lastPathComponent == "IMG_1.xmp")
        #expect(PhotoMetadata(xmp: try Data(contentsOf: url)) == PhotoMetadata(rating: 4, flag: .flagged))
        #expect(try Data(contentsOf: photo) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["IMG_1.DNG", "IMG_1.xmp"])
    }

    @Test("A new sidecar keeps the label from the XMP inside the photo, which it takes the place of")
    func newSidecarKeepsEmbeddedLabel() throws {
        let photo = try folder().appendingPathComponent("IMG_1.tif")
        try XMPSamples.writeImage(to: photo, xmp: XMPSamples.lightroom(rating: 1, pick: 0, good: nil, label: "Green"))
        let original = try Data(contentsOf: photo)

        let url = try XMPSidecar.save(PhotoMetadata(rating: 3), for: photo)
        #expect(PhotoMetadata(xmp: try Data(contentsOf: url)) == PhotoMetadata(rating: 3, label: "Green"))
        #expect(try Data(contentsOf: photo) == original)
    }

    @Test("The sidecar Proof read is the one written, by its name on disk, and the photo is untouched")
    func writesExistingSidecar() throws {
        let folder = try folder()
        let photo = folder.appendingPathComponent("IMG_1.DNG")
        try Data("raw bytes".utf8).write(to: photo)
        let older = folder.appendingPathComponent("IMG_1.XMP")
        let newer = folder.appendingPathComponent("IMG_1.DNG.xmp")
        try Data(XMPSamples.rating(1).utf8).write(to: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: older.path)
        try Data(Self.lightroom.utf8).write(to: newer)

        #expect(try XMPSidecar.save(PhotoMetadata(rating: 5, label: "Red"), for: photo).lastPathComponent == "IMG_1.DNG.xmp")
        #expect(PhotoMetadata(xmp: try Data(contentsOf: newer)) == PhotoMetadata(rating: 5, label: "Red"))
        #expect(try String(contentsOf: older, encoding: .utf8) == XMPSamples.rating(1))
        #expect(try Data(contentsOf: photo) == Data("raw bytes".utf8))

        try FileManager.default.removeItem(at: newer)
        #expect(try XMPSidecar.save(PhotoMetadata(rating: 2), for: photo).lastPathComponent == "IMG_1.XMP")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["IMG_1.DNG", "IMG_1.XMP"])
    }
}
