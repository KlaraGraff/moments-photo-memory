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
    /// Size of the map area; the overview camera is fitted to it.
    @State private var mapSize: CGSize = .zero
    /// The overview is refitted on resize; after the user flies to a country
    /// the camera stays where they put it.
    @State private var isShowingGlobeOverview = true
    /// MapKit reports a programmatic camera with its own distance value, so
    /// the first report after a move is the baseline for spotting user zooms.
    @State private var awaitingProgrammaticCamera = false
    @State private var programmaticDistance: Double?

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
            HStack(spacing: 0) {
                GeometryReader { proxy in
                    mapView
                        .onChange(of: proxy.size, initial: true) { _, size in
                            mapSize = size
                            refitGlobeOverview()
                        }
                }
                // Map ignores the safe area. Flush against the floating
                // sidebar it would extend under it and centre the globe on
                // the hidden part; a 1 pt gap keeps it inside its own frame.
                .padding(.leading, 1)
                .clipped()
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
            stat(title: "Cities", value: "\(screenState.statistics.cityCount)", systemImage: "building.2")
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
        // Stats sit on a band one tone down; spacing, not rules, separates them.
        .background(Paper.well.opacity(0.6))
    }

    private func stat(title: LocalizedStringKey, value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 10)
    }

    private var mapView: some View {
        Map(position: $cameraPosition) {
            ForEach(screenState.snapshot.overviewSegments) { segment in
                if let from = segment.from.center, let to = segment.to.center {
                    let coordinates = [from.coordinate, to.coordinate]
                    MapPolyline(MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count))
                        .stroke(Paper.accent.opacity(0.8), lineWidth: 2.5)
                }
            }

            ForEach(screenState.snapshot.cityClusters) { cluster in
                if let center = cluster.center {
                    Annotation(cluster.name ?? String(localized: "City"), coordinate: center.coordinate, anchor: .bottom) {
                        Button {
                            selection.showInLibrary(cluster.stopIDs, title: cityTitle(cluster))
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Paper.accent)
                                    .shadow(color: Paper.shadow.opacity(0.3), radius: 2)
                                Text("\(cluster.stopIDs.count)")
                                    .font(.caption2.monospacedDigit().bold())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Paper.raised, in: Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                        .help(String(format: String(localized: "Show photos from %@"), cityTitle(cluster)))
                        .accessibilityIdentifier("footprints.city.\(cluster.id)")
                    }
                }
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
        .onMapCameraChange(frequency: .onEnd) { context in
            if awaitingProgrammaticCamera {
                awaitingProgrammaticCamera = false
                programmaticDistance = context.camera.distance
                return
            }
            guard isShowingGlobeOverview, let programmaticDistance else { return }
            // Zooming by hand changes the distance; keep the user's camera.
            if abs(context.camera.distance - programmaticDistance) > programmaticDistance * 0.05 {
                isShowingGlobeOverview = false
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("footprints.globe")
        .accessibilityLabel("Footprints globe")
    }

    private var countryPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Visited countries")
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .foregroundStyle(Paper.ink)
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
                            .foregroundStyle(Paper.muted)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                    ForEach(screenState.countrySummaries) { country in
                        HStack(spacing: 0) {
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
                                            .foregroundStyle(Paper.ink)
                                        Text("\(country.photoCount) photos")
                                            .font(.caption)
                                            .foregroundStyle(Paper.muted)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.leading, 16)
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Show on the globe"))
                            Button {
                                selection.showInLibrary(itemIDs(of: country), title: country.name)
                            } label: {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.callout)
                                    .foregroundStyle(Paper.muted)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .padding(.trailing, 8)
                            .help(String(format: String(localized: "Show photos from %@"), country.name))
                            .accessibilityLabel(String(format: String(localized: "Show photos from %@"), country.name))
                            .accessibilityIdentifier("footprints.country.photos.\(country.id)")
                        }
                    }
                }
            }
        }
        .background(Paper.canvas)
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

    /// Name for a city pin: the cluster's own name, else its country.
    private func cityTitle(_ cluster: PlaceCluster) -> String {
        if let name = cluster.name, !name.isEmpty { return name }
        return screenState.geocoding[cluster.id]?.displayName ?? String(localized: "City")
    }

    private func itemIDs(of country: FootprintsCountrySummary) -> [String] {
        let clusterIDs = Set(country.clusterIDs)
        return screenState.snapshot.cityClusters
            .filter { clusterIDs.contains($0.id) }
            .flatMap(\.stopIDs)
    }

    private func focus(on itemID: String?) {
        guard let itemID,
              let cluster = screenState.snapshot.cityClusters.first(where: { $0.stopIDs.contains(itemID) }),
              let center = cluster.center else { return }
        moveCamera(to: center)
    }

    private func refitGlobeOverview() {
        guard isShowingGlobeOverview else { return }
        moveCamera(to: screenState.snapshot.cameraTarget, animated: false)
    }

    private func moveCamera(to target: FootprintsCameraTarget, animated: Bool = true) {
        isShowingGlobeOverview = target.isGlobeOverview
        let distance = target.isGlobeOverview
            ? FootprintsCameraTarget.globeDistance(fitting: mapSize)
            : target.distanceMetres
        awaitingProgrammaticCamera = true
        let position = MapCameraPosition.camera(
            MapCamera(
                centerCoordinate: target.coordinate,
                distance: distance
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
