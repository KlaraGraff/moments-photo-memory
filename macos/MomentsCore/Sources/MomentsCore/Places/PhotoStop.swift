import CoreLocation
import Foundation

/// The minimum information needed to build places and routes from a photo.
public struct PhotoStop: Equatable, Hashable, Sendable {
    public let id: String
    public let date: Date
    public let coordinate: GeoPoint?

    public init(id: String, date: Date, coordinate: GeoPoint? = nil) {
        self.id = id
        self.date = date
        self.coordinate = coordinate
    }
}
