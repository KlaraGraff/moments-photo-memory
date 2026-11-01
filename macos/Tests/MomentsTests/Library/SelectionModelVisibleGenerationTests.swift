import Foundation
import XCTest
@testable import Moments

/// The counter pages hash instead of the whole `visibleItemIDs` set.
@MainActor
final class SelectionModelVisibleGenerationTests: XCTestCase {
    func testNewModelStartsAtGenerationZero() {
        let model: SelectionModel = SelectionModel()
        let expected: Int = 0
        XCTAssertEqual(model.visibleGeneration, expected)
        XCTAssertNil(model.visibleItemIDs)
    }

    func testAssigningASetBumpsTheGenerationByOne() {
        let model: SelectionModel = SelectionModel()
        let ids: Set<String> = ["a", "b"]
        model.visibleItemIDs = ids
        let expected: Int = 1
        XCTAssertEqual(model.visibleGeneration, expected)
        XCTAssertEqual(model.visibleItemIDs, ids)
    }

    /// "No filter" is a real value: pages must rebuild when it comes back.
    func testAssigningNilBumpsTheGeneration() {
        let model: SelectionModel = SelectionModel()
        model.visibleItemIDs = nil
        let expected: Int = 1
        XCTAssertEqual(model.visibleGeneration, expected)
        XCTAssertNil(model.visibleItemIDs)
    }

    func testTwoAssignmentsBumpTheGenerationByTwo() {
        let model: SelectionModel = SelectionModel()
        let first: Set<String> = ["a"]
        let second: Set<String> = ["b", "c"]
        model.visibleItemIDs = first
        model.visibleItemIDs = second
        let expected: Int = 2
        XCTAssertEqual(model.visibleGeneration, expected)
        XCTAssertEqual(model.visibleItemIDs, second)
    }
}
