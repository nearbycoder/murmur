import MurmurKit
import XCTest
@testable import Murmur

final class MurmurTests: XCTestCase {
    func testFileTreeRollsUpFolders() {
        let nodes = FileNode.tree([
            (0, "Disc 1/01.flac", 100, 50),
            (1, "Disc 1/02.flac", 300, 300),
            (2, "cover.jpg", 10, 0),
        ])
        XCTAssertEqual(nodes.map(\.name), ["Disc 1", "cover.jpg"])
        XCTAssertEqual(nodes[0].length, 400)
        XCTAssertEqual(nodes[0].downloaded, 350)
        XCTAssertEqual(nodes[0].fileIDs.sorted(), [0, 1])
        XCTAssertNil(nodes[1].children)
    }

    func testFormatting() {
        XCTAssertEqual(Format.percent(1), "100%")
        XCTAssertEqual(Format.percent(0.051), "5.1%")
        XCTAssertEqual(Format.percent(0.5), "50%")
        XCTAssertNil(Format.eta(nil))
        XCTAssertNotNil(Format.eta(3725))
        XCTAssertEqual(Int64(0).speed, "0 KB/s")
    }
}
