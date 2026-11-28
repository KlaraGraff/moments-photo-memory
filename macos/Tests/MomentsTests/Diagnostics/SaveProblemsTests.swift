import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// Saving never fails silently: a failed save keeps what was written, is
/// logged without its content, shows the notice, and Try Again writes it.
/// The diagnostics file holds counts and codes, never what was written.
@MainActor
final class SaveProblemsTests: XCTestCase {
    private let marker = "ZZSECRET-湖边的晚饭"

    /// An error that, like a real one, carries a path and words in its message.
    private var failure: NSError {
        NSError(domain: NSCocoaErrorDomain, code: 134030, userInfo: [
            NSLocalizedDescriptionKey: "Could not save “\(marker)”",
            NSFilePathErrorKey: "/Volumes/Synthetic/\(marker)/Moments.store",
        ])
    }

    override func tearDown() {
        SaveProblems.guard.injectFailure = nil
        SaveProblems.guard.retryFailed()
        SaveProblems.shared.refresh()
        super.tearDown()
    }

    func testAFailedSaveKeepsTheMemoryAndTryingAgainWritesIt() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let journal = DiagnosticsJournal()
        let saving = SaveGuard(journal: journal)
        let failure = failure
        saving.injectFailure = { _ in failure }
        let item = MediaItem(id: "save-problem-item", title: "Synthetic")
        context.insert(item)
        context.insert(Memory(text: marker, mediaItem: item))

        XCTAssertFalse(saving.save(context, site: "SaveProblemsTests.swift:1"))

        // Still there, still unsaved: nothing was rolled back.
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Memory>()).map(\.text), [marker])
        XCTAssertEqual(saving.problem?.errorText, "NSCocoaErrorDomain/134030")
        // Logged, with the code and nothing of the words or the path.
        XCTAssertEqual(journal.recent.map(\.line), ["saving save-failed site=SaveProblemsTests.swift:1 error=NSCocoaErrorDomain/134030"])

        saving.injectFailure = nil
        XCTAssertTrue(saving.retryFailed())
        XCTAssertNil(saving.problem)
        // Written to the store: a fresh context reads it back.
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Memory>()).map(\.text), [marker])
    }

    func testSaveOrReportShowsTheNoticeUntilTryAgainSaves() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let failure = failure
        SaveProblems.guard.injectFailure = { _ in failure }
        context.insert(MediaItem(id: "save-problem-notice", title: "Synthetic"))

        XCTAssertFalse(context.saveOrReport())
        XCTAssertNotNil(SaveProblems.shared.visibleProblem)
        XCTAssertEqual(MomentsLog.journal.recent.last?.name, "save-failed")

        // Closed: hidden until saving fails again.
        SaveProblems.shared.dismiss()
        XCTAssertNil(SaveProblems.shared.visibleProblem)
        XCTAssertFalse(context.saveOrReport())
        XCTAssertNotNil(SaveProblems.shared.visibleProblem)

        SaveProblems.guard.injectFailure = nil
        SaveProblems.shared.tryAgain()
        XCTAssertNil(SaveProblems.shared.visibleProblem)
        XCTAssertFalse(context.hasChanges)
    }

    func testAnotherSaveOfTheSameContextHidesTheNotice() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let failure = failure
        SaveProblems.guard.injectFailure = { _ in failure }
        context.insert(MediaItem(id: "save-problem-autosave", title: "Synthetic"))
        XCTAssertFalse(context.saveOrReport())
        XCTAssertNotNil(SaveProblems.shared.visibleProblem)

        // Like autosave: saved without the guard, so nothing is unsaved now.
        SaveProblems.guard.injectFailure = nil
        try context.save()
        SaveProblems.shared.refresh()
        XCTAssertNil(SaveProblems.shared.visibleProblem)
    }

    func testQuittingWithEverythingSavedDoesNotAsk() {
        var asked = false
        XCTAssertEqual(SaveProblems.shared.confirmQuit(quitAnyway: { asked = true; return true }), .terminateNow)
        XCTAssertFalse(asked)
    }

    func testQuittingWithUnsavedChangesTriesOnceMoreThenAsks() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let failure = failure
        SaveProblems.guard.injectFailure = { _ in failure }
        context.insert(MediaItem(id: "save-problem-quit", title: "Synthetic"))
        XCTAssertFalse(context.saveOrReport())

        var asked = 0
        // "Don't Quit": stays open, the changes still there.
        XCTAssertEqual(SaveProblems.shared.confirmQuit(quitAnyway: { asked += 1; return false }), .terminateCancel)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(context.hasChanges)
        // "Quit Anyway".
        XCTAssertEqual(SaveProblems.shared.confirmQuit(quitAnyway: { asked += 1; return true }), .terminateNow)
        // Saving works again: the last try writes it and nobody is asked.
        SaveProblems.guard.injectFailure = nil
        XCTAssertEqual(SaveProblems.shared.confirmQuit(quitAnyway: { asked += 1; return false }), .terminateNow)
        XCTAssertEqual(asked, 2)
        XCTAssertFalse(context.hasChanges)
    }

    func testTheDiagnosticsFileHasNoMemoriesNamesOrPaths() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "diagnostics-item", title: marker)
        context.insert(item)
        let memory = Memory(text: marker, mediaItem: item)
        context.insert(memory)
        context.insert(Comment(memoryID: memory.id, text: marker))
        context.insert(Person(name: marker))
        context.insert(Place(name: marker, latitude: 0.0012, longitude: 0.0034))
        try context.save()
        let journal = DiagnosticsJournal()
        journal.record(DiagnosticEvent(.saving, "save-failed", site: "MemoryComments.swift:373", error: failure, id: memory.id))

        let text = DiagnosticsExport.report(context: context, journal: journal).text

        XCTAssertTrue(text.contains("photos: 1"))
        XCTAssertTrue(text.contains("memories: 1"))
        XCTAssertTrue(text.contains("comments: 1"))
        XCTAssertTrue(text.contains("places: 1"))
        XCTAssertTrue(text.contains("NSCocoaErrorDomain/134030"))
        XCTAssertFalse(text.contains("ZZSECRET"))
        XCTAssertFalse(text.contains("湖边"))
        XCTAssertFalse(text.contains("/Volumes"))
        XCTAssertFalse(text.contains("0.0012"), "no coordinates")
        XCTAssertFalse(text.contains(memory.id), "only the first characters of an ID")
    }

    func testARealFailedSaveReachesTheDiagnosticsFileAsACodeOnly() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "diagnostics-real-failure", title: marker)
        context.insert(item)
        context.insert(Memory(text: marker, mediaItem: item))
        let failure = failure
        SaveProblems.guard.injectFailure = { _ in failure }
        XCTAssertFalse(context.saveOrReport())

        // The app's own journal, as Export Diagnostics reads it.
        let text = DiagnosticsExport.report(context: context).text

        XCTAssertTrue(text.contains("save-failed site=SaveProblemsTests.swift:"))
        XCTAssertTrue(text.contains("NSCocoaErrorDomain/134030"))
        XCTAssertFalse(text.contains("ZZSECRET"))
        XCTAssertFalse(text.contains("湖边"))
        XCTAssertFalse(text.contains("/Volumes"))
    }

    func testTheLoggerUsesTheAppsOwnIdentifier() {
        XCTAssertEqual(MomentsLog.subsystem, "com.momentsphotomemory.Moments")
    }
}
