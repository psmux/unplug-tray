import XCTest
@testable import UnplugCore

final class ParsingTests: XCTestCase {
    func testLsofGroupsByProcess() {
        let out = "p501\ncPreview\np502\ncTerminal\np501\ncPreview\n"
        XCTAssertEqual(Ejector.parseLsof(out), [Holder(pid: 501, name: "Preview"), Holder(pid: 502, name: "Terminal")])
    }

    func testDissenterLine() {
        let out = "Volume Stick on disk4s1 failed to unmount: dissented by PID 88 (/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds)"
        XCTAssertEqual(Ejector.parseDissenters(out), [Holder(pid: 88, name: "mds")])
    }

    func testWholeDiskName() {
        XCTAssertEqual(DriveScanner.wholeDiskName("disk11s2"), "disk11")
        XCTAssertEqual(DriveScanner.wholeDiskName("disk4"), "disk4")
    }

    func testApfsFollowsPhysicalStore() {
        let volume: [String: Any] = [
            "DeviceIdentifier": "disk12s1", "ParentWholeDisk": "disk12",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk11s2"]],
        ]
        let lookup: (String) -> [String: Any]? = { $0 == "disk11s2" ? ["ParentWholeDisk": "disk11"] : nil }
        XCTAssertEqual(DriveScanner.physicalWholeDisk(info: volume, lookup: lookup), "disk11")
    }

    func testPlainVolumeUsesParent() {
        let volume: [String: Any] = ["DeviceIdentifier": "disk4s1", "ParentWholeDisk": "disk4"]
        XCTAssertEqual(DriveScanner.physicalWholeDisk(info: volume, lookup: { _ in nil }), "disk4")
    }

    func testDisplayName() {
        let v = Volume(name: "Photos", mountPoint: URL(fileURLWithPath: "/Volumes/Photos"), total: 1, free: 1)
        XCTAssertEqual(Drive(id: "disk4", model: "SD Card", bus: "USB", size: 1, volumes: [v]).displayName, "Photos")
        XCTAssertEqual(Drive(id: "disk4", model: "SD Card", bus: "USB", size: 1, volumes: [v, v]).displayName, "SD Card")
    }
}
