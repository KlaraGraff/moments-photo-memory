import Foundation

/// Carries the owner's settings and library over from the placeholder bundle
/// identifiers that builds used before the release identifier was chosen.
///
/// macOS keeps user defaults per bundle identifier, so the first launch under
/// the release identifier would otherwise start without trip covers, manual
/// trip assignments, People decisions, filters or the language choice. The
/// owner's library also lives in the folder the preview build used.
///
/// Nothing here deletes or moves anything: preferences are copied, and the
/// store is opened where it already is.
enum AppIdentityMigration {
    /// The preview build the owner used day to day, then the plain
    /// development build. The first domain that holds settings wins.
    static let legacyDomains = [
        "org.example.Moments.peoplepreview",
        "org.example.Moments"
    ]

    /// Set once the import has run (to the domain copied from, or "" when no
    /// earlier build left settings), so it never runs twice.
    static let importedFromKey = "MomentsAppIdentity.importedPreferencesFrom"
    /// The store folder chosen on the first launch under this identifier.
    static let storeFolderKey = "MomentsAppIdentity.storeFolderName"

    static let storeFolderName = "Moments"
    static let previewStoreFolderName = "Moments People Preview"

    /// Builds that still carry a placeholder identifier (CI, tests, older
    /// local builds) keep their old behaviour.
    static func isPlaceholder(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return bundleIdentifier.hasPrefix("org.example.")
    }

    /// Runs once per Mac, before anything reads user defaults.
    @MainActor
    static func runAtLaunch() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-MomentsUITesting")
            || arguments.contains("-MomentsUITestStoreDirectory")
            || UnitTestHostDelegate.isUnitTestHost {
            return
        }
        #endif
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        importLegacyPreferences(
            into: .standard,
            ownDomain: bundleIdentifier,
            readDomain: { UserDefaults.standard.persistentDomain(forName: $0) }
        )
    }

    /// Copies every key of the first legacy domain that has any into
    /// `defaults`, never overwriting a key this build already wrote.
    /// Returns the domain copied from, or nil when nothing ran.
    @discardableResult
    static func importLegacyPreferences(
        into defaults: UserDefaults,
        ownDomain: String,
        readDomain: (String) -> [String: Any]?
    ) -> String? {
        guard !isPlaceholder(ownDomain) else { return nil }
        let own = defaults.persistentDomain(forName: ownDomain) ?? [:]
        guard own[importedFromKey] == nil else { return nil }

        var source = ""
        for domain in legacyDomains where domain != ownDomain {
            guard let values = readDomain(domain), !values.isEmpty else { continue }
            for (key, value) in values where own[key] == nil {
                defaults.set(value, forKey: key)
            }
            source = domain
            break
        }
        defaults.set(source, forKey: importedFromKey)
        return source
    }

    /// The folder under Application Support that holds `Moments.store`.
    ///
    /// - The preview build keeps its own folder.
    /// - Placeholder builds use `Moments`.
    /// - The release build decides once: it adopts the preview build's
    ///   library when one exists (that is the owner's real library), and
    ///   otherwise uses `Moments`. The choice is remembered so that a
    ///   library made later in the other folder never takes over.
    static func storeFolderName(
        bundleIdentifier: String?,
        defaults: UserDefaults,
        storeExists: (String) -> Bool
    ) -> String {
        if bundleIdentifier?.hasSuffix(".peoplepreview") == true {
            return previewStoreFolderName
        }
        if isPlaceholder(bundleIdentifier) {
            return storeFolderName
        }
        if let recorded = defaults.string(forKey: storeFolderKey),
           recorded == storeFolderName || recorded == previewStoreFolderName {
            return recorded
        }
        let chosen = storeExists(previewStoreFolderName) ? previewStoreFolderName : storeFolderName
        defaults.set(chosen, forKey: storeFolderKey)
        return chosen
    }
}
