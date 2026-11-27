import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Comments under a memory and owner-only chapters (issue #28), with
/// synthetic data and in-memory stores only.
@MainActor
final class MemoryCommentsTests: XCTestCase {
    private let partner = "_partner00000000000000000000000002"
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func comment(_ id: String, parent: String? = nil, author: String = MomentsAccount.localID, at seconds: Double) -> Comment {
        Comment(id: id, memoryID: "mem", parentCommentID: parent, text: id, authorAccountID: author,
                createdAt: t0.addingTimeInterval(seconds), updatedAt: t0.addingTimeInterval(seconds))
    }

    func testRepliesStayOneStepInUnderTheCommentThatStartedTheThread() {
        let comments = [
            comment("reply-to-reply", parent: "reply", author: MomentsAccount.localID, at: 30),
            comment("first", at: 10),
            comment("reply", parent: "first", author: partner, at: 20),
            comment("second", author: partner, at: 40)
        ]
        let threads = CommentThreads.threads(comments)
        XCTAssertEqual(threads.map(\.root.id), ["first", "second"])
        XCTAssertEqual(threads[0].replies.map(\.id), ["reply", "reply-to-reply"])
        XCTAssertTrue(threads[1].replies.isEmpty)
    }

    func testAReplyWhoseCommentIsGoneMovesUpUnderTheMemory() {
        let comments = [
            comment("orphan", parent: "deleted", author: partner, at: 20),
            comment("first", at: 10)
        ]
        XCTAssertEqual(CommentThreads.threads(comments).map(\.root.id), ["first", "orphan"])
    }

    func testOnlyMyOwnCommentsAreMineToDeleteAndHerRepliesStay() {
        let mine = comment("mine", at: 10)
        let hers = comment("hers", parent: "mine", author: partner, at: 20)
        let myReply = comment("my-reply", parent: "mine", at: 30)
        XCTAssertTrue(CommentThreads.isOwn(mine))
        XCTAssertFalse(CommentThreads.isOwn(hers))
        XCTAssertEqual(CommentThreads.repliesThatStay(after: mine, in: [mine, hers, myReply]).map(\.id), ["hers"])
    }

    func testACommentIsSavedUnderItsMemory() throws {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "synthetic-photo")
        let memory = Memory(id: "mem", text: "Synthetic words", mediaItem: item)
        context.insert(item)
        context.insert(memory)
        context.insert(Comment(memoryID: memory.id, text: "Synthetic comment"))
        try context.save()
        let memoryID = memory.id
        let saved: [Comment] = try context.fetch(FetchDescriptor<Comment>(predicate: #Predicate { $0.memoryID == memoryID }))
        XCTAssertEqual(saved.map(\.text), ["Synthetic comment"])
        XCTAssertEqual(saved.first?.authorAccountID, MomentsAccount.localID)
    }

    func testOnlyTheChaptersMakerRenamesOrDeletesIt() {
        let mine = UserGroup(id: "g-mine", name: "Mine", kind: .chapter)
        let hers = UserGroup(id: "g-hers", name: "Hers", kind: .chapter, ownerAccountID: partner)
        XCTAssertTrue(UserGroupRuleEngine.canEdit(mine))
        XCTAssertTrue(UserGroupRuleEngine.canDelete(mine))
        XCTAssertFalse(UserGroupRuleEngine.canEdit(hers))
        XCTAssertFalse(UserGroupRuleEngine.canDelete(hers))
    }
}
