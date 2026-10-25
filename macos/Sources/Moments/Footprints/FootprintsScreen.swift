import MapKit
import MomentsCore
import Observation
import SwiftData
import SwiftUI

struct FootprintsScreen: View {
    @Query private var items: [MediaItem]
    @Environment(SelectionModel.self) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var screenState = FootprintsScreenState()
    @State private var cameraPosition = MapCameraPosition.camera(
        MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            distance: FootprintsCameraTarget.globeDistanceMetres
        )
    )
    @State private var cameraInputSignature: String?

    /// Created once per screen; a stored `let` would re-read the cache file
    /// from disk every time SwiftUI re-creates this view value.
    @State private var geocodeResolver: FootprintsGeocodeResolver?

    private var input: FootprintsInput {
        FootprintsCalculator.input(from: items, visibleItemIDs: selection.visibleItemIDs)
    }

    var body: some View {
        let currentInput = input
        VStack(spacing: 0) {
            statsHeader
            Divider()
            HStack(spacing: 0) {
                mapView
                Divider()
                countryPanel
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
            }
        }
        .navigationTitle("Footprints")
        .task(id: currentInput.signature) {
            await refresh(for: currentInput)
        }
        .onChange(of: selection.focusedItemID) { _, focusedID in
            focus(on: focusedID)
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 0) {
            stat(title: "Countries", value: "\(screenState.statistics.countryCount)", systemImage: "flag")
            Divider().frame(height: 30)
            stat(title: "Cities", value: "\(screenState.statistics.cityCount)", systemImage: "building.2")
            Divider().frame(height: 30)
            stat(title: "Kilometres", value: screenState.statistics.formattedKilometres, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            Spacer()
            if screenState.isGeocoding {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 12)
                    .accessibilityLabel(Text("Looking up countries"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func stat(title: LocalizedStringKey, value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
    }

    private var mapView: some View {
        Map(position: $cameraPosition) {
            ForEach(screenState.snapshot.overviewSegments) { segment in
                if let from = segment.from.center, let to = segment.to.center {
                    let coordinates = [from.coordinate, to.coordinate]
                    MapPolyline(MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count))
                        .stroke(.orange, lineWidth: 2.5)
                }
            }

            ForEach(screenState.snapshot.cityClusters) { cluster in
                if let center = cluster.center {
                    Annotation(cluster.name ?? String(localized: "City"), coordinate: center.coordinate, anchor: .bottom) {
                        Button {
                            selection.select(cluster.stopIDs, focus: cluster.stopIDs.first)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.red)
                                    .shadow(radius: 2)
                                Text("\(cluster.stopIDs.count)")
                                    .font(.caption2.monospacedDigit().bold())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.regularMaterial, in: Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                        .help(cluster.name ?? String(localized: "City"))
                    }
                }
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var countryPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Visited countries")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                if screenState.snapshot.cityClusters.isEmpty {
                    ContentUnavailableView(
                        "No geotagged memories",
                        systemImage: "location.slash",
                        description: Text("Add photos with locations to see your footprint.")
                    )
                    .padding(.horizontal, 8)
                } else {
                    if screenState.didEncounterGeocodingError {
                        Label("Offline: cached countries only", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                    ForEach(screenState.countrySummaries) { country in
                        Button {
                            guard let center = country.firstCenter else { return }
                            moveCamera(to: center)
                        } label: {
                            HStack(spacing: 10) {
                                Text(country.flag)
                                    .font(.title3)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(country.name)
                                        .foregroundStyle(.primary)
                                    Text("\(country.photoCount) \(String(localized: "photos"))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "location.north.line")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 54)
                    }
                }
            }
        }
        .background(.background)
    }

    @MainActor
    private func refresh(for input: FootprintsInput) async {
        let snapshot = FootprintsCalculator.snapshot(for: input)
        screenState = FootprintsScreenState(
            snapshot: snapshot,
            geocoding: [:],
            isGeocoding: !snapshot.cityClusters.isEmpty,
            didEncounterGeocodingError: false
        )
        if cameraInputSignature != input.signature {
            cameraInputSignature = input.signature
            moveCamera(to: snapshot.cameraTarget, animated: false)
        }
        guard !snapshot.cityClusters.isEmpty else { return }

        let resolver = geocodeResolver ?? FootprintsGeocodeResolver()
        geocodeResolver = resolver
        let batch = await resolver.resolve(clusters: snapshot.cityClusters)
        guard !Task.isCancelled else { return }
        screenState.geocoding = batch.results
        screenState.isGeocoding = false
        screenState.didEncounterGeocodingError = batch.didEncounterError
    }

    private func focus(on itemID: String?) {
        guard let itemID,
              let cluster = screenState.snapshot.cityClusters.first(where: { $0.stopIDs.contains(itemID) }),
              let center = cluster.center else { return }
        moveCamera(to: center)
    }

    private func moveCamera(to target: FootprintsCameraTarget, animated: Bool = true) {
        let position = MapCameraPosition.camera(
            MapCamera(
                centerCoordinate: target.coordinate,
                distance: target.distanceMetres
            )
        )
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.35)) {
                cameraPosition = position
            }
        } else {
            cameraPosition = position
        }
    }

    private func moveCamera(to center: GeoPoint) {
        moveCamera(
            to: FootprintsCameraTarget(center: center, distanceMetres: 2_000_000)
        )
    }
}

private struct FootprintsScreenState {
    var snapshot = FootprintsSnapshot.empty
    var geocoding: [String: FootprintsGeocodeResult] = [:]
    var isGeocoding = false
    var didEncounterGeocodingError = false

    var statistics: FootprintsStatistics {
        FootprintsCalculator.statistics(for: snapshot, geocoding: geocoding)
    }

    var countrySummaries: [FootprintsCountrySummary] {
        FootprintsCountrySummary.build(clusters: snapshot.cityClusters, geocoding: geocoding)
    }
}
