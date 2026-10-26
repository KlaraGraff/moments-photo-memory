import Foundation

/// The name a person sees for a place. Import names spots it could not look up
/// "Spot <last 6 characters of the id>"; that label is an internal handle, so
/// screens show the nearest named parent (area, then city) instead.
enum PlaceDisplayName {
    /// True for an empty name or the import's generated "Spot 402a14" label,
    /// in whichever language the import ran.
    static func isPlaceholder(_ name: String, placeID: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let suffix = placeID.suffix(6)
        guard !suffix.isEmpty, trimmed.hasSuffix(" " + suffix) else { return false }
        // Exactly one word before the id suffix: "Spot", "Ort", "地点".
        let prefix = trimmed.dropLast(suffix.count + 1)
        return !prefix.isEmpty && !prefix.contains(" ")
    }

    /// The place's own name, else its closest parent with a real name, else nil.
    static func resolvedName(of place: Place) -> String? {
        var current: Place? = place
        var depth = 0
        // Depth guard: parent chains are spot → area → city.
        while let candidate = current, depth < 4 {
            if !isPlaceholder(candidate.name, placeID: candidate.id),
               !isUnknownArea(candidate.name) {
                return candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            current = candidate.parent
            depth += 1
        }
        return nil
    }

    /// The import writes this when a reverse lookup returned no area name.
    private static func isUnknownArea(_ name: String) -> Bool {
        name == String(localized: "Unknown area") || name == "Unknown area"
    }
}

extension Place {
    /// Never an internal id; falls back to a localized "Unknown place".
    var displayName: String {
        PlaceDisplayName.resolvedName(of: self) ?? String(localized: "Unknown place")
    }
}

extension MediaItem {
    /// This person's place override, else the place's display name.
    var displayPlaceName: String? {
        let override = placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return place?.displayName
    }
}
