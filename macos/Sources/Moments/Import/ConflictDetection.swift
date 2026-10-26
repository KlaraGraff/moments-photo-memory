import Foundation
import MomentsCore

/// Applies the versioned conflict rules to imported metadata. Every result is
/// a candidate for review; it is never treated as proof that a photo is wrong.
public struct ImportConflictDetector: Sendable {
    public let configuration: ImportConflictConfiguration

    public init(configuration: ImportConflictConfiguration = .current) {
        self.configuration = configuration
    }

    public func detect(_ metadata: [ImportedMediaMetadata]) -> [ImportConflictEvent] {
        let ordered = metadata.sorted {
            $0.captureDate == $1.captureDate ? $0.id < $1.id : $0.captureDate < $1.captureDate
        }
        guard ordered.count > 1 else { return [] }

        var events: [ImportConflictEvent] = []
        for index in 1..<ordered.count {
            let previous = ordered[index - 1]
            let current = ordered[index]
            let gap = current.captureDate.timeIntervalSince(previous.captureDate)
            guard gap >= 0 else { continue }
            if gap > configuration.noPhotosGap {
                events.append(ImportConflictEvent(
                    kind: .noPhotosGap,
                    itemIDs: [previous.id, current.id],
                    timeGap: gap,
                    detail: String(localized: "There is a gap of more than two hours with no photos.")
                ))
                continue
            }
            guard let from = coordinate(for: previous), let to = coordinate(for: current) else { continue }
            let distance = from.distance(to: to)
            let speedMetersPerSecond = gap > 0 ? distance / gap : .infinity
            let speedKmh = speedMetersPerSecond * 3.6

            if distance >= configuration.transportMinimumDistanceMeters,
               gap > 0,
               speedKmh <= configuration.transportMaximumSpeedKmh {
                events.append(ImportConflictEvent(
                    kind: .transport,
                    itemIDs: [previous.id, current.id],
                    distanceMeters: distance,
                    timeGap: gap,
                    detail: String(localized: "The distance and time are consistent with transport.")
                ))
                continue
            }
            if gap <= configuration.consecutiveMaximumTimeGap,
               distance > configuration.consecutiveDistanceMeters {
                events.append(ImportConflictEvent(
                    kind: .shortFastJump,
                    itemIDs: [previous.id, current.id],
                    distanceMeters: distance,
                    timeGap: gap,
                    detail: String(localized: "Neighbouring photos contain a candidate location jump.")
                ))
            }
            if distance > configuration.highSpeedDistanceMeters,
               speedMetersPerSecond > configuration.highSpeedMetersPerSecond {
                events.append(ImportConflictEvent(
                    kind: .highSpeedJump,
                    itemIDs: [previous.id, current.id],
                    distanceMeters: distance,
                    timeGap: gap,
                    detail: String(localized: "The implied speed is unusually high for a photo sequence.")
                ))
            }
            if gap <= 1, distance > configuration.sameSecondDistanceMeters {
                events.append(ImportConflictEvent(
                    kind: .sameSecondFarApart,
                    itemIDs: [previous.id, current.id],
                    distanceMeters: distance,
                    timeGap: gap,
                    detail: String(localized: "Photos with the same second have far-apart coordinates.")
                ))
            }
        }

        if ordered.count >= 3 {
            for index in 1..<(ordered.count - 1) {
                let first = ordered[index - 1]
                let middle = ordered[index]
                let last = ordered[index + 1]
                guard let firstPoint = coordinate(for: first),
                      let middlePoint = coordinate(for: middle),
                      let lastPoint = coordinate(for: last) else { continue }
                let firstLeg = firstPoint.distance(to: middlePoint)
                let secondLeg = middlePoint.distance(to: lastPoint)
                let returnLeg = firstPoint.distance(to: lastPoint)
                let totalGap = last.captureDate.timeIntervalSince(first.captureDate)
                if totalGap <= configuration.abaMaximumTimeGap,
                   firstLeg > configuration.abaLegDistanceMeters,
                   secondLeg > configuration.abaLegDistanceMeters,
                   returnLeg <= configuration.abaReturnDistanceMeters {
                    events.append(ImportConflictEvent(
                        kind: .abaLoop,
                        itemIDs: [first.id, middle.id, last.id],
                        distanceMeters: max(firstLeg, secondLeg),
                        timeGap: totalGap,
                        detail: String(localized: "The sequence leaves a place and returns near its starting point.")
                    ))
                }
            }
        }
        return events
    }

    private func coordinate(for item: ImportedMediaMetadata) -> GeoPoint? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}
