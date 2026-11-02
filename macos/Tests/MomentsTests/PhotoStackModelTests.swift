import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class PhotoStackModelTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Four look-alike shots a second apart, a different photo a minute
    /// later, a video and a screenshot inside the burst's seconds.
    private func makeLibrary() throws -> (ModelContainer, [MediaItem]) {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        var items: [MediaItem] = (0..<4).map { index in
            MediaItem(id: "shot-\(index)", captureDate: base.addingTimeInterval(Double(index)), kind: .photo, perceptualHash: String(format: "%016llx", UInt64(index)))
        }
        items.append(MediaItem(id: "later", captureDate: base.addingTimeInterval(60), kind: .photo, perceptualHash: "0000000000000000"))
        items.append(MediaItem(id: "clip", captureDate: base.addingTimeInterval(1.5), kind: .video, perceptualHash: "0000000000000000"))
        items.append(MediaItem(id: "screen", captureDate: base.addingTimeInterval(2.5), kind: .photo, isScreenshot: true, perceptualHash: "0000000000000000"))
        for item in items { context.insert(item) }
        try context.save()
        return (container, items)
    }

    private func model() -> PhotoStackModel {
        PhotoStackModel(analysis: PhotoStackAnalysisStore(fileURL: nil))
    }

    private func stackRecords(_ context: ModelContext) throws -> [UserGroup] {
        try context.fetch(FetchDescriptor<UserGroup>()).filter { $0.kind == .stack }
    }

    func testBurstBecomesOneStackWithoutVideosOrScreenshots() throws {
        // The container must outlive the items, or SwiftData resets them.
        let (container, items) = try makeLibrary()
        let index = model().update(items: items, decisions: [])
        withExtendedLifetime(container) {}
        XCTAssertEqual(index.stacks.count, 1)
        XCTAssertEqual(index.stack(containing: "shot-2")?.memberIDs, ["shot-0", "shot-1", "shot-2", "shot-3"])
        XCTAssertNil(index.stack(containing: "clip"))
        XCTAssertNil(index.stack(containing: "screen"))
        XCTAssertNil(index.stack(containing: "later"))
    }

    // A screen that passes the same source key twice does not get its photos
    // hashed again: the memo hands back the photos key of the first call, so
    // the second call returns the index it already had and detects nothing.
    func testSameSourceKeySkipsRehashing() throws {
        let (container, items) = try makeLibrary()
        let stacks: PhotoStackModel = model()
        let sourceKey: Int = 41
        let first: PhotoStackIndex = stacks.update(items: items, decisions: [], sourceKey: sourceKey)
        let generation: Int = stacks.generation
        XCTAssertEqual(first.stacks.count, 1)

        // A different list under the same source key. Were it hashed, the
        // burst would be gone; a memo hit keeps the photos of the first call.
        let others: [MediaItem] = items.filter { (item: MediaItem) -> Bool in
            item.id == "later"
        }
        let second: PhotoStackIndex = stacks.update(items: others, decisions: [], sourceKey: sourceKey)
        withExtendedLifetime(container) {}
        XCTAssertEqual(second, first, "the same source key must reuse the photos key")
        XCTAssertEqual(stacks.generation, generation, "the same source key must not detect again")
        XCTAssertEqual(second.stack(containing: "shot-0")?.memberIDs.count, 4)
    }

    // A new source key hashes the photos it is handed, so a list that folds
    // differently is detected.
    func testNewSourceKeyRehashes() throws {
        let (container, items) = try makeLibrary()
        let stacks: PhotoStackModel = model()
        let first: PhotoStackIndex = stacks.update(items: items, decisions: [], sourceKey: 41)
        let generation: Int = stacks.generation
        XCTAssertEqual(first.stacks.count, 1)

        // The same photos without the burst: hashed again, nothing folds.
        let others: [MediaItem] = items.filter { (item: MediaItem) -> Bool in
            item.id == "later" || item.id == "clip"
        }
        let second: PhotoStackIndex = stacks.update(
            items: others,
            decisions: [],
            waits: true,
            sourceKey: 42
        )
        withExtendedLifetime(container) {}
        XCTAssertTrue(second.isEmpty, "a new source key must hash the photos passed")
        XCTAssertNil(second.stack(containing: "shot-0"))
        XCTAssertGreaterThan(stacks.generation, generation, "the new list must be detected")
    }

    func testSetCoverIsStoredAndUndone() throws {
        let (container, items) = try makeLibrary()
        let context = container.mainContext
        let stacks = model()
        stacks.update(items: items, decisions: [])
        let stack = try XCTUnwrap(stacks.stack(containing: "shot-0"))
        XCTAssertEqual(stack.coverID, "shot-0")

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        stacks.setCover("shot-2", of: stack, context: context, undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertEqual(stacks.stack(containing: "shot-0")?.coverID, "shot-2")
        XCTAssertEqual(stacks.stack(containing: "shot-0")?.isCoverChosen, true)
        XCTAssertEqual(try stackRecords(context).count, 1)
        XCTAssertEqual(stacks.lastChange?.kind, .cover)

        // A fresh model reading the store sees the same cover.
        let reread = model()
        reread.update(items: items, decisions: try stackRecords(context))
        XCTAssertEqual(reread.stack(containing: "shot-3")?.coverID, "shot-2")

        undoManager.undo()
        XCTAssertEqual(try stackRecords(context).count, 0)
        XCTAssertEqual(stacks.stack(containing: "shot-0")?.coverID, "shot-0")
    }

    func testUnstackShowsEveryShotAndUndoStacksThemAgain() throws {
        let (container, items) = try makeLibrary()
        let context = container.mainContext
        let stacks = model()
        stacks.update(items: items, decisions: [])
        let stack = try XCTUnwrap(stacks.stack(containing: "shot-0"))
        stacks.setCover("shot-1", of: stack, context: context)
        let chosen = try XCTUnwrap(stacks.stack(containing: "shot-0"))

        stacks.unstack(chosen, context: context)
        XCTAssertNil(stacks.stack(containing: "shot-0"))
        XCTAssertTrue(stacks.index.isEmpty)

        let change = try XCTUnwrap(stacks.lastChange)
        stacks.undo(change, context: context)
        XCTAssertEqual(stacks.stack(containing: "shot-3")?.coverID, "shot-1")
        XCTAssertNil(stacks.lastChange)
    }

    func testRemovedShotStaysOnItsOwn() throws {
        let (container, items) = try makeLibrary()
        let context = container.mainContext
        let stacks = model()
        stacks.update(items: items, decisions: [])
        let stack = try XCTUnwrap(stacks.stack(containing: "shot-0"))

        stacks.remove("shot-1", from: stack, context: context)
        XCTAssertNil(stacks.stack(containing: "shot-1"))
        XCTAssertEqual(stacks.stack(containing: "shot-0")?.memberIDs, ["shot-0", "shot-2", "shot-3"])

        // Folding a newest-first grid: the stack is one cell, the removed shot its own.
        let folded = LibraryFilterEngine.folding(
            [LibrarySection(id: "s", title: "", itemIDs: ["later", "shot-3", "shot-2", "shot-1", "shot-0"], startDate: nil, endDate: nil)],
            with: stacks.index
        )
        XCTAssertEqual(folded.sections[0].itemIDs, ["later", "shot-0", "shot-1"])
        XCTAssertEqual(folded.stackCounts, ["shot-0": 3])
    }

    func testAnalysisRoundTripsThroughItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "stack-analysis-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PhotoStackAnalysisStore(fileURL: url)
        let analysis = PhotoStackAnalysis(featurePrint: [0.25, -1, 3.5], quality: StackQuality(sharpness: 12, faceCount: 1, faceQuality: 0.6, eyesOpen: 1))
        store.merge(["a": analysis])
        XCTAssertEqual(store.revision, 1)
        store.finish()

        // Written in the background, then read back the same way at launch.
        let deadline = Date().addingTimeInterval(5)
        while PhotoStackAnalysisStore.read(from: url)?["a"] == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(PhotoStackAnalysisStore.read(from: url)?["a"], analysis)
        let reread = PhotoStackAnalysisStore(fileURL: url)
        while reread.entries["a"] == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(reread.entries["a"], analysis)
    }

    func testFinishDropsResultsForDeletedPhotos() {
        let store = PhotoStackAnalysisStore(fileURL: nil)
        let analysis = PhotoStackAnalysis(featurePrint: nil, quality: StackQuality(sharpness: 1))
        store.merge(["kept": analysis, "deleted": analysis])
        store.finish(keeping: ["kept"])
        XCTAssertEqual(Array(store.entries.keys), ["kept"])
    }

    func testSharperImageScoresHigher() {
        func image(sharp: Bool) -> CGImage {
            let size = 256
            let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            for x in stride(from: 0, to: size, by: 16) {
                context.setFillColor(gray: (x / 16).isMultiple(of: 2) ? 0.1 : 0.9, alpha: 1)
                context.fill(CGRect(x: x, y: 0, width: 16, height: size))
            }
            let crisp = context.makeImage()!
            guard !sharp else { return crisp }
            // Drawn small and scaled up again: the stripes' edges soften.
            let small = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            small.interpolationQuality = .high
            small.draw(crisp, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let blurred = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            blurred.interpolationQuality = .high
            blurred.draw(small.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
            return blurred.makeImage()!
        }
        XCTAssertGreaterThan(PhotoStackAnalyzer.sharpness(of: image(sharp: true)), PhotoStackAnalyzer.sharpness(of: image(sharp: false)))
    }
}
