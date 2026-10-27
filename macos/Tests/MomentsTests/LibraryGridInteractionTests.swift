import XCTest
@testable import Moments

@MainActor
final class LibraryGridInteractionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testSecondClickDeselects() {
        let selection = SelectionModel()
        selection.click("b", order: order)
        XCTAssertEqual(selection.selectedItemIDs, ["b"])
        selection.click("b", order: order)
        XCTAssertTrue(selection.selectedItemIDs.isEmpty)
        XCTAssertNil(selection.focusedItemID)
    }

    func testPlainClickReplacesAMultipleSelection() {
        let selection = SelectionModel()
        selection.click("a", order: order)
        selection.click("c", command: true, order: order)
        XCTAssertEqual(selection.selectedItemIDs, ["a", "c"])
        // Like Finder: a plain click on one of several selected photos keeps only it.
        selection.click("c", order: order)
        XCTAssertEqual(selection.selectedItemIDs, ["c"])
    }

    func testCommandClickTogglesOne() {
        let selection = SelectionModel()
        selection.click("a", order: order)
        selection.click("d", command: true, order: order)
        selection.click("a", command: true, order: order)
        XCTAssertEqual(selection.selectedItemIDs, ["d"])
    }

    func testShiftClickSelectsTheRangeFromTheAnchor() {
        let selection = SelectionModel()
        selection.click("b", order: order)
        selection.click("d", shift: true, order: order)
        XCTAssertEqual(selection.selectedItemIDs, ["b", "c", "d"])
        XCTAssertEqual(selection.focusedItemID, "d")
        // The anchor stays at b, so a second Shift-click goes back from there.
        selection.click("a", shift: true, order: order)
        XCTAssertEqual(selection.selectedItemIDs, ["a", "b", "c", "d"])
    }

    func testShiftClickWithoutAVisibleAnchorAddsThePhoto() {
        let selection = SelectionModel()
        selection.click("d", order: order)
        // d is filtered out of view; Shift-click must not fall back to a plain click.
        selection.click("b", shift: true, order: ["a", "b", "c"])
        XCTAssertEqual(selection.selectedItemIDs, ["b", "d"])
        selection.click("b", shift: true, order: ["a", "b", "c"])
        XCTAssertEqual(selection.selectedItemIDs, ["b", "d"], "Shift-clicking the anchor must not deselect it")
    }

    func testClearForgetsTheAnchor() {
        let selection = SelectionModel()
        selection.click("b", order: order)
        selection.clear()
        selection.click("d", shift: true, order: order)
        XCTAssertEqual(selection.selectedItemIDs, ["d"])
    }

    func testOpenViewerKeepsThePagingOrder() {
        let selection = SelectionModel()
        selection.openViewer("c", in: order)
        XCTAssertEqual(selection.viewerRequest, ViewerRequest(itemIDs: order, itemID: "c"))
        selection.openViewer("z", in: [])
        XCTAssertEqual(selection.viewerRequest?.itemIDs, ["z"])
    }

    // Two sections: 7 photos in 3 columns (rows abc / def / g), then 2 photos.
    private let sections = [["a", "b", "c", "d", "e", "f", "g"], ["h", "i"]]

    func testArrowsStartAtTheFirstPhoto() {
        XCTAssertEqual(LibraryGridNavigation.move(from: nil, .down, sections: sections, columns: 3), "a")
    }

    func testLeftAndRightCrossSections() {
        XCTAssertEqual(LibraryGridNavigation.move(from: "g", .right, sections: sections, columns: 3), "h")
        XCTAssertEqual(LibraryGridNavigation.move(from: "h", .left, sections: sections, columns: 3), "g")
        XCTAssertEqual(LibraryGridNavigation.move(from: "a", .left, sections: sections, columns: 3), "a")
        XCTAssertEqual(LibraryGridNavigation.move(from: "i", .right, sections: sections, columns: 3), "i")
    }

    func testDownKeepsTheColumn() {
        XCTAssertEqual(LibraryGridNavigation.move(from: "b", .down, sections: sections, columns: 3), "e")
        // e's column has no photo in the short last row: go to its last photo.
        XCTAssertEqual(LibraryGridNavigation.move(from: "e", .down, sections: sections, columns: 3), "g")
        // From the last row into the next section, same column where it exists.
        XCTAssertEqual(LibraryGridNavigation.move(from: "g", .down, sections: sections, columns: 3), "h")
        XCTAssertEqual(LibraryGridNavigation.move(from: "i", .down, sections: sections, columns: 3), "i")
    }

    func testUpGoesToThePreviousSectionsLastRow() {
        XCTAssertEqual(LibraryGridNavigation.move(from: "e", .up, sections: sections, columns: 3), "b")
        XCTAssertEqual(LibraryGridNavigation.move(from: "h", .up, sections: sections, columns: 3), "g")
        XCTAssertEqual(LibraryGridNavigation.move(from: "i", .up, sections: sections, columns: 3), "g")
        XCTAssertEqual(LibraryGridNavigation.move(from: "a", .up, sections: sections, columns: 3), "a")
    }

    /// The smallest window has room for 3 to 8 photos per row; wider ones
    /// for more, toward small photos.
    func testStepsGrowWithTheWindow() {
        XCTAssertEqual(LibraryThumbnailSize.steps(windowWidth: 900), [3, 4, 5, 6, 8])
        XCTAssertEqual(LibraryThumbnailSize.steps(windowWidth: 600), [3, 4, 5, 6, 8])
        XCTAssertEqual(LibraryThumbnailSize.steps(windowWidth: 1111).last, 10)
        XCTAssertEqual(LibraryThumbnailSize.steps(windowWidth: 2560).last, 26)
        XCTAssertEqual(LibraryViewState().gridColumns, LibraryThumbnailSize.defaultColumns)
    }

    /// Resizing keeps the chosen count while the window has room for it, and
    /// caps it at the densest step that fits when it does not.
    func testTheWindowCapsTheChosenCountWithoutChangingIt() {
        XCTAssertEqual(LibraryThumbnailSize.shown(chosen: 4, windowWidth: 900).columns, 4)
        XCTAssertEqual(LibraryThumbnailSize.shown(chosen: 4, windowWidth: 2560).columns, 4)
        XCTAssertEqual(LibraryThumbnailSize.shown(chosen: 18, windowWidth: 2560).columns, 18)
        XCTAssertEqual(LibraryThumbnailSize.shown(chosen: 18, windowWidth: 900).columns, 8)
        // A count that is not a step shows as the nearest one.
        XCTAssertEqual(LibraryThumbnailSize.shown(chosen: 7, windowWidth: 2560).columns, 6)
    }

    func testPlusAndMinusStepFromWhatTheWindowShows() {
        XCTAssertEqual(LibraryThumbnailSize.zoomed(chosen: 4, by: -1, windowWidth: 900), 5)
        XCTAssertEqual(LibraryThumbnailSize.zoomed(chosen: 4, by: 1, windowWidth: 900), 3)
        XCTAssertNil(LibraryThumbnailSize.zoomed(chosen: 3, by: 1, windowWidth: 900))
        XCTAssertNil(LibraryThumbnailSize.zoomed(chosen: 8, by: -1, windowWidth: 900))
        XCTAssertEqual(LibraryThumbnailSize.zoomed(chosen: 8, by: -1, windowWidth: 2560), 10)
        // Capped at 8 in a small window: + goes to 6, − is at the end.
        XCTAssertEqual(LibraryThumbnailSize.zoomed(chosen: 18, by: 1, windowWidth: 900), 6)
        XCTAssertNil(LibraryThumbnailSize.zoomed(chosen: 18, by: -1, windowWidth: 900))
    }

    func testUpToFivePerRowArePrints() {
        XCTAssertFalse(LibraryThumbnailSize(columns: LibraryThumbnailSize.defaultColumns).isCompact)
        XCTAssertFalse(LibraryThumbnailSize(columns: 5).isCompact)
        XCTAssertTrue(LibraryThumbnailSize(columns: 6).isCompact)
    }

    func testTheOldZoomLevelBecomesItsCount() throws {
        let suite = "moments.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: LibraryThumbnailSize.legacyLevelKey)
        LibraryThumbnailSize.migrateLegacyLevel(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: LibraryThumbnailSize.storageKey), 8)
        XCTAssertNil(defaults.object(forKey: LibraryThumbnailSize.legacyLevelKey))
        // Once only: a later choice stays.
        defaults.set(12, forKey: LibraryThumbnailSize.storageKey)
        defaults.set(2, forKey: LibraryThumbnailSize.legacyLevelKey)
        LibraryThumbnailSize.migrateLegacyLevel(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: LibraryThumbnailSize.storageKey), 12)
    }
}
