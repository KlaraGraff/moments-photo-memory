import CoreGraphics
import Foundation
import SwiftData

/// The edits the viewer's info column makes to one photo: its time, its
/// place name, its trip, and who is in it. Each keeps the original so it can
/// go back.
@MainActor
enum PhotoInfoEditing {
    /// Sets the time the photo was taken. The camera's time stays in
    /// `captureDate`, so `revertCaptureDate` can return to it.
    static func setCaptureDate(_ date: Date, on item: MediaItem, now: Date = .now) {
        if item.captureDate.map({ abs($0.timeIntervalSince(date)) < 1 }) == true {
            revertCaptureDate(on: item, now: now)
            return
        }
        item.userCorrectedCaptureDateUTC = date
        item.timeConfidenceRaw = ImportTimeConfidence.userCorrected.rawValue
        touch(item, now: now)
    }

    static func revertCaptureDate(on item: MediaItem, now: Date = .now) {
        guard item.userCorrectedCaptureDateUTC != nil else { return }
        item.userCorrectedCaptureDateUTC = nil
        if item.timeConfidenceRaw == ImportTimeConfidence.userCorrected.rawValue {
            item.timeConfidenceRaw = nil
        }
        touch(item, now: now)
    }

    /// Names the photo's place for this person. An empty name, or the name the
    /// place already has, removes the correction.
    static func setPlaceName(_ name: String, on item: MediaItem, context: ModelContext, now: Date = .now) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = item.place.flatMap(PlaceDisplayName.resolvedName(of:))
        let current = item.localPlaceOverride
        if value.isEmpty || value == original {
            guard let current, current.nameOverride != nil else { return }
            // A corrected map link or position stays; only the name goes.
            if current.mapLinkOverride == nil, current.latitude == nil, current.longitude == nil {
                context.delete(current)
            } else {
                current.nameOverride = nil
                current.updatedAt = now
                current.updatedBy = MomentsAccount.localID
            }
            touch(item, now: now)
            return
        }
        guard value != current?.nameOverride else { return }
        if let current {
            current.nameOverride = value
            current.updatedAt = now
            current.updatedBy = MomentsAccount.localID
        } else {
            context.insert(PlaceOverride(mediaID: item.id, nameOverride: value, updatedAt: now, updatedBy: MomentsAccount.localID, mediaItem: item))
        }
        touch(item, now: now)
    }

    /// Moves the photo into another trip, or out of every trip.
    static func setTrip(_ trip: Trip?, on item: MediaItem, now: Date = .now) {
        guard item.trip?.id != trip?.id || item.tripID != trip?.id else { return }
        item.trip = trip
        item.tripID = trip?.id
        touch(item, now: now)
    }

    /// Starts a trip with this photo in it, spanning the photo's day.
    @discardableResult
    static func moveToNewTrip(named name: String, item: MediaItem, context: ModelContext, now: Date = .now) -> Trip? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let date = item.effectiveCaptureDate
        let trip = Trip(name: value, startDate: date, endDate: date, updatedAt: now, updatedBy: MomentsAccount.localID)
        context.insert(trip)
        setTrip(trip, on: item, now: now)
        return trip
    }

    /// Renames a trip; an empty name goes back to the name it was given.
    static func renameTrip(_ trip: Trip, to name: String, now: Date = .now) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let override: String? = value.isEmpty || value == trip.name ? nil : value
        guard trip.overrideName != override else { return }
        trip.overrideName = override
        trip.updatedAt = now
        trip.updatedBy = MomentsAccount.localID
    }

    private static func touch(_ item: MediaItem, now: Date) {
        item.updatedAt = now
        item.updatedBy = MomentsAccount.localID
    }
}

/// Zoom and pan for the viewer's photo, kept apart from the view so the
/// arithmetic can be tested. `offset` moves the photo's centre away from the
/// centre of the area that shows it.
struct ViewerZoom: Equatable {
    static let maximum: CGFloat = 5

    var scale: CGFloat = 1
    var offset: CGSize = .zero

    var isZoomed: Bool { scale > 1.001 }

    /// Zooms to `newScale` keeping the point under `anchor` (in the area's own
    /// coordinates) where it is, as a pinch or ⌘-scroll does.
    mutating func zoom(to newScale: CGFloat, anchor: CGPoint, fitted: CGSize, area: CGSize) {
        let clamped = min(max(newScale, 1), Self.maximum)
        let center = CGPoint(x: area.width / 2, y: area.height / 2)
        let pointX = anchor.x - center.x
        let pointY = anchor.y - center.y
        let ratio = clamped / scale
        offset = CGSize(
            width: pointX - (pointX - offset.width) * ratio,
            height: pointY - (pointY - offset.height) * ratio
        )
        scale = clamped
        clampOffset(fitted: fitted, area: area)
    }

    mutating func pan(by delta: CGSize, fitted: CGSize, area: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
        clampOffset(fitted: fitted, area: area)
    }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    /// Keeps the photo's edges from coming inside the area: a photo smaller
    /// than the area in one direction stays centred in that direction.
    mutating func clampOffset(fitted: CGSize, area: CGSize) {
        let limitX = max(0, (fitted.width * scale - area.width) / 2)
        let limitY = max(0, (fitted.height * scale - area.height) / 2)
        offset.width = min(max(offset.width, -limitX), limitX)
        offset.height = min(max(offset.height, -limitY), limitY)
    }
}

enum SwipeAxis {
    case undecided, horizontal, vertical
}

/// Where a sideways swipe over the viewer's photo ends up.
enum ViewerSwipe {
    /// 1 for the next photo, -1 for the previous one, 0 to spring back.
    /// `offset` is how far the photo slid (negative: towards the next one);
    /// `lastStep` is the fingers' last movement, so a quick flick turns the
    /// page even when it travelled only a little.
    static func direction(offset: CGFloat, width: CGFloat, lastStep: CGFloat, hasPrevious: Bool, hasNext: Bool) -> Int {
        let threshold = max(width * 0.18, 40)
        let flick = abs(lastStep) > 6
        if hasNext, offset < 0, offset < -threshold || (flick && lastStep < 0) { return 1 }
        if hasPrevious, offset > 0, offset > threshold || (flick && lastStep > 0) { return -1 }
        return 0
    }
}
