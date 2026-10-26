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

    func testAdaptiveColumnCount() {
        XCTAssertEqual(LibraryGridNavigation.columns(width: 174, minimum: 175, spacing: 24), 1)
        XCTAssertEqual(LibraryGridNavigation.columns(width: 374, minimum: 175, spacing: 24), 2)
        XCTAssertEqual(LibraryGridNavigation.columns(width: 800, minimum: 175, spacing: 24), 4)
    }
}
