import Foundation
import XCTest
@testable import MomentsCore

/// What may be logged and exported: codes, counts and short ID prefixes,
/// never words from the library, places, coordinates or paths.
final class DiagnosticsTests: XCTestCase {
    private let marker = "ZZSECRET"

    func testTokensStopAtAnythingThatIsNotPlainCode() {
        XCTAssertEqual(DiagnosticSanitizer.token("NSCocoaErrorDomain"), "NSCocoaErrorDomain")
        XCTAssertEqual(DiagnosticSanitizer.token("Moments.SaveError"), "Moments.SaveError")
        XCTAssertEqual(DiagnosticSanitizer.token("Domain /Volumes/Synthetic/ZZSECRET"), "Domain")
        XCTAssertNil(DiagnosticSanitizer.token("/Volumes/Synthetic"))
        XCTAssertNil(DiagnosticSanitizer.token("湖边"))
        XCTAssertEqual(DiagnosticSanitizer.token(String(repeating: "a", count: 100))?.count, 64)
    }

    func testIDsAreCutToTheirFirstEightCharacters() {
        XCTAssertEqual(DiagnosticSanitizer.idPrefix("1a2b3c4d-5e6f-7a8b-9c0d-112233445566"), "1A2B3C4D")
        XCTAssertEqual(DiagnosticSanitizer.idPrefix("abc"), "ABC")
        XCTAssertNil(DiagnosticSanitizer.idPrefix("--"))
    }

    func testSitesKeepOnlyTheFileNameAndLine() {
        XCTAssertEqual(DiagnosticSanitizer.site(file: "Moments/Timeline/TripEdits.swift", line: 358), "TripEdits.swift:358")
    }

    func testAnEventFromAnErrorKeepsItsCodeAndDropsItsMessage() {
        let error = NSError(domain: "NSCocoaErrorDomain", code: 134030, userInfo: [
            NSLocalizedDescriptionKey: "\(marker) at 0.001, 0.002",
            NSFilePathErrorKey: "/Volumes/Synthetic/\(marker)/Moments.store",
        ])
        let event = DiagnosticEvent(.saving, "save-failed", site: "TripEdits.swift:358", error: error, id: "1a2b3c4d-5e6f", count: 3)
        XCTAssertEqual(event.line, "saving save-failed site=TripEdits.swift:358 error=NSCocoaErrorDomain/134030 id=1A2B3C4D count=3")
    }

    func testTheJournalKeepsOnlyTheNewestEvents() {
        let journal = DiagnosticsJournal(capacity: 3)
        for count in 0..<5 { journal.record(DiagnosticEvent(.app, "tick", count: count)) }
        XCTAssertEqual(journal.recent.map(\.count), [2, 3, 4])
    }

    func testRecentErrorCodesAreDistinctAndNewestFirst() {
        let journal = DiagnosticsJournal()
        journal.record(DiagnosticEvent(.saving, "save-failed", error: NSError(domain: "A", code: 1)))
        journal.record(DiagnosticEvent(.backup, "backup-failed", error: NSError(domain: "B", code: 2)))
        journal.record(DiagnosticEvent(.saving, "save-failed", error: NSError(domain: "A", code: 1)))
        XCTAssertEqual(journal.recentErrorCodes, ["A/1", "B/2"])
    }

    func testTheReportHasVersionsCountsAndCodesButNothingPersonal() {
        let error = NSError(domain: "NSCocoaErrorDomain", code: 134030, userInfo: [
            NSLocalizedDescriptionKey: "Could not save “\(marker) 湖边的晚饭”",
            NSFilePathErrorKey: "/Volumes/Synthetic/Library/Application Support/Moments/\(marker).store",
        ])
        let report = DiagnosticsReport(
            appVersion: "0.9.0",
            buildNumber: "1",
            systemVersion: "Version 14.6.1 (Build 23G93)",
            architecture: "arm64",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            counts: [("photos", 50_000), ("memories", 812)],
            events: [DiagnosticEvent(.saving, "save-failed", site: "MemoryComments.swift:373", error: error, id: "abcdef12-3456", date: Date(timeIntervalSince1970: 1_790_000_000))]
        )
        let text = report.text
        XCTAssertTrue(text.contains("version: 0.9.0 (1)"))
        XCTAssertTrue(text.contains("macOS: Version 14.6.1 (Build 23G93)"))
        XCTAssertTrue(text.contains("photos: 50000"))
        XCTAssertTrue(text.contains("  NSCocoaErrorDomain/134030"))
        XCTAssertTrue(text.contains("site=MemoryComments.swift:373"))
        XCTAssertFalse(text.contains(marker))
        XCTAssertFalse(text.contains("湖边"))
        XCTAssertFalse(text.contains("/Volumes"))
        XCTAssertFalse(text.contains("Application Support"))
    }

    func testAReportWithoutALibrarySaysSo() {
        let report = DiagnosticsReport(appVersion: "0.9.0", buildNumber: "1", systemVersion: "14.6", architecture: "arm64", counts: [], events: [])
        XCTAssertTrue(report.text.contains("no library open"))
        XCTAssertTrue(report.text.contains("recent errors:\n  none"))
    }

    func testVersionTextCannotCarryAPath() {
        XCTAssertFalse(DiagnosticsReport.version("0.9.0/Volumes/Synthetic").contains("/"))
        XCTAssertEqual(DiagnosticsReport.version(""), "unknown")
    }
}
