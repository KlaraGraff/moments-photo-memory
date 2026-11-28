import Foundation
import XCTest
@testable import MomentsCore

/// A store that fails while `failing` is set and otherwise "writes" what it
/// holds, like a database context whose changes stay until saved.
private final class FakeStore: SaveTarget {
    struct Failure: Error {}
    var failing = true
    var unsaved: [String] = []
    var saved: [String] = []

    func commitChanges() throws {
        if failing {
            throw NSError(domain: "FakeStoreDomain", code: 640, userInfo: [
                NSLocalizedDescriptionKey: "Could not write “ZZSECRET walk by the lake” to /Volumes/Synthetic/Library/Moments.store",
                NSFilePathErrorKey: "/Volumes/Synthetic/Library/Moments.store",
            ])
        }
        saved += unsaved
        unsaved = []
    }
}

private final class ProblemRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SaveProblem?] = []
    func append(_ value: SaveProblem?) { lock.lock(); values.append(value); lock.unlock() }
    var all: [SaveProblem?] { lock.lock(); defer { lock.unlock() }; return values }
}

final class SaveGuardTests: XCTestCase {
    func testAFailedSaveKeepsTheTextLogsItAndReportsAProblem() {
        let journal = DiagnosticsJournal()
        let saving = SaveGuard(journal: journal)
        let recorder = ProblemRecorder()
        saving.onChange = { recorder.append($0) }
        let store = FakeStore()
        store.unsaved = ["ZZSECRET walk by the lake"]

        XCTAssertFalse(saving.save(store, site: "TripMemoryLines.swift:142", retryable: true))

        // Nothing was thrown away: the words are still waiting in the store.
        XCTAssertEqual(store.unsaved, ["ZZSECRET walk by the lake"])
        XCTAssertEqual(saving.problem?.unsavedTargets, 1)
        XCTAssertEqual(saving.problem?.errorText, "FakeStoreDomain/640")
        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertNotNil(recorder.all.first ?? nil)
        // Logged with where and which error, but none of the message.
        let event = try? XCTUnwrap(journal.recent.last)
        XCTAssertEqual(event?.line, "saving save-failed site=TripMemoryLines.swift:142 error=FakeStoreDomain/640")
        for line in journal.recent.map(\.line) {
            XCTAssertFalse(line.contains("ZZSECRET"))
            XCTAssertFalse(line.contains("/Volumes"))
        }
    }

    func testTryingAgainSavesTheKeptTextAndClearsTheProblem() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let recorder = ProblemRecorder()
        saving.onChange = { recorder.append($0) }
        let store = FakeStore()
        store.unsaved = ["我们在湖边走了很久"]
        saving.save(store, site: "a.swift:1", retryable: true)

        store.failing = false
        XCTAssertTrue(saving.retryFailed())

        XCTAssertEqual(store.saved, ["我们在湖边走了很久"])
        XCTAssertNil(saving.problem)
        XCTAssertEqual(recorder.all.count, 2)
        XCTAssertNil(recorder.all.last ?? nil)
        XCTAssertEqual(saving.journal.recent.last?.name, "save-recovered")
    }

    func testALaterSaveOfTheSameStoreAlsoClearsIt() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let store = FakeStore()
        saving.save(store, site: "a.swift:1", retryable: true)
        store.failing = false
        store.unsaved = ["second"]
        XCTAssertTrue(saving.save(store, site: "b.swift:2", retryable: true))
        XCTAssertNil(saving.problem)
    }

    func testEachNewFailureRaisesTheRevisionSoAClosedNoticeShowsAgain() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let store = FakeStore()
        saving.save(store, site: "a.swift:1", retryable: true)
        let first = saving.problem?.revision
        saving.save(store, site: "a.swift:1", retryable: true)
        let second = saving.problem?.revision
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(saving.problem?.unsavedTargets, 1, "one store, however often it failed")
    }

    func testFailuresOffTheMainThreadAreShownButNotRetriedFromTheMainThread() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let store = FakeStore()
        saving.save(store, site: "a.swift:1", retryable: false)
        store.failing = false
        XCTAssertFalse(saving.retryFailed())
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertNotNil(saving.problem)
    }

    func testAStoreThatIsGoneLeavesNothingUnsavedAndIsLogged() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let recorder = ProblemRecorder()
        saving.onChange = { recorder.append($0) }
        var store: FakeStore? = FakeStore()
        saving.save(store!, site: "a.swift:1", retryable: true)
        XCTAssertNotNil(saving.problem)
        store = nil
        XCTAssertNil(saving.problem)
        // The window hears that it is gone, and the log says changes went.
        XCTAssertNil(recorder.all.last ?? nil)
        XCTAssertEqual(saving.journal.recent.last?.line, "saving save-dropped count=1")
    }

    func testASaveMadeElsewhereClearsTheProblem() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let recorder = ProblemRecorder()
        saving.onChange = { recorder.append($0) }
        let store = FakeStore()
        saving.save(store, site: "a.swift:1", retryable: false)
        // Saved by its own autosave, not through the guard.
        saving.markSaved(store)
        XCTAssertNil(saving.problem)
        XCTAssertNil(recorder.all.last ?? nil)
        // Logged at the save that failed.
        XCTAssertEqual(saving.journal.recent.last?.line, "saving save-recovered site=a.swift:1")
        // Marking a store with nothing pending says nothing.
        saving.markSaved(store)
        XCTAssertEqual(recorder.all.count, 2)
    }

    func testAnotherStoresSaveTellsTheWindowWhenAFailedStoreIsGone() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let recorder = ProblemRecorder()
        saving.onChange = { recorder.append($0) }
        var gone: FakeStore? = FakeStore()
        saving.save(gone!, site: "a.swift:1", retryable: true)
        gone = nil
        let other = FakeStore()
        other.failing = false
        XCTAssertTrue(saving.save(other, site: "b.swift:2", retryable: true))
        // Nobody read `problem` in between: the save itself said so.
        XCTAssertEqual(recorder.all.count, 2)
        XCTAssertNil(recorder.all.last ?? nil)
        XCTAssertEqual(saving.journal.recent.last?.line, "saving save-dropped count=1")
    }

    func testTryingAgainThatStillFailsKeepsTheProblem() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let store = FakeStore()
        store.unsaved = ["kept"]
        saving.save(store, site: "a.swift:1", retryable: true)
        XCTAssertFalse(saving.retryFailed())
        XCTAssertEqual(store.unsaved, ["kept"])
        XCTAssertEqual(saving.problem?.unsavedTargets, 1)
    }

    func testAnInjectedFailureFailsWithoutTouchingTheStore() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        saving.injectFailure = { site in site == "a.swift:1" ? NSError(domain: "Injected", code: 1) : nil }
        let store = FakeStore()
        store.failing = false
        store.unsaved = ["kept"]
        XCTAssertFalse(saving.save(store, site: "a.swift:1", retryable: true))
        XCTAssertEqual(store.unsaved, ["kept"])
        saving.injectFailure = nil
        XCTAssertTrue(saving.retryFailed())
        XCTAssertEqual(store.saved, ["kept"])
    }

    func testASuccessfulSaveWithNothingPendingReportsNothing() {
        let saving = SaveGuard(journal: DiagnosticsJournal())
        let recorder = ProblemRecorder()
        saving.onChange = { recorder.append($0) }
        let store = FakeStore()
        store.failing = false
        XCTAssertTrue(saving.save(store, site: "a.swift:1"))
        XCTAssertTrue(recorder.all.isEmpty)
        XCTAssertTrue(saving.journal.recent.isEmpty)
    }
}
