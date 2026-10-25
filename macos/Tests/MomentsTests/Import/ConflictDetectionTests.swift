import Foundation
import MomentsCore
import XCTest
@testable import Moments

final class ConflictDetectionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_767_225_600)

    func testShortFastJumpRule() {
        let events = detect([
            item("a", 0, 0, 0),
            item("b", 60, 0, 0.04)
        ])
        XCTAssertTrue(events.contains { $0.kind == .shortFastJump })
    }

    func testHighSpeedRule() {
        let events = detect([
            item("a", 0, 0, 0),
            item("b", 60, 0, 0.03)
        ])
        XCTAssertTrue(events.contains { $0.kind == .highSpeedJump })
    }

    func testSameSecondFarApartRule() {
        let events = detect([
            item("a", 0, 0, 0),
            item("b", 0, 0, 0.05)
        ])
        XCTAssertTrue(events.contains { $0.kind == .sameSecondFarApart })
    }

    func testABALoopRule() {
        let events = detect([
            item("a", 0, 0, 0),
            item("b", 10 * 60, 0, 0.05),
            item("c", 20 * 60, 0, 0.0005)
        ])
        XCTAssertTrue(events.contains { $0.kind == .abaLoop })
    }

    func testTransportRuleSuppressesConflictForLongConsistentTravel() {
        let events = detect([
            item("a", 0, 0, 0),
            item("b", 60 * 60, 5, 0)
        ])
        XCTAssertTrue(events.contains { $0.kind == .transport })
        XCTAssertFalse(events.contains { $0.kind == .shortFastJump })
    }

    func testLongGapIsNoPhotosOnly() {
        let events = detect([
            item("a", 0, 0, 0),
            item("b", 3 * 60 * 60, 0, 0.01)
        ])
        XCTAssertTrue(events.contains { $0.kind == .noPhotosGap })
        XCTAssertFalse(events.contains { $0.kind == .shortFastJump })
    }

    private func detect(_ items: [ImportedMediaMetadata]) -> [ImportConflictEvent] {
        ImportConflictDetector().detect(items)
    }

    private func item(_ id: String, _ seconds: TimeInterval, _ latitude: Double?, _ longitude: Double?) -> ImportedMediaMetadata {
        ImportedMediaMetadata(
            id: id,
            bookmarkData: Data(),
            fileName: "synthetic-\(id).jpg",
            contentHash: id,
            captureDate: base.addingTimeInterval(seconds),
            captureDateSource: .exif,
            timeZoneOffsetMinutes: 0,
            latitude: latitude,
            longitude: longitude,
            width: 4,
            height: 4,
            kind: .photo,
            duration: nil
        )
    }
}
