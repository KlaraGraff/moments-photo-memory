import Foundation
import SwiftData
import XCTest
import MomentsCore
@testable import Moments

@MainActor
final class RecentlyDeletedTests: XCTestCase {
    private let day: TimeInterval = 86_400

    // MARK: Migration

    func testFrozenV7StoreOpensWithDeletionFieldsEmpty() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moments-v7-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storeURL = folder.appending(path: "Moments.store")
        defer { try? FileManager.default.removeItem(at: folder) }

        let legacy = try MomentsPersistence.makeV7Container(url: storeURL)
        let oldContext = legacy.mainContext
        let item = SchemaV7.MediaItem(id: "frozen-v7-item", title: "Synthetic V7 item")
        oldContext.insert(item)
        oldContext.insert(SchemaV7.Memory(text: "Synthetic memory", mediaItem: item))
        oldContext.insert(SchemaV7.UserGroup(name: "Synthetic group"))
        oldContext.insert(SchemaV7.UserGroupItem(groupID: "group", mediaID: "frozen-v7-item"))
        oldContext.insert(SchemaV7.Person(id: "person-1", name: "Synthetic person"))
        oldContext.insert(SchemaV7.PhotoNote(mediaID: "frozen-v7-item", text: "Synthetic note"))
        try oldContext.save()

        let current = try MomentsPersistence.makeContainer(url: storeURL)
        let context = current.mainContext
        let items = try context.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.map(\.id), ["frozen-v7-item"])
        XCTAssertNil(items.first?.deletedAt)
        XCTAssertNil(items.first?.ownerAccountID)
        XCTAssertNil(items.first?.importSourceIDsRaw)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Memory>()).map(\.text), ["Synthetic memory"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserGroupItem>()).map(\.mediaID), ["frozen-v7-item"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoNote>()).map(\.text), ["Synthetic note"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Person>()).map(\.name), ["Synthetic person"])
        // The Library's query still finds the old photo.
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil })).count, 1)

        context.insert(ImportSource(kind: .folder, name: "Synthetic folder", locationKey: "/synthetic"))
        RecentlyDeleted.moveToTrash(items, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ImportSource>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt != nil })).count, 1)
    }

    // MARK: Moving, recovering, purging

    func testOnlyOwnPhotosMoveAndComeBack() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let mine = MediaItem(id: "mine", title: "Mine")
        let partners = MediaItem(id: "partners", title: "Partner's")
        partners.ownerAccountID = "partner"
        context.insert(mine)
        context.insert(partners)
        try context.save()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(RecentlyDeleted.moveToTrash([mine, partners], now: now, context: context), ["mine"])
        XCTAssertEqual(mine.deletedAt, now)
        XCTAssertEqual(mine.deletedBy, MomentsAccount.localID)
        XCTAssertNil(partners.deletedAt)
        // Already there: nothing moves twice.
        XCTAssertEqual(RecentlyDeleted.moveToTrash([mine], context: context), [])
        // The partner deletes their own.
        XCTAssertEqual(RecentlyDeleted.moveToTrash([partners], accountID: "partner", context: context), ["partners"])

        XCTAssertEqual(RecentlyDeleted.daysLeft(mine, now: now), 30)
        XCTAssertEqual(RecentlyDeleted.daysLeft(mine, now: now.addingTimeInterval(29.5 * day)), 1)
        XCTAssertEqual(RecentlyDeleted.daysLeft(mine, now: now.addingTimeInterval(31 * day)), 0)

        XCTAssertEqual(RecentlyDeleted.recover([mine, partners], context: context), ["mine"])
        XCTAssertNil(mine.deletedAt)
        XCTAssertNil(mine.deletedBy)
        XCTAssertNotNil(partners.deletedAt)
    }

    func testPurgeRemovesExpiredPhotosAndWhatHangsOffThem() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = MediaItem(id: "old", title: "Old")
        let recent = MediaItem(id: "recent", title: "Recent")
        let kept = MediaItem(id: "kept", title: "Kept")
        for item in [old, recent, kept] { context.insert(item) }
        context.insert(Memory(text: "Synthetic memory", mediaItem: old))
        context.insert(PhotoNote(mediaID: "old", text: "Synthetic note"))
        context.insert(PhotoNote(mediaID: "kept", text: "Kept note"))
        let group = UserGroup(name: "Synthetic group")
        context.insert(group)
        context.insert(UserGroupItem(groupID: group.id, mediaID: "old"))
        context.insert(UserGroupItem(groupID: group.id, mediaID: "kept"))
        context.insert(FaceObservation(mediaID: "old", rect: (0, 0, 0.1, 0.1), embedding: Data(), cropData: Data(), quality: 1))
        context.insert(FaceScanRecord(id: "old"))
        old.setFavorite(true, context: context)
        let tag = Tag(id: "tag", displayName: "Synthetic tag")
        context.insert(tag)
        old.addTag(tag, context: context)
        try context.save()

        RecentlyDeleted.moveToTrash([old], now: now.addingTimeInterval(-31 * day), context: context)
        RecentlyDeleted.moveToTrash([recent], now: now.addingTimeInterval(-2 * day), context: context)

        XCTAssertEqual(RecentlyDeleted.purgeExpired(now: now, context: context), 1)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<MediaItem>()).map(\.id)), ["recent", "kept"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoNote>()).map(\.mediaID), ["kept"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserGroupItem>()).map(\.mediaID), ["kept"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<FaceObservation>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<FaceScanRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Favorite>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MediaTag>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Tag>()).count, 1, "the tag itself stays")
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserGroup>()).count, 1, "the group stays")

        // Delete Now: only photos already in Recently Deleted.
        XCTAssertEqual(RecentlyDeleted.deletePermanently([recent, kept], context: context), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).map(\.id), ["kept"])
    }

    // MARK: Undo and the viewer

    func testDeletingUndoesAndRedoes() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let item = MediaItem(id: "photo", title: "Photo")
        context.insert(item)
        try context.save()
        let selection = SelectionModel()
        selection.select("photo")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        PhotoDeletion.request(["photo"], confirm: false, selection: selection, context: context, undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertNotNil(item.deletedAt)
        XCTAssertTrue(selection.selectedItemIDs.isEmpty)
        XCTAssertEqual(selection.lastDeletion?.itemIDs, ["photo"])

        // ⌘Z still works after the bar has hidden itself.
        selection.lastDeletion = nil
        undoManager.undo()
        XCTAssertNil(item.deletedAt)
        selection.openViewer("photo", in: ["photo"])
        undoManager.redo()
        XCTAssertNotNil(item.deletedAt)
        XCTAssertNil(selection.viewerRequest, "Redo left the viewer on the deleted photo")
        undoManager.undo()
        XCTAssertNil(item.deletedAt)

        // A new delete; ⌘Z clears its bar.
        undoManager.beginUndoGrouping()
        PhotoDeletion.request(["photo"], confirm: false, selection: selection, context: context, undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertNotNil(selection.lastDeletion)
        undoManager.undo()
        XCTAssertNil(selection.lastDeletion, "The bar still offers Undo after ⌘Z")
        undoManager.removeAllActions()
        undoManager.beginUndoGrouping()
        PhotoDeletion.request(["photo"], confirm: false, selection: selection, context: context, undoManager: undoManager)
        undoManager.endUndoGrouping()

        // The bar's Undo leaves nothing for ⌘Z.
        let notice = try XCTUnwrap(selection.lastDeletion)
        PhotoDeletion.undo(notice, selection: selection, context: context, undoManager: undoManager)
        XCTAssertNil(item.deletedAt)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertNil(selection.lastDeletion)
    }

    func testDeleteAsksFirstAndLeavesPartnersPhotos() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let mine = MediaItem(id: "mine", title: "Mine")
        let partners = MediaItem(id: "partners", title: "Partner's")
        partners.ownerAccountID = "partner"
        context.insert(mine)
        context.insert(partners)
        try context.save()
        let selection = SelectionModel()

        PhotoDeletion.request(["mine", "partners"], confirm: true, selection: selection, context: context, undoManager: nil)
        XCTAssertEqual(selection.pendingDeletion, PendingDeletion(itemIDs: ["mine"], othersCount: 1))
        XCTAssertNil(mine.deletedAt, "nothing moves before the alert is confirmed")

        selection.pendingDeletion = nil
        PhotoDeletion.request(["partners"], confirm: true, selection: selection, context: context, undoManager: nil)
        XCTAssertNil(selection.pendingDeletion, "only a partner's photo: nothing to ask")
    }

    func testViewerMovesOnFromADeletedPhoto() {
        let selection = SelectionModel()
        selection.openViewer("b", in: ["a", "b", "c"])
        selection.forget(deleted: ["b"])
        XCTAssertEqual(selection.viewerRequest, ViewerRequest(itemIDs: ["a", "c"], itemID: "c"))
        selection.forget(deleted: ["c"])
        XCTAssertEqual(selection.viewerRequest, ViewerRequest(itemIDs: ["a"], itemID: "a"))
        selection.forget(deleted: ["a"])
        XCTAssertNil(selection.viewerRequest)
    }

    // MARK: Import sources

    func testRemovingAFolderKeepsPhotosAnotherFolderHolds() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let trip = ImportSource(kind: .folder, name: "Trip", locationKey: "/synthetic/trip")
        let other = ImportSource(kind: .folder, name: "Other", locationKey: "/synthetic/other")
        context.insert(trip)
        context.insert(other)
        let onlyTrip = MediaItem(id: "only-trip", source: .file, title: "A")
        onlyTrip.addImportSource(trip.id)
        let both = MediaItem(id: "both", source: .file, title: "B")
        both.addImportSource(trip.id)
        both.addImportSource(other.id)
        let elsewhere = MediaItem(id: "elsewhere", source: .file, title: "C")
        elsewhere.addImportSource(other.id)
        for item in [onlyTrip, both, elsewhere] { context.insert(item) }
        try context.save()

        let summaries = ImportSources.summaries(context: context)
        XCTAssertEqual(summaries.first { $0.id == trip.id }?.itemCount, 2)

        XCTAssertEqual(ImportSources.remove(trip, context: context), 1)
        XCTAssertNotNil(onlyTrip.deletedAt)
        XCTAssertNil(both.deletedAt)
        XCTAssertEqual(both.importSourceIDs, [other.id])
        XCTAssertNil(elsewhere.deletedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ImportSource>()).map(\.id), [other.id])
        // Settings runs the backfill again: the removed folder stays removed.
        ImportSources.backfill(context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ImportSource>()).map(\.id), [other.id])
    }

    func testRemovingApplePhotosMovesOnlyItsPhotos() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let photos = ImportSources.photosSource(context: context)
        let fromPhotos = MediaItem(id: "photos", source: .photos, title: "P")
        let fromFolder = MediaItem(id: "folder", source: .file, title: "F")
        let partners = MediaItem(id: "partner-photos", source: .photos, title: "Q")
        partners.ownerAccountID = "partner"
        for item in [fromPhotos, fromFolder, partners] { context.insert(item) }
        try context.save()

        XCTAssertEqual(ImportSources.remove(photos, context: context), 1)
        XCTAssertNotNil(fromPhotos.deletedAt)
        XCTAssertNil(fromFolder.deletedAt)
        XCTAssertNil(partners.deletedAt)
        // Only the partner's Apple Photos photos are left, so no source of mine comes back.
        ImportSources.backfill(context: context)
        let photosKind = ImportSource.Kind.photos.rawValue
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ImportSource>(predicate: #Predicate { $0.kindRaw == photosKind })), 0)
    }

    func testOutermostFoldersFoldSubfoldersIntoTheirParent() {
        let roots = ImportSources.outermostFolders(["/a/trip", "/a/trip/day1", "/a/trip/day2", "/a/tripping", "/b"])
        XCTAssertEqual(Set(roots), ["/a/trip", "/a/tripping", "/b"])
    }

    func testReimportingAFolderBringsBackItsDeletedPhotos() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("a.jpg"), date: Date(timeIntervalSince1970: 1_767_225_600), latitude: 0.01, longitude: 0.02, marker: 1)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("b.jpg"), date: Date(timeIntervalSince1970: 1_767_225_700), latitude: 0.01, longitude: 0.02, marker: 2)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(
            geocoder: FixedGeocoder(),
            geocodeCache: ImportGeocodeCache()
        )
        let first = try await importer.importFolder(folder, container: container)
        XCTAssertEqual(first.importedCount, 2)
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let sources = try context.fetch(FetchDescriptor<ImportSource>())
        XCTAssertEqual(sources.count, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.name, folder.lastPathComponent)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).map(\.importSourceIDs), [[source.id], [source.id]])

        XCTAssertEqual(ImportSources.remove(source, context: context), 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil })).count, 0)

        let again = try await importer.importFolder(folder, container: container)
        XCTAssertEqual(again.importedCount, 2)
        XCTAssertEqual(again.skippedCount, 0)
        let fresh = ModelContext(container)
        let items = try fresh.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.count, 2, "no duplicates")
        XCTAssertTrue(items.allSatisfy { $0.deletedAt == nil })
        let newSource = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ImportSource>()).first)
        XCTAssertTrue(items.allSatisfy { $0.importSourceIDs == [newSource.id] })
    }
}

private struct FixedGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City")
    }
}
