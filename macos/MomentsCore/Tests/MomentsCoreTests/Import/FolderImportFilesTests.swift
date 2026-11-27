import Foundation
import XCTest
@testable import MomentsCore

final class FolderImportFilesTests: XCTestCase {
    func testNewPictureAndRawFormatsAreSupportedInAnyCase() {
        for ext in ["heif", "HIF", "gif", "tif", "TIFF", "webp", "dng", "CR3", "cr2", "nef", "arw", "raf", "orf", "rw2", "pef"] {
            XCTAssertTrue(SupportedMediaFile.isSupported(pathExtension: ext), ext)
        }
        for ext in ["jpg", "jpeg", "heic", "png", "mov", "mp4"] {
            XCTAssertTrue(SupportedMediaFile.isSupported(pathExtension: ext), ext)
        }
        for ext in ["xmp", "aae", "txt", "pdf", "psd", ""] {
            XCTAssertFalse(SupportedMediaFile.isSupported(pathExtension: ext), ext)
        }
        XCTAssertTrue(SupportedMediaFile.isRaw(pathExtension: "NEF"))
        XCTAssertFalse(SupportedMediaFile.isRaw(pathExtension: "jpg"))
    }

    func testARawFileShotWithAJpegIsLeftOutButARawOnItsOwnIsKept() {
        let files = [
            file("/synthetic/a/IMG_0001.CR3"),
            file("/synthetic/a/IMG_0001.JPG"),
            file("/synthetic/a/IMG_0002.CR3"),
            file("/synthetic/b/IMG_0001.CR3"),
            file("/synthetic/a/IMG_0003.dng"),
            file("/synthetic/a/IMG_0003.heic"),
            file("/synthetic/a/IMG_0004.MOV")
        ]
        XCTAssertEqual(SupportedMediaFile.droppingRawCompanions(files).map(\.path), [
            "/synthetic/a/IMG_0001.JPG",
            "/synthetic/a/IMG_0002.CR3",
            "/synthetic/b/IMG_0001.CR3",
            "/synthetic/a/IMG_0003.heic",
            "/synthetic/a/IMG_0004.MOV"
        ])
    }

    func testDroppedFoldersAndFilesBecomeOneImportEach() {
        let jobs = DroppedImport.jobs([
            .init(url: file("/synthetic/trip/day1/IMG_1.jpg"), isDirectory: false),
            .init(url: folder("/synthetic/trip"), isDirectory: true),
            .init(url: folder("/synthetic/trip/day2"), isDirectory: true),
            .init(url: file("/synthetic/loose/a.heic"), isDirectory: false),
            .init(url: file("/synthetic/loose/notes.txt"), isDirectory: false),
            .init(url: file("/synthetic/other/b.webp"), isDirectory: false),
            .init(url: file("/synthetic/loose/c.NEF"), isDirectory: false),
            .init(url: file("/synthetic/loose/a.heic"), isDirectory: false),
            .init(url: folder("/synthetic/trip"), isDirectory: true)
        ])
        XCTAssertEqual(jobs, [
            .folder(folder("/synthetic/trip")),
            .files(in: folder("/synthetic/loose"), [file("/synthetic/loose/a.heic"), file("/synthetic/loose/c.NEF")]),
            .files(in: folder("/synthetic/other"), [file("/synthetic/other/b.webp")])
        ])
        XCTAssertEqual(DroppedImport.jobs([.init(url: file("/synthetic/notes.txt"), isDirectory: false)]), [])
    }

    func testAFolderIsMissingWhenItsBookmarkDoesNotLeadToAFolder() {
        XCTAssertEqual(FolderLocationCheck.classify(resolved: true, isStale: false, existsAsFolder: true), .found)
        XCTAssertEqual(FolderLocationCheck.classify(resolved: true, isStale: true, existsAsFolder: true), .foundWithStaleBookmark)
        XCTAssertEqual(FolderLocationCheck.classify(resolved: true, isStale: false, existsAsFolder: false), .missing)
        XCTAssertEqual(FolderLocationCheck.classify(resolved: false, isStale: false, existsAsFolder: false), .missing)
    }

    func testClosedMissingFoldersStayHiddenAndTheRestAreSortedByName() {
        let shown = FolderLocationCheck.toShow(
            missing: [(id: "s3", name: "Trip 10"), (id: "s1", name: "trip 2"), (id: "s2", name: "Archive")],
            dismissed: ["s2"]
        )
        XCTAssertEqual(shown.map(\.id), ["s1", "s3"])
    }

    private func file(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: false) }
    private func folder(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }
}
