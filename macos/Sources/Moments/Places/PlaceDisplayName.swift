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
        // Parent chains are spot → area → city.
        namingPlace(of: place).flatMap(ownName(of:))
    }

    /// The name this place has itself: this person's rename of it, else the
    /// name the import gave it, unless that is only a placeholder.
    static func ownName(of place: Place) -> String? {
        if let corrected = place.correctedName { return corrected }
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPlaceholder(name, placeID: place.id), !importFallbackNames.contains(name) else { return nil }
        return name
    }

    /// Written by the import, in the language it ran in, when a reverse
    /// lookup returned no area or city name.
    private static let importFallbackNames: Set<String> = [
        "Unknown area", "Unbekanntes Gebiet", "未知区域",
        "Unknown city", "Unbekannte Stadt", "未知城市",
        String(localized: "Unknown area"), String(localized: "Unknown city")
    ]

    /// The place that supplies `resolvedName`, so filters can match every
    /// unnamed spot under it.
    static func namingPlace(of place: Place) -> Place? {
        var current: Place? = place
        var depth = 0
        while let candidate = current, depth < 4 {
            if ownName(of: candidate) != nil {
                return candidate
            }
            current = candidate.parent
            depth += 1
        }
        return nil
    }

    /// True when `placeID` is `place` or one of its parents.
    static func place(_ place: Place?, isWithin placeID: String) -> Bool {
        var current = place
        var depth = 0
        while let candidate = current, depth < 4 {
            if candidate.id == placeID { return true }
            current = candidate.parent
            depth += 1
        }
        return false
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

extension MediaItem {
    /// This person's override, else a real name from the place or a parent;
    /// nil when the import only gave it an internal handle like "Spot 402a14".
    var namedPlace: String? {
        let override = placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return place.flatMap(PlaceDisplayName.resolvedName(of:))
    }
}
