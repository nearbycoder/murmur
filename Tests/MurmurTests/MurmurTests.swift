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

    func testSlowModeSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ weekday: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            // 2026-11-01 is a Sunday (weekday 1).
            calendar.date(from: DateComponents(year: 2026, month: 11, day: weekday, hour: hour, minute: minute))!
        }
        let weekdays: Set<Int> = [2, 3, 4, 5, 6]
        XCTAssertTrue(AppSettings.schedule(covers: date(2, 9), start: 540, end: 1020, days: weekdays, calendar: calendar))
        XCTAssertFalse(AppSettings.schedule(covers: date(2, 17), start: 540, end: 1020, days: weekdays, calendar: calendar))
        XCTAssertFalse(AppSettings.schedule(covers: date(1, 12), start: 540, end: 1020, days: weekdays, calendar: calendar))
        // 23:00–07:00 starting Friday covers early Saturday but not early Friday... unless Thursday is on.
        XCTAssertTrue(AppSettings.schedule(covers: date(7, 3), start: 1380, end: 420, days: [6], calendar: calendar))
        XCTAssertFalse(AppSettings.schedule(covers: date(6, 3), start: 1380, end: 420, days: [6], calendar: calendar))
        XCTAssertTrue(AppSettings.schedule(covers: date(6, 23, 30), start: 1380, end: 420, days: [6], calendar: calendar))
    }
}
