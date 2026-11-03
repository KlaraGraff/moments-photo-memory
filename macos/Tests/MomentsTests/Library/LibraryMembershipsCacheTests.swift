import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Proves the Library's memberships are fetched once per `groupSourcesRevision`
/// and per container, and that a membership change is seen on the next refresh.
@MainActor
final class LibraryMembershipsCacheTests: XCTestCase {
    private var container: ModelContainer?

    override func setUp() {
        super.setUp()
        LibraryMembershipsCache.resetForTests()
    }

    override func tearDown() {
        LibraryMembershipsCache.resetForTests()
        container = nil
        super.tearDown()
    }

    /// In memory, like the other store tests: never on disk.
    private func makeContext() throws -> ModelContext {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    private func fetchAll(in context: ModelContext) -> [UserGroupItem] {
        (try? context.fetch(FetchDescriptor<UserGroupItem>())) ?? []
    }

    // MARK: (a) A matching revision reuses the fetched memberships

    func testTwoRefreshesWithTheSameRevisionFetchOnce() throws {
        let context: ModelContext = try makeContext()
        let membership: UserGroupItem = UserGroupItem(id: "membership-a", groupID: "group-a", mediaID: "photo-a")
        context.insert(membership)
        try context.save()

        let revision: Int = 1
        let first: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: revision, context: context) { [self] () -> [UserGroupItem] in
            fetchAll(in: context)
        }
        let second: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: revision, context: context) { [self] () -> [UserGroupItem] in
            fetchAll(in: context)
        }

        XCTAssertEqual(LibraryMembershipsCache.fetchCount, 1, "a matching revision must not fetch again")
        XCTAssertEqual(first.map(\.id), ["membership-a"])
        XCTAssertEqual(second.map(\.id), ["membership-a"])
        XCTAssertTrue(first.first === second.first, "the same rows come back, not copies")
    }

    // A moved revision fetches again and sees a membership that was added.
    func testMovedRevisionFetchesAgainAndSeesANewMembership() throws {
        let context: ModelContext = try makeContext()
        context.insert(UserGroupItem(id: "membership-b", groupID: "group-b", mediaID: "photo-b"))
        try context.save()

        let first: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: 1, context: context) { [self] () -> [UserGroupItem] in
            fetchAll(in: context)
        }
        XCTAssertEqual(first.map(\.id), ["membership-b"])

        let added: UserGroupItem = UserGroupItem(id: "membership-c", groupID: "group-b", mediaID: "photo-c")
        context.insert(added)
        try context.save()

        let second: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: 2, context: context) { [self] () -> [UserGroupItem] in
            fetchAll(in: context)
        }
        XCTAssertEqual(LibraryMembershipsCache.fetchCount, 2)
        XCTAssertEqual(Set(second.map(\.id)), ["membership-b", "membership-c"])
    }

    // A matching revision after a membership was deleted must not hand the
    // deleted row on: the fetch runs again and the row is gone.
    func testMatchingRevisionRefetchesWhenACachedRowWasDeleted() throws {
        let context: ModelContext = try makeContext()
        let kept: UserGroupItem = UserGroupItem(id: "membership-kept", groupID: "group-d", mediaID: "photo-d")
        let removed: UserGroupItem = UserGroupItem(id: "membership-removed", groupID: "group-d", mediaID: "photo-e")
        context.insert(kept)
        context.insert(removed)
        try context.save()

        let first: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: 3, context: context) { [self] () -> [UserGroupItem] in
            fetchAll(in: context)
        }
        XCTAssertEqual(Set(first.map(\.id)), ["membership-kept", "membership-removed"])

        context.delete(removed)

        let second: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: 3, context: context) { [self] () -> [UserGroupItem] in
            fetchAll(in: context)
        }
        XCTAssertEqual(LibraryMembershipsCache.fetchCount, 2, "a deleted cached row must force a fetch")
        XCTAssertEqual(second.map(\.id), ["membership-kept"])
        XCTAssertFalse(second.contains(where: { (item: UserGroupItem) -> Bool in item.isDeleted }))
    }

    // A second container with the same revision has its own memberships.
    func testAnotherContainerFetchesItsOwnMemberships() throws {
        let firstContext: ModelContext = try makeContext()
        firstContext.insert(UserGroupItem(id: "membership-first", groupID: "group-e", mediaID: "photo-f"))
        try firstContext.save()

        let secondContainer: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        let secondContext: ModelContext = secondContainer.mainContext
        secondContext.insert(UserGroupItem(id: "membership-second", groupID: "group-e", mediaID: "photo-g"))
        try secondContext.save()

        let first: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: 1, context: firstContext) { [self] () -> [UserGroupItem] in
            fetchAll(in: firstContext)
        }
        let second: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: 1, context: secondContext) { [self] () -> [UserGroupItem] in
            fetchAll(in: secondContext)
        }

        XCTAssertEqual(LibraryMembershipsCache.fetchCount, 2, "another container must fetch on its own")
        XCTAssertEqual(first.map(\.id), ["membership-first"])
        XCTAssertEqual(second.map(\.id), ["membership-second"])
    }

    // MARK: (b) A membership save moves the store's revision

    // What the page's `.onChange(of: store.groupSourcesRevision)` keys on: a
    // membership added or removed moves it, so the next refresh sees the change.
    func testMembershipSaveMovesTheRevisionTheCacheIsKeyedOn() async throws {
        let context: ModelContext = try makeContext()
        let photo: MediaItem = MediaItem(id: "photo-member", captureDate: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(photo)
        let group: UserGroup = UserGroup(id: "group-f", name: "Synthetic Group F", kind: .manual)
        context.insert(group)
        try context.save()

        let store: LibraryStore = LibraryStore()
        store.start(context: context)
        let start: Int = store.groupSourcesRevision

        let first: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: start, context: context) { [self] () -> [UserGroupItem] in
            fetchAll(in: context)
        }
        XCTAssertEqual(first.count, 0)

        let membership: UserGroupItem = UserGroupItem(id: "membership-f", groupID: group.id, mediaID: photo.id)
        context.insert(membership)
        try context.save()

        let moved: Bool = await waitUntil(timeout: 3) { () -> Bool in
            store.groupSourcesRevision > start
        }
        XCTAssertTrue(moved, "adding a membership must move the group sources revision")

        let second: [UserGroupItem] = LibraryMembershipsCache.memberships(revision: store.groupSourcesRevision, context: context) { [self] () -> [UserGroupItem] in
            fetchAll(in: context)
        }
        XCTAssertEqual(second.map(\.id), ["membership-f"])
        XCTAssertEqual(LibraryMembershipsCache.fetchCount, 2)
    }

    /// Polls every 50 ms, like the app's settle timer would.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline: Date = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
