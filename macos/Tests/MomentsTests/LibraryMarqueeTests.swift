import XCTest
@testable import Moments

final class LibraryMarqueeTests: XCTestCase {
    /// Two rows of three 100 × 80 photos with 10 pt gaps.
    private let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 100, height: 80),
        "b": CGRect(x: 110, y: 0, width: 100, height: 80),
        "c": CGRect(x: 220, y: 0, width: 100, height: 80),
        "d": CGRect(x: 0, y: 90, width: 100, height: 80),
        "e": CGRect(x: 110, y: 90, width: 100, height: 80),
        "f": CGRect(x: 220, y: 90, width: 100, height: 80),
    ]

    func testTheRectangleSelectsEveryPhotoItTouches() {
        // From the gap left of "a" to the middle of "e".
        let rect = CGRect(x: -5, y: -5, width: 165, height: 135)
        XCTAssertEqual(LibraryMarquee.hits(in: rect, frames: frames), ["a", "b", "d", "e"])
    }

    func testARectangleInAGapSelectsNothing() {
        let rect = CGRect(x: 101, y: 0, width: 8, height: 170)
        XCTAssertTrue(LibraryMarquee.hits(in: rect, frames: frames).isEmpty)
    }

    func testAThinRectangleStillSelects() {
        // A straight-down drag has no width but crosses "b" and "e".
        let rect = CGRect(x: 150, y: -5, width: 0, height: 120)
        XCTAssertEqual(LibraryMarquee.hits(in: rect, frames: frames), ["b", "e"])
    }

    func testPlainDragReplacesTheSelection() {
        XCTAssertEqual(LibraryMarquee.selection(base: ["a", "f"], hits: ["b", "c"], mode: .replace), ["b", "c"])
    }

    func testShiftDragAdds() {
        XCTAssertEqual(LibraryMarquee.selection(base: ["a", "f"], hits: ["a", "b"], mode: .add), ["a", "b", "f"])
    }

    func testCommandDragFlipsWhatItTouches() {
        XCTAssertEqual(LibraryMarquee.selection(base: ["a", "f"], hits: ["a", "b"], mode: .toggle), ["b", "f"])
        // Shrinking the rectangle back gives the photo back its old state.
        XCTAssertEqual(LibraryMarquee.selection(base: ["a", "f"], hits: [], mode: .toggle), ["a", "f"])
    }

    func testAutoscrollOnlyNearTheEdges() {
        XCTAssertEqual(LibraryMarquee.autoscrollVelocity(pointerY: 300, top: 0, bottom: 600), 0)
        XCTAssertGreaterThan(LibraryMarquee.autoscrollVelocity(pointerY: 590, top: 0, bottom: 600), 0)
        XCTAssertLessThan(LibraryMarquee.autoscrollVelocity(pointerY: 10, top: 0, bottom: 600), 0)
    }

    func testAutoscrollSpeedsUpTowardsAndPastTheEdge() {
        let entering = LibraryMarquee.autoscrollVelocity(pointerY: 560, top: 0, bottom: 600)
        let atEdge = LibraryMarquee.autoscrollVelocity(pointerY: 600, top: 0, bottom: 600)
        let past = LibraryMarquee.autoscrollVelocity(pointerY: 700, top: 0, bottom: 600)
        let farPast = LibraryMarquee.autoscrollVelocity(pointerY: 5000, top: 0, bottom: 600)
        XCTAssertGreaterThan(entering, 0)
        XCTAssertGreaterThan(atEdge, entering)
        XCTAssertGreaterThan(past, atEdge)
        XCTAssertEqual(farPast, 3200, "the speed is capped")
        // The same either way.
        XCTAssertEqual(LibraryMarquee.autoscrollVelocity(pointerY: 0, top: 0, bottom: 600), -atEdge)
    }

    /// Held still at the edge, the grid keeps scrolling: the speed never
    /// drops to zero inside the zone or past the edge.
    func testHoldingAtTheEdgeKeepsScrolling() {
        for y in stride(from: 557, through: 900, by: 7) {
            XCTAssertGreaterThan(LibraryMarquee.autoscrollVelocity(pointerY: CGFloat(y), top: 0, bottom: 600), 0, "stopped at \(y)")
        }
    }
}
