import Foundation
import MomentsCore
import XCTest
@testable import Moments

/// What the Mac notifications for the other person's words say (issue #28).
@MainActor
final class PartnerNotifierTests: XCTestCase {
    func testEachKindHasItsOwnTitleAndTheWordsAsBody() {
        let memory = PartnerNotifier.content(
            for: .single(SyncArrival(kind: .memory, recordID: "mem", memoryID: "mem", text: "Synthetic words")),
            partner: "Sam"
        )
        XCTAssertEqual(memory, PartnerNotifier.Content(title: "Sam wrote a memory", body: "Synthetic words", memoryID: "mem"))
        let comment = PartnerNotifier.content(
            for: .single(SyncArrival(kind: .comment, recordID: "c", memoryID: "mem", text: "Nice")),
            partner: "Sam"
        )
        XCTAssertEqual(comment.title, "Sam commented on your memory")
        let reply = PartnerNotifier.content(
            for: .single(SyncArrival(kind: .reply, recordID: "r", memoryID: "mem", text: "Yes")),
            partner: "Sam"
        )
        XCTAssertEqual(reply.title, "Sam replied to you")
        XCTAssertEqual(reply.memoryID, "mem")
    }

    func testManyAtOnceIsOneSummary() {
        let summary = PartnerNotifier.content(for: .summary(count: 7), partner: "Sam")
        XCTAssertEqual(summary.title, "Sam wrote 7 memories and comments")
        XCTAssertEqual(summary.body, "Open Moments to see them.")
        XCTAssertNil(summary.memoryID)
    }

    func testLongWordsAreCutToOneLine() {
        let long = String(repeating: "word ", count: 60) + "\nsecond line"
        let body = PartnerNotifier.shortened(long)
        XCTAssertLessThanOrEqual(body.count, PartnerNotifier.bodyLimit)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertFalse(body.contains("\n"))
        XCTAssertEqual(PartnerNotifier.shortened("one\ntwo"), "one two")
    }
}
