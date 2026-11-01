import CoreGraphics
import Foundation
import XCTest
@testable import Moments

/// The face scan and the burst analysis load thousands of photos. Every
/// `PhotoKitAssetSource` builds a `PHCachingImageManager`, so both paths must
/// reuse the one shared source instead of making a new one per photo.
final class PhotoKitAssetSourceSharedTests: XCTestCase {
    func testSharedSourceIsOneInstance() {
        let first: PhotoKitAssetSource = PhotoKitAssetSource.shared
        let second: PhotoKitAssetSource = PhotoKitAssetSource.shared
        XCTAssertTrue(first === second)
    }

    /// A media item with neither a Photos identifier nor a bookmark has no
    /// image behind it, so the loader gives up without reading anything.
    func testLoaderReturnsNilWithoutAPhotoOrABookmark() async {
        let descriptor = PeopleMediaDescriptor(
            id: "synthetic-no-source",
            bookmarkData: nil,
            photosLocalIdentifier: nil
        )
        let image: CGImage? = await PeopleImageLoader.load(descriptor, allowDownload: false)
        XCTAssertNil(image)
    }
}
