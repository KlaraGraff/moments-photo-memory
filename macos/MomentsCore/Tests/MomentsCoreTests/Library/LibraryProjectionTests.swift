import XCTest
@testable import MomentsCore

final class LibraryProjectionTests: XCTestCase {
    func testProjectionBuildsStableDateGroupsAndMapStops() {
        let first = LibraryPhotoDescriptor(
            id: "b",
            captureDate: Date(timeIntervalSince1970: 2),
            dayKey: "2026-01-02",
            monthKey: "2026-01",
            latitude: 1,
            longitude: 2
        )
        let second = LibraryPhotoDescriptor(
            id: "a",
            captureDate: Date(timeIntervalSince1970: 1),
            dayKey: "2026-01-01",
            monthKey: "2026-01",
            latitude: nil,
            longitude: nil
        )

        let projection = LibraryProjection(photos: [first, second])

        XCTAssertEqual(projection.photos.map(\.id), ["a", "b"])
        XCTAssertEqual(projection.dayPhotoIDs["2026-01-01"], ["a"])
        XCTAssertEqual(projection.dayPhotoIDs["2026-01-02"], ["b"])
        XCTAssertEqual(projection.monthPhotoIDs["2026-01"], ["a", "b"])
        XCTAssertEqual(projection.mapStops.map(\.id), ["b"])
        XCTAssertEqual(projection.photoByID["b"]?.id, "b")
    }

    func testFilteringUsesTheSharedPhotoIndex() {
        let photos = [
            LibraryPhotoDescriptor(id: "keep", placeID: "home", placeName: "Home", kind: .photo, isFavorite: true, hasMemory: true, title: "Morning"),
            LibraryPhotoDescriptor(id: "drop-kind", placeID: "home", kind: .video),
            LibraryPhotoDescriptor(id: "drop-search", placeID: "away", placeName: "Away", title: "Evening")
        ]
        let projection = LibraryProjection(photos: photos)

        XCTAssertEqual(
            projection.matchingIDs(LibraryProjectionFilter(placeID: "home", favoritesOnly: true, memoriesOnly: true, searchText: "morning")),
            ["keep"]
        )
    }

    func testPlaceIndexFindsANameWithoutScanningTheWholePlaceList() {
        let places = [
            LibraryPlaceDescriptor(id: "near", name: "Near", latitude: 35.01, longitude: -5.01),
            LibraryPlaceDescriptor(id: "far", name: "Far", latitude: 45, longitude: 20)
        ]
        let index = LibraryPlaceIndex(places: places)

        XCTAssertEqual(index.nearestName(to: GeoPoint(latitude: 35, longitude: -5)), "Near")
        XCTAssertNil(index.nearestName(to: GeoPoint(latitude: 0, longitude: 0), within: 100_000))
    }

    func testTwentyThousandSyntheticPhotosBuildQuickly() {
        let photos = (0..<20_000).map { index in
            LibraryPhotoDescriptor(
                id: "photo-\(index)",
                captureDate: Date(timeIntervalSince1970: TimeInterval(index)),
                dayKey: "2026-\(index / 100)",
                monthKey: "2026-\(index / 1_000)",
                latitude: Double(index % 90),
                longitude: Double(index % 180)
            )
        }

        let start = Date()
        let projection = LibraryProjection(photos: photos)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(projection.photos.count, 20_000)
        XCTAssertEqual(projection.mapStops.count, 20_000)
        XCTAssertLessThan(elapsed, 1.0)
    }
}

extension LibraryProjectionTests {
    func testPhotoBatchIsDeterministicAndCarriesGeneration() {
        let projection = LibraryProjection(photos: (0..<5).map { LibraryPhotoDescriptor(id: "p\($0)", captureDate: Date(timeIntervalSince1970: TimeInterval($0))) })
        let result = projection.photoBatch(PageBatchRequest(generation: 7, offset: 2, limit: 2))
        XCTAssertEqual(result.generation, 7)
        XCTAssertEqual(result.offset, 2)
        XCTAssertEqual(result.values.map(\.id), ["p2", "p3"])
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.total, 5)
        XCTAssertEqual(projection.photoBatch(PageBatchRequest(offset: 99, limit: 4)).values, [])
    }

    func testMapBucketsRespectGridAndCap() {
        let photos = (0..<20).map { i in
            let coordinate = Double(i / 2)
            let captureDate = Date(timeIntervalSince1970: TimeInterval(i))
            return LibraryPhotoDescriptor(
                id: "p\(i)",
                captureDate: captureDate,
                latitude: coordinate,
                longitude: coordinate
            )
        }
        let projection = LibraryProjection(photos: photos)
        let all = projection.mapBuckets(gridDegrees: 1)
        XCTAssertEqual(all.reduce(0) { $0 + $1.photoCount }, 20)
        XCTAssertLessThanOrEqual(projection.mapBuckets(gridDegrees: 1, cap: 3).count, 3)
        XCTAssertEqual(all, projection.mapBuckets(gridDegrees: 1))
    }
}
