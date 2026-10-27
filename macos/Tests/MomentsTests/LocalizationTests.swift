import Foundation
import XCTest
@testable import Moments

final class LocalizationTests: XCTestCase {
    /// The built app carries German and Chinese, not only the catalog.
    func testAppBundleShipsGermanAndChinese() throws {
        let bundle = Bundle(for: MediaItem.self)
        for language in ["en", "de", "zh-Hans"] {
            XCTAssertTrue(bundle.localizations.contains(language), "\(language) missing from \(bundle.localizations)")
        }
        let expected = ["de": "Einstellungen", "zh-Hans": "设置"]
        for (language, value) in expected {
            let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"))
            let localized = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(localized.localizedString(forKey: "Settings", value: nil, table: nil), value)
        }
    }

    func testLanguageChoiceIsStoredForThisAppOnly() throws {
        let suite = "MomentsTests.AppLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .system)
        AppLanguage.choose(.german, in: defaults)
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .german)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?[AppLanguage.defaultsKey] as? [String], ["de"])
        AppLanguage.choose(.chineseSimplified, in: defaults)
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .chineseSimplified)
        AppLanguage.choose(.system, in: defaults)
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .system)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[AppLanguage.defaultsKey])

        // A regional variant written by System Settings still counts.
        defaults.set(["zh-Hans-CN"], forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .chineseSimplified)
        defaults.set(["de-DE"], forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .german)
        defaults.set(["fr"], forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .system)
    }
}
