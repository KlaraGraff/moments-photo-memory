import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class UserGroupTests: XCTestCase {
    func testAllAnyAndEachSupportedField() {
        let place = Place(id: "place-1", name: "Tangier")
        let trip = Trip(id: "trip-1", name: "Synthetic trip")
        let item = MediaItem(
            id: "media-1",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .photo,
            place: place,
            trip: trip
        )
        let tag = Tag(id: "tag-1", displayName: "blue")
        item.mediaTags = [MediaTag(id: "join-1", mediaID: item.id, tagID: tag.id, mediaItem: item, tag: tag)]
        item.memories = [Memory(id: "memory-1", text: "Synthetic memory", mediaItem: item)]

        let all = UserGroupRuleSet(mode: .all, rules: [
            UserGroupRule(field: .place, value: place.id),
            UserGroupRule(field: .trip, value: trip.id),
            UserGroupRule(field: .type, value: "photo"),
            UserGroupRule(field: .hasMemory, value: "true"),
            UserGroupRule(field: .tag, value: tag.id),
            UserGroupRule(field: .dateRange, value: "2023-11-14", secondaryValue: "2023-11-15")
        ])
        XCTAssertTrue(UserGroupRuleEngine.matches(item, ruleSet: all))

        let any = UserGroupRuleSet(mode: .any, rules: [
            UserGroupRule(field: .place, value: "other-place"),
            UserGroupRule(field: .type, op: .isNot, value: "video")
        ])
        XCTAssertTrue(UserGroupRuleEngine.matches(item, ruleSet: any))

        let negatedRules = [
            UserGroupRule(field: .place, op: .isNot, value: "other-place"),
            UserGroupRule(field: .trip, op: .isNot, value: "other-trip"),
            UserGroupRule(field: .type, op: .isNot, value: "video"),
            UserGroupRule(field: .dateRange, op: .isNot, value: "2020-01-01", secondaryValue: "2020-01-02"),
            UserGroupRule(field: .hasMemory, op: .isNot, value: "false"),
            UserGroupRule(field: .tag, op: .isNot, value: "other-tag")
        ]
        for rule in negatedRules {
            XCTAssertTrue(UserGroupRuleEngine.matches(item, ruleSet: UserGroupRuleSet(rules: [rule])))
        }
    }

    func testExclusionsPersistAndHideSmartMatches() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "media-1", kind: .photo)
        let group = UserGroup(id: "group-1", name: "Synthetic smart", kind: .smart, rules: UserGroupRuleSet(rules: [UserGroupRule(field: .type, value: "photo")]))
        let membership = UserGroupItem(groupID: group.id, mediaID: item.id, excluded: true)
        context.insert(item); context.insert(group); context.insert(membership)
        try context.save()

        let storedMembership = try context.fetch(FetchDescriptor<UserGroupItem>()).first!
        let visible = UserGroupRuleEngine.visibleItems(for: group, from: [item], memberships: [storedMembership])
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(storedMembership.excluded)
    }

    func testLibraryPhotoSegmentStillHidesScreenshots() {
        let screenshot = MediaItem(id: "synthetic-screenshot", kind: .photo, isScreenshot: true)
        let photo = MediaItem(id: "synthetic-photo", kind: .photo)
        var criteria = LibraryFilterCriteria.default
        criteria.mediaType = .photo
        XCTAssertEqual(LibraryFilterEngine.filteredItems([screenshot, photo], by: criteria).map(\.id), ["synthetic-photo"])
    }

    func testScreenshotRulesUsePurePredicateAndEmptyRulesMatchNothing() {
        let place = Place(id: "place-1", name: "Synthetic place")
        let screenshot = MediaItem(id: "shot", kind: .photo, isScreenshot: true, place: place)
        let group = UserGroupRuleSet(rules: [
            UserGroupRule(field: .place, value: place.id),
            UserGroupRule(field: .type, value: "screenshot")
        ])
        XCTAssertTrue(UserGroupRuleEngine.matches(screenshot, ruleSet: group))
        XCTAssertFalse(UserGroupRuleEngine.matches(screenshot, ruleSet: UserGroupRuleSet()))
        let emptyGroup = UserGroup(id: "empty", name: "Empty", kind: .smart)
        XCTAssertTrue(UserGroupRuleEngine.visibleItems(for: emptyGroup, from: [screenshot], memberships: []).isEmpty)
    }

    func testDateRulesUseInclusiveLocalCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 10, hour: 23))!
        let item = MediaItem(id: "date-item", captureDate: date, kind: .photo)
        let rule = UserGroupRule(field: .dateRange, value: "2024-01-10", secondaryValue: "2024-01-10")
        let criteria = UserGroupRuleSet().libraryCriteria(for: rule, calendar: calendar)!
        XCTAssertTrue(LibraryFilterEngine.matches(item, criteria: criteria, calendar: calendar, hidesScreenshots: false))
        XCTAssertEqual(LibraryFilterEngine.filteredItems([item], by: criteria, calendar: calendar).map(\.id), [item.id])

        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let shanghaiDate = calendar.date(from: DateComponents(year: 2024, month: 1, day: 10, hour: 1))!
        let shanghaiItem = MediaItem(id: "shanghai-item", captureDate: shanghaiDate, kind: .photo)
        XCTAssertTrue(UserGroupRuleEngine.matches(shanghaiItem, ruleSet: UserGroupRuleSet(rules: [rule]), calendar: calendar))
        XCTAssertEqual(UserGroupRuleSet.localDayKey(for: shanghaiDate, calendar: calendar), "2024-01-10")
    }

    func testSmartGroupsIncludePinnedItemsAndAllowReaddingExcludedItems() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let photo = MediaItem(id: "photo", kind: .photo)
        let video = MediaItem(id: "video", kind: .video)
        let group = UserGroup(id: "smart", name: "Synthetic smart", kind: .smart, rules: UserGroupRuleSet(rules: [UserGroupRule(field: .type, value: "photo")]))
        context.insert(photo); context.insert(video); context.insert(group)
        try context.save()

        UserGroupRuleEngine.add(video, to: group, memberships: [], context: context)
        UserGroupRuleEngine.remove(photo, from: group, memberships: [], context: context)
        try context.save()
        var memberships = try context.fetch(FetchDescriptor<UserGroupItem>())
        XCTAssertEqual(Set(UserGroupRuleEngine.visibleItems(for: group, from: [photo, video], memberships: memberships).map(\.id)), Set(["video"]))

        UserGroupRuleEngine.add(photo, to: group, memberships: [], context: context)
        try context.save()
        memberships = try context.fetch(FetchDescriptor<UserGroupItem>())
        XCTAssertEqual(Set(UserGroupRuleEngine.visibleItems(for: group, from: [photo, video], memberships: memberships).map(\.id)), Set(["photo", "video"]))

        UserGroupRuleEngine.convertToManual(group, items: [photo, video], memberships: memberships, context: context)
        try context.save()
        let converted = try context.fetch(FetchDescriptor<UserGroupItem>())
        XCTAssertEqual(group.kind, .manual)
        XCTAssertEqual(Set(converted.map(\.mediaID)), Set(["photo", "video"]))
    }

    func testMembershipActionsFetchFreshRowsAndRemoveDuplicates() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "item")
        let group = UserGroup(id: "manual", name: "Synthetic manual", kind: .manual)
        context.insert(item); context.insert(group)
        context.insert(UserGroupItem(groupID: group.id, mediaID: item.id))
        context.insert(UserGroupItem(groupID: group.id, mediaID: item.id))
        try context.save()

        UserGroupRuleEngine.remove(item, from: group, memberships: [], context: context)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<UserGroupItem>()).isEmpty)

        UserGroupRuleEngine.add(item, to: group, memberships: [], context: context)
        UserGroupRuleEngine.add(item, to: group, memberships: [], context: context)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserGroupItem>()).count, 1)
    }

    func testPlaceAndTripRulesMatchIDsOnly() {
        let place = Place(id: "place-id", name: "Display name")
        let trip = Trip(id: "trip-id", name: "Trip name")
        let item = MediaItem(id: "item", place: place, trip: trip)
        XCTAssertTrue(UserGroupRuleEngine.matches(item, ruleSet: UserGroupRuleSet(rules: [
            UserGroupRule(field: .place, value: place.id),
            UserGroupRule(field: .trip, value: trip.id)
        ])))
        XCTAssertFalse(UserGroupRuleEngine.matches(item, ruleSet: UserGroupRuleSet(rules: [
            UserGroupRule(field: .place, value: place.name)
        ])))
        XCTAssertFalse(UserGroupRuleEngine.matches(item, ruleSet: UserGroupRuleSet(rules: [
            UserGroupRule(field: .trip, value: trip.name)
        ])))

        var libraryCriteria = LibraryFilterCriteria.default
        libraryCriteria.placeID = place.name
        XCTAssertTrue(LibraryFilterEngine.filteredItems([item], by: libraryCriteria).isEmpty)
        libraryCriteria.placeID = nil
        libraryCriteria.tripKey = trip.name
        XCTAssertTrue(LibraryFilterEngine.filteredItems([item], by: libraryCriteria).isEmpty)
    }

    func testConvertToManualSnapshotsCurrentMatches() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "media-1", kind: .photo)
        let group = UserGroup(id: "group-1", name: "Synthetic smart", kind: .smart, rules: UserGroupRuleSet(rules: [UserGroupRule(field: .type, value: "photo")]))
        context.insert(item); context.insert(group)
        try context.save()

        UserGroupRuleEngine.convertToManual(group, items: [item], memberships: [], context: context)
        try context.save()
        let memberships = try context.fetch(FetchDescriptor<UserGroupItem>())
        XCTAssertEqual(group.kind, .manual)
        XCTAssertEqual(memberships.map(\.mediaID), [item.id])
    }

    func testOnlyOwnerCanDeleteAndItemsMayBelongToSeveralGroups() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "media-1")
        let first = UserGroup(id: "group-1", name: "First")
        let second = UserGroup(id: "group-2", name: "Second")
        context.insert(item); context.insert(first); context.insert(second)
        context.insert(UserGroupItem(groupID: first.id, mediaID: item.id))
        context.insert(UserGroupItem(groupID: second.id, mediaID: item.id))
        try context.save()

        XCTAssertTrue(UserGroupRuleEngine.canDelete(first, accountID: MomentsAccount.localID))
        XCTAssertFalse(UserGroupRuleEngine.canDelete(UserGroup(name: "Partner", ownerAccountID: "partner"), accountID: MomentsAccount.localID))
        let memberships = try context.fetch(FetchDescriptor<UserGroupItem>())
        XCTAssertEqual(UserGroupRuleEngine.visibleItems(for: first, from: [item], memberships: memberships).count, 1)
        XCTAssertEqual(UserGroupRuleEngine.visibleItems(for: second, from: [item], memberships: memberships).count, 1)
    }

    func testFrozenSchemaV4StoreMigratesToV5() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moments-v4-v5-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storeURL = folder.appending(path: "Moments.store")
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacy = try MomentsPersistence.makeV4Container(url: storeURL)
        let oldContext = legacy.mainContext
        oldContext.insert(SchemaV4.MediaItem(id: "frozen-v4-item", title: "Synthetic V4 item"))
        try oldContext.save()

        let current = try MomentsPersistence.makeContainer(url: storeURL)
        let items = try current.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.map(\.id), ["frozen-v4-item"])
        XCTAssertTrue(try current.mainContext.fetch(FetchDescriptor<UserGroup>()).isEmpty)
    }
}
