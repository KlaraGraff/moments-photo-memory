import Foundation
import XCTest
@testable import Moments

/// The window's one back button: it returns to where a jump came from, else
/// one level up, and the open photo is the first thing it leaves.
@MainActor
final class SelectionModelBackTests: XCTestCase {
    /// What the window does after a jump: shows the page asked for.
    private func settle(_ model: SelectionModel) {
        if let destination: SidebarDestination = model.requestedDestination {
            model.page = destination
            model.requestedDestination = nil
        }
    }

    func testNothingToGoBackToOnAPagesTopLevel() {
        let model: SelectionModel = SelectionModel()
        XCTAssertNil(model.backTarget)
        model.page = .trips
        XCTAssertNil(model.backTarget)
    }

    func testAPlaceClickedInAChapterLeadsBackToTheChapterThenTheShelf() {
        let model: SelectionModel = SelectionModel()
        model.page = .trips
        model.openTripID = "trip-a"
        model.showInLibrary(["p1", "p2"], title: "Harbour", placeName: "Harbour")
        settle(model)
        XCTAssertEqual(model.page, .library)
        XCTAssertEqual(model.libraryScope?.placeName, "Harbour")

        let first: SidebarDestination = model.goBack()
        XCTAssertEqual(first, .trips)
        XCTAssertEqual(model.page, .trips)
        XCTAssertEqual(model.openTripID, "trip-a")
        XCTAssertNil(model.libraryScope, "The Library should be as it was before the place was clicked")

        // The chapter was opened on the shelf, without a jump: one level up.
        let second: SidebarDestination = model.goBack()
        XCTAssertEqual(second, .trips)
        XCTAssertNil(model.openTripID)
        XCTAssertNil(model.backTarget)
    }

    func testAPersonsPhotosLeadBackToAllPhotos() {
        let model: SelectionModel = SelectionModel()
        model.showInLibrary(["p1"], title: "Alex", personID: "alex")
        settle(model)
        let target: NavigationStop? = model.backTarget
        XCTAssertEqual(target?.page, .library)
        XCTAssertNil(target?.libraryScope)
        model.goBack()
        XCTAssertNil(model.libraryScope)
        XCTAssertNil(model.backTarget)
    }

    func testBackReopensThePhotoALinkWasClickedIn() {
        let model: SelectionModel = SelectionModel()
        model.openViewer("p2", in: ["p1", "p2", "p3"])
        model.showTrip("trip-a")
        settle(model)
        XCTAssertNil(model.viewerRequest)
        XCTAssertEqual(model.page, .trips)

        model.goBack()
        XCTAssertEqual(model.page, .library)
        XCTAssertEqual(model.viewerRequest, ViewerRequest(itemIDs: ["p1", "p2", "p3"], itemID: "p2"))

        // The open photo goes first, and only it.
        model.goBack()
        XCTAssertNil(model.viewerRequest)
        XCTAssertEqual(model.page, .library)
        XCTAssertNil(model.backTarget)
    }

    func testShowInLibraryFromTheLargeMapLeadsBackToTheMap() {
        let model: SelectionModel = SelectionModel()
        model.page = .trips
        model.showMap(title: "Map", itemIDs: nil)
        XCTAssertNotNil(model.mapScope)
        model.showInLibrary(["p1"], title: "Portugal")
        settle(model)
        XCTAssertNil(model.mapScope)

        model.goBack()
        XCTAssertEqual(model.page, .trips)
        XCTAssertEqual(model.mapScope, MapScope(title: "Map", itemIDs: nil))
        XCTAssertNil(model.libraryScope)

        model.goBack()
        XCTAssertNil(model.mapScope)
        XCTAssertEqual(model.page, .trips)
        XCTAssertNil(model.backTarget)
    }

    func testTheMapComesBackAtThePlaceItHadOpen() {
        let model: SelectionModel = SelectionModel()
        model.page = .trips
        model.showMap(title: "Map", itemIDs: nil)
        // The map opened a place's strip of photos.
        model.mapOpenPlaceItemID = "p7"
        model.showInLibrary(["p7", "p8"], title: "Lisbon")
        settle(model)
        XCTAssertNil(model.mapOpenPlaceItemID)

        model.goBack()
        XCTAssertEqual(model.mapScope, MapScope(title: "Map", itemIDs: nil))
        XCTAssertEqual(model.mapFocusRequest, "p7", "The map should fly back to the place it had open")
        XCTAssertEqual(model.focusedItemID, "p7", "The place's photo should be selected so the place stays open")
    }

    func testRenamingInTheHeadingAddsNoStep() {
        let model: SelectionModel = SelectionModel()
        model.showInLibrary(["p1"], title: "Harbour", placeName: "Harbour")
        settle(model)
        model.showInLibrary(["p1", "p2"], title: "Harbour cafe", placeName: "Harbour cafe", replacing: true)
        settle(model)
        model.goBack()
        XCTAssertNil(model.libraryScope, "Back should skip the old name and return to all photos")
        XCTAssertNil(model.backTarget)
    }

    func testOnePersonAfterAnotherGoesBackThroughBoth() {
        let model: SelectionModel = SelectionModel()
        model.showInLibrary(["p1"], title: "Alex", personID: "alex")
        settle(model)
        model.showInLibrary(["p2"], title: "Robin", personID: "robin")
        settle(model)
        model.goBack()
        XCTAssertEqual(model.libraryScope?.personID, "alex")
        model.goBack()
        XCTAssertNil(model.libraryScope)
    }

    func testAPageFromTheSidebarStartsOver() {
        let model: SelectionModel = SelectionModel()
        model.page = .trips
        model.openTripID = "trip-a"
        model.showInLibrary(["p1"], title: "Alex", personID: "alex")
        settle(model)
        model.forgetBackHistory()
        let target: NavigationStop? = model.backTarget
        XCTAssertEqual(target?.page, .library, "Only one level up is left: all photos")
        XCTAssertNil(target?.libraryScope)
    }

    func testAStepThatIsWhereTheWindowAlreadyIsIsSkipped() {
        let model: SelectionModel = SelectionModel()
        model.showInLibrary(["p1"], title: "Alex", personID: "alex")
        settle(model)
        // The group was ignored: the heading went away without Back.
        model.libraryScope = nil
        XCTAssertNil(model.backTarget, "Back would lead to where the window already is")
        model.goBack()
        XCTAssertEqual(model.page, .library)
        XCTAssertNil(model.libraryScope)
    }

    func testADeletedPhotoIsNotReopened() {
        let model: SelectionModel = SelectionModel()
        model.openViewer("p2", in: ["p1", "p2", "p3"])
        model.showTrip("trip-a")
        settle(model)
        let deleted: Set<String> = ["p2"]
        model.forget(deleted: deleted)
        model.goBack()
        XCTAssertEqual(model.viewerRequest, ViewerRequest(itemIDs: ["p1", "p3"], itemID: "p3"))
    }

    func testTheHistoryIsCapped() {
        let model: SelectionModel = SelectionModel()
        for index in 0..<(SelectionModel.backStackLimit + 10) {
            model.showInLibrary(["p\(index)"], title: "Place \(index)", placeName: "Place \(index)")
            settle(model)
        }
        XCTAssertEqual(model.backStack.count, SelectionModel.backStackLimit)
    }
}
