import Foundation
import Testing
@testable import ProofKit

struct FolderLocationTests {
    static func name(_ path: String) -> String {
        FolderLocation.filesName(of: URL(fileURLWithPath: path, isDirectory: true), deviceName: "On My iPad")
    }

    @Test("A folder in the device's own storage is named from On My iPad down")
    func onDevice() {
        let group = "/private/var/mobile/Containers/Shared/AppGroup/0C3F9D1E-6B2A-4F7E-9C1D-2A4B6C8D0E1F"
        #expect(Self.name(group + "/File Provider Storage/Proof Test") == "On My iPad › Proof Test")
        #expect(Self.name(group + "/File Provider Storage/Photos/2026") == "On My iPad › Photos › 2026")
        #expect(Self.name(group + "/File Provider Storage") == "On My iPad")
    }

    @Test("A folder in iCloud Drive is named from iCloud Drive down")
    func iCloudDrive() {
        #expect(Self.name("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Trips/Lisbon")
                == "iCloud Drive › Trips › Lisbon")
    }

    @Test("A folder on a drive is named from the drive down")
    func drive() {
        #expect(Self.name("/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/SD Card/DCIM/100LEICA")
                == "SD Card › DCIM › 100LEICA")
    }

    @Test("Any other folder shows its own name")
    func other() {
        #expect(Self.name("/private/var/mobile/Containers/Shared/AppGroup/ABC/Dropbox/Photos") == "Photos")
    }
}
