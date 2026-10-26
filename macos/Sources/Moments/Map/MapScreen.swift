import CoreLocation
import Combine
import Foundation
import MapKit
import Network
import SwiftData
import SwiftUI
import MomentsCore

/// One map for every photo with a location. Zoomed out to the whole world it
/// is a globe with the visited countries; zoomed in it shows places and the
/// routes between them. Pins are the photos themselves, like Apple Photos.
struct MapScreen: View {
    @Query(sort: \MediaItem.captureDate) private var items: [MediaItem]
    @Query private var places: [Place]
    @Environment(SelectionModel.self) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cameraPosition = MapCameraPosition.camera(
        MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            distance: FootprintsCameraTarget.globeDistanceMetres
        )
    )
    @State private var latitudeDelta = 90.0
    @State private var cameraDistance = FootprintsCameraTarget.globeDistanceMetres
    @State private var mapStyle: MapScreenStyle = .satellite
    @State private var selectedClusterID: String?
    /// A pin click also reaches the map's background tap; ignore that echo
    /// so the photo strip does not close right after it opens.
    @State private var lastMarkerSelection = Date.distantPast
    @StateObject private var networkMonitor = MapNetworkMonitor()

    /// Size of the map area; the globe overview is fitted to it.
    @State private var mapSize: CGSize = .zero
    /// The globe is refitted on resize until the person moves the camera.
    @State private var isShowingGlobeOverview = true
    /// MapKit reports a programmatic camera with its own distance value, so
    /// the first report after a move is the baseline for spotting user zooms.
    @State private var awaitingProgrammaticCamera = false
    @State private var programmaticDistance: Double?
    @State private var showingCountries = false

    /// Clustering and routes are rebuilt only when items, the Library filter
    /// or the zoom level change, not on every render or selection change.
    @State private var cachedSnapshot: PlacesViewModel.Snapshot?
    @State private var itemsByID: [String: MediaItem] = [:]
    @State private var world = MapWorldState()
    /// Created once per screen; it reads its cache file from disk.
    @State private var geocodeResolver: FootprintsGeocodeResolver?

    private let viewModel = PlacesViewModel()

    /// Above this camera altitude the map is a globe: city pins, countries and
    /// the whole trip's route. Below it, places and local routes.
    static let worldDistanceMetres = 3_000_000.0

    private var isWorldView: Bool { cameraDistance >= Self.worldDistanceMetres }

    private var snapshot: PlacesViewModel.Snapshot {
        cachedSnapshot ?? PlacesViewModel.Snapshot(level: .city, stops: [], clusters: [], routeSegments: [], coordinateByID: [:])
    }

    private var snapshotKey: Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.captureDate)
            hasher.combine(item.latitude)
            hasher.combine(item.longitude)
        }
        hasher.combine(selection.visibleItemIDs)
        hasher.combine(viewModel.level(for: latitudeDelta))
        return hasher.finalize()
    }

    private var worldInput: FootprintsInput {
        FootprintsCalculator.input(from: items, visibleItemIDs: selection.visibleItemIDs)
    }

    private var selectedCluster: PlaceCluster? {
        guard !isWorldView else { return nil }
        if let selectedClusterID {
            return snapshot.clusters.first { $0.id == selectedClusterID }
        }
        return viewModel.selectedCluster(
            in: snapshot,
            selectedItemIDs: selection.selectedItemIDs,
            focusedItemID: selection.focusedItemID
        )
    }

    private var selectedItems: [MediaItem] {
        guard let selectedCluster else { return [] }
        return selectedCluster.stopIDs
            .compactMap { itemsByID[$0] }
            .filter { selection.isVisible($0.id) }
            .sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
    }

    var body: some View {
        let currentWorldInput = worldInput
        VStack(spacing: 0) {
            // The same filters as the Library, kept in step with it: pick a
            // person to see only the places you were with them.
            LibraryFilterChips()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Paper.well.opacity(0.45))
                .accessibilityIdentifier("map.filters")
            mapArea
        }
        .background { LibraryFilterPublisher() }
        .navigationTitle("Map")
        .task(id: snapshotKey) {
            itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            cachedSnapshot = viewModel.snapshot(
                items: items,
                visibleItemIDs: selection.visibleItemIDs,
                latitudeDelta: latitudeDelta
            )
        }
        .task(id: currentWorldInput.signature) {
            await refreshWorld(for: currentWorldInput)
        }
        .onChange(of: selection.focusedItemID) { _, focusedItemID in
            focus(on: focusedItemID)
        }
        .onChange(of: selection.selectedItemIDs) { _, selectedItemIDs in
            guard let selectedClusterID,
                  let cluster = snapshot.clusters.first(where: { $0.id == selectedClusterID }) else { return }
            if selectedItemIDs.isDisjoint(with: cluster.stopIDs) {
                self.selectedClusterID = nil
            }
        }
        .onChange(of: selection.visibleItemIDs) { _, _ in
            selectedClusterID = nil
        }
        .onChange(of: latitudeDelta) { _, _ in
            if let selectedClusterID,
               !snapshot.clusters.contains(where: { $0.id == selectedClusterID }) {
                self.selectedClusterID = nil
            }
        }
    }

    private var mapArea: some View {
        ZStack(alignment: .top) {
            GeometryReader { proxy in
                mapView
                    .onChange(of: proxy.size, initial: true) { _, size in
                        mapSize = size
                        refitGlobeOverview()
                    }
            }
            // Map ignores the safe area. Flush against the floating sidebar or
            // the title bar it would extend under them and centre the globe on
            // the hidden part; a 1 pt gap keeps it inside its own frame.
            .padding(.leading, 1)
            .padding(.top, 1)
            .clipped()
            .overlay(alignment: .topLeading) {
                if isWorldView, !world.snapshot.cityClusters.isEmpty { worldSummary }
            }
            .overlay(alignment: .topTrailing) { mapToolbar }
            .overlay(alignment: .bottom) { bottomStrip }

            if snapshot.isEmpty, cachedSnapshot != nil {
                emptyState
            }

            if networkMonitor.isOffline {
                mapStatus(text: "Map tiles unavailable", systemImage: "wifi.exclamationmark")
                    .padding(.top, 12)
            }
        }
    }

    // MARK: Map

    private var mapView: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom, .rotate, .pitch]) {
            ForEach(snapshot.routeSegments) { segment in
                if let from = segment.from.center, let to = segment.to.center {
                    let coordinates = [from.coordinate, to.coordinate]
                    MapPolyline(MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count))
                        .stroke(Paper.accent.opacity(0.8), lineWidth: isWorldView ? 2.5 : 3)
                        .mapOverlayLevel(level: .aboveRoads)

                    if !isWorldView {
                        Annotation(coordinate: midpoint(from, to), anchor: .center) {
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.caption2)
                                .foregroundStyle(Paper.accent)
                                .rotationEffect(.radians(routeBearing(from, to)))
                                .accessibilityHidden(true)
                        } label: {
                            EmptyView()
                        }
                    }
                }
            }

            ForEach(snapshot.clusters) { cluster in
                if let center = cluster.center {
                    Annotation(coordinate: center.coordinate, anchor: .bottom) {
                        photoPin(cluster)
                    } label: {
                        Text(clusterDisplayName(cluster))
                    }
                }
            }
        }
        .mapStyle(mapStyle.value)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("map.view")
        .accessibilityLabel(Text("Map"))
        .onMapCameraChange(frequency: .onEnd) { context in
            latitudeDelta = context.region.span.latitudeDelta
            cameraDistance = context.camera.distance
            // Down among the places the camera is the person's, whatever
            // brought it there: a resize must never pull it back to the globe.
            if context.camera.distance < Self.worldDistanceMetres {
                isShowingGlobeOverview = false
                awaitingProgrammaticCamera = false
                return
            }
            if awaitingProgrammaticCamera {
                awaitingProgrammaticCamera = false
                programmaticDistance = context.camera.distance
                return
            }
            guard isShowingGlobeOverview, let programmaticDistance else { return }
            // Zooming by hand changes the distance; keep the person's camera.
            if abs(context.camera.distance - programmaticDistance) > programmaticDistance * 0.05 {
                isShowingGlobeOverview = false
            }
        }
        .onTapGesture {
            guard Date().timeIntervalSince(lastMarkerSelection) > 0.4 else { return }
            closePanel()
        }
    }

    /// A photo standing on the map: the place's first photo in a white frame,
    /// with the number of photos there when there is more than one.
    private func photoPin(_ cluster: PlaceCluster) -> some View {
        let isSelected = selectedCluster?.id == cluster.id
        let side: CGFloat = isWorldView ? 34 : 46
        let cover = cluster.stopIDs.lazy.compactMap { itemsByID[$0] }.first
        return Button {
            pinClicked(cluster)
        } label: {
            VStack(spacing: 0) {
                Group {
                    if let cover {
                        ThumbnailView(item: cover, width: Int(side * 2), height: Int(side * 2))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Paper.well)
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(2.5)
                .background(isSelected ? Paper.accent : Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if cluster.stopIDs.count > 1 {
                        Text(cluster.stopIDs.count, format: .number)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Paper.accent, in: Capsule())
                            .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                            .offset(x: 7, y: -7)
                    }
                }
                MapPinPointer()
                    .fill(isSelected ? Paper.accent : Color.white)
                    .frame(width: 12, height: 6)
            }
            .compositingGroup()
            .shadow(color: Paper.shadow.opacity(0.28), radius: 4, y: 2)
            .scaleEffect(isSelected ? 1.08 : 1)
            .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: isSelected)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(clusterDisplayName(cluster))
        .accessibilityLabel(clusterDisplayName(cluster))
        .accessibilityValue(Text("\(cluster.stopIDs.count) photos"))
        .accessibilityIdentifier("map.marker.\(cluster.stopIDs.first ?? cluster.id)")
    }

    // MARK: Overlays

    private var mapToolbar: some View {
        HStack(spacing: 8) {
            Picker("Map style", selection: $mapStyle) {
                ForEach(MapScreenStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            // One way in and one way out, named in words: on the globe it
            // zooms to where the photos are; closer in it goes back out.
            if isWorldView {
                if photosFitBelowWorld {
                    Button("Zoom to photos", systemImage: "photo.on.rectangle") {
                        fitAll()
                    }
                    .help("Zoom in to the places your photos were taken")
                    .accessibilityIdentifier("map.fit")
                }
            } else {
                Button("Whole world", systemImage: "globe.europe.africa") {
                    showGlobe()
                }
                .help("Back out to the globe with every country you visited")
                .accessibilityIdentifier("map.globe")
            }
        }
        .padding(8)
        .paperFloatingPanel(cornerRadius: 10)
        .padding(14)
    }

    /// Countries, cities and distance, in a corner the globe never reaches.
    /// The country list opens from it instead of taking room beside the globe.
    private var worldSummary: some View {
        let statistics = world.statistics
        return Button {
            showingCountries.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                worldStat(value: "\(statistics.countryCount)", title: "Countries")
                worldStat(value: "\(statistics.cityCount)", title: "Cities")
                worldStat(value: statistics.formattedKilometres, title: "Kilometres")
                if world.isGeocoding {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Looking up countries"))
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Paper.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .paperFloatingPanel(cornerRadius: 10)
        .padding(14)
        .help("Visited countries")
        .accessibilityIdentifier("map.stats")
        .popover(isPresented: $showingCountries, arrowEdge: .bottom) {
            countryList
        }
    }

    private func worldStat(value: String, title: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(Paper.ink)
            Text(title)
                .font(.caption)
                .foregroundStyle(Paper.muted)
        }
    }

    private var countryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Visited countries")
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .foregroundStyle(Paper.ink)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                if world.didEncounterGeocodingError {
                    Label("Offline: cached countries only", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                ForEach(world.countrySummaries) { country in
                    HStack(spacing: 0) {
                        Button {
                            showingCountries = false
                            guard let center = country.firstCenter else { return }
                            flyTo(center, latitudeDelta: 8)
                        } label: {
                            HStack(spacing: 10) {
                                Text(country.flag)
                                    .font(.title3)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(country.name)
                                        .foregroundStyle(Paper.ink)
                                    Text("\(country.photoCount) \(String(localized: "photos"))")
                                        .font(.caption)
                                        .foregroundStyle(Paper.muted)
                                }
                                Spacer(minLength: 8)
                            }
                            .padding(.leading, 16)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show on the map")
                        .accessibilityIdentifier("map.country.\(country.id)")
                        Button {
                            showingCountries = false
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
                        .accessibilityIdentifier("map.country.photos.\(country.id)")
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .frame(width: 280)
        .frame(maxHeight: 360)
        .background(Paper.raised)
    }

    /// Height of the photo row; a horizontal ScrollView otherwise takes all
    /// the vertical space it is offered and the strip covers the map.
    private static let photoRowHeight: CGFloat = 112

    @ViewBuilder
    private var bottomStrip: some View {
        if let selectedCluster, !selectedItems.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(clusterDisplayName(selectedCluster))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("map.panel.title")
                    HStack(spacing: 4) {
                        Text(selectedItems.count, format: .number)
                            .font(.caption.monospacedDigit())
                        Text("photos")
                            .font(.caption)
                    }
                    .foregroundStyle(Paper.muted)
                    .fixedSize()
                    Spacer(minLength: 8)
                    Button {
                        selection.showInLibrary(selectedItems.map(\.id), title: clusterDisplayName(selectedCluster))
                    } label: {
                        Label("Show in Library", systemImage: "photo.on.rectangle")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("map.panel.show-in-library")
                    Button {
                        closePanel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                    .accessibilityLabel("Close photo strip")
                    .accessibilityIdentifier("map.panel.close")
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.top, 8)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(selectedItems) { item in
                            Button {
                                open(itemID: item.id)
                            } label: {
                                photoCard(item)
                            }
                            .buttonStyle(.plain)
                            .help("Open photo")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .frame(height: Self.photoRowHeight)
            }
            .frame(maxWidth: 720)
            // Opaque: map labels must not show through the photo strip.
            .paperFloatingPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map.panel")
            .padding(14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No geotagged photos",
            systemImage: "mappin.slash",
            description: Text("Add a location to see places and routes.")
        )
        .frame(maxWidth: 320)
        .padding(24)
        .paperFloatingPanel()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func mapStatus(text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(Paper.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Paper.raised, in: Capsule())
            .shadow(color: Paper.shadow.opacity(0.12), radius: 6, y: 2)
    }

    private func photoCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(item: item, width: 224, height: 150)
                    .frame(width: 112, height: 75)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if item.kind == .video {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .shadow(radius: 2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityIdentifier("map.panel.photo.\(item.id)")
            if let date = item.captureDate {
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption2)
                    .foregroundStyle(Paper.muted)
            }
        }
        .frame(width: 112, alignment: .leading)
    }

    // MARK: Behaviour

    private func clusterDisplayName(_ cluster: PlaceCluster) -> String {
        if let name = cluster.name, !name.isEmpty {
            return name
        }
        if let center = cluster.center {
            let nearest = places
                .compactMap { place -> (Place, Double)? in
                    guard let latitude = place.latitude, let longitude = place.longitude else { return nil }
                    return (place, center.distance(to: GeoPoint(latitude: latitude, longitude: longitude)))
                }
                .min { $0.1 < $1.1 }
            if let nearest, nearest.1 <= 1_500, let name = PlaceDisplayName.resolvedName(of: nearest.0) {
                return name
            }
        }
        return String(localized: "Unknown place")
    }

    /// On the globe a pin flies down to its city; closer in it opens the
    /// place's photos along the bottom.
    private func pinClicked(_ cluster: PlaceCluster) {
        lastMarkerSelection = Date()
        if isWorldView {
            guard let center = cluster.center else { return }
            flyTo(center, latitudeDelta: viewModel.thresholds.city * 0.9)
            return
        }
        selectedClusterID = cluster.id
        selection.select(viewModel.selectionIDs(for: cluster), focus: cluster.stopIDs.first)
    }

    private func closePanel() {
        // A selection made in another screen with no visible strip stays.
        guard selectedCluster != nil, !selectedItems.isEmpty else { return }
        selectedClusterID = nil
        selection.clear()
    }

    /// A photo in the strip opens in the large viewer, paging through the strip.
    private func open(itemID: String) {
        lastMarkerSelection = Date()
        selection.select([itemID], focus: itemID)
        selection.openViewer(itemID, in: selectedItems.map(\.id))
    }

    private func focus(on itemID: String?) {
        // A pin clicked here is already on screen; only selections made in
        // other screens move the camera.
        guard Date().timeIntervalSince(lastMarkerSelection) > 0.4 else { return }
        guard let itemID, let coordinate = snapshot.coordinateByID[itemID] else { return }
        moveCamera(to: .region(viewModel.focusRegion(for: coordinate)), isGlobe: false)
        selectedClusterID = snapshot.cluster(containing: itemID)?.id
    }

    /// When the photos span half the world, fitting them is the globe
    /// already, so there is nothing to zoom to.
    private var photosFitBelowWorld: Bool {
        guard !snapshot.stops.isEmpty else { return false }
        let span = viewModel.initialRegion(for: snapshot.stops).span
        return max(span.latitudeDelta, span.longitudeDelta) < 30
    }

    private func fitAll() {
        guard !snapshot.stops.isEmpty else { return }
        moveCamera(to: .region(viewModel.initialRegion(for: snapshot.stops)), isGlobe: false)
    }

    private func flyTo(_ center: GeoPoint, latitudeDelta: Double) {
        let region = MKCoordinateRegion(
            center: center.coordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: latitudeDelta)
        )
        moveCamera(to: .region(region), isGlobe: false)
    }

    private func showGlobe() {
        selectedClusterID = nil
        moveCamera(to: globePosition(world.snapshot.cameraTarget), isGlobe: true)
    }

    private func refitGlobeOverview() {
        guard isShowingGlobeOverview else { return }
        moveCamera(to: globePosition(world.snapshot.cameraTarget), isGlobe: true, animated: false)
    }

    /// The globe fills most of the shorter side of the map and stays whole.
    private func globePosition(_ target: FootprintsCameraTarget) -> MapCameraPosition {
        .camera(MapCamera(centerCoordinate: target.coordinate, distance: FootprintsCameraTarget.globeDistance(fitting: mapSize)))
    }

    private func moveCamera(to position: MapCameraPosition, isGlobe: Bool, animated: Bool = true) {
        isShowingGlobeOverview = isGlobe
        // MapKit reports nothing for a move to where the camera already is,
        // so only a real move waits for its report.
        awaitingProgrammaticCamera = isGlobe && position != cameraPosition
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.45)) {
                cameraPosition = position
            }
        } else {
            cameraPosition = position
        }
    }

    @MainActor
    private func refreshWorld(for input: FootprintsInput) async {
        let snapshot = FootprintsCalculator.snapshot(for: input)
        let previousTarget = world.snapshot.cameraTarget
        world = MapWorldState(
            snapshot: snapshot,
            geocoding: world.geocoding,
            isGeocoding: !snapshot.cityClusters.isEmpty,
            didEncounterGeocodingError: false
        )
        if isShowingGlobeOverview, previousTarget != snapshot.cameraTarget {
            moveCamera(to: globePosition(snapshot.cameraTarget), isGlobe: true, animated: false)
        }
        guard !snapshot.cityClusters.isEmpty else {
            world.isGeocoding = false
            return
        }
        let resolver = geocodeResolver ?? FootprintsGeocodeResolver()
        geocodeResolver = resolver
        let batch = await resolver.resolve(clusters: snapshot.cityClusters)
        guard !Task.isCancelled else { return }
        world.geocoding = batch.results
        world.isGeocoding = false
        world.didEncounterGeocodingError = batch.didEncounterError
    }

    private func itemIDs(of country: FootprintsCountrySummary) -> [String] {
        let clusterIDs = Set(country.clusterIDs)
        return world.snapshot.cityClusters
            .filter { clusterIDs.contains($0.id) }
            .flatMap(\.stopIDs)
    }

    private func midpoint(_ from: GeoPoint, _ to: GeoPoint) -> CLLocationCoordinate2D {
        GeoPoint.centre(of: [from, to])?.coordinate ?? from.coordinate
    }

    private func routeBearing(_ from: GeoPoint, _ to: GeoPoint) -> Double {
        let radians = Double.pi / 180
        let latitude1 = from.latitude * radians
        let latitude2 = to.latitude * radians
        let deltaLongitude = (to.longitude - from.longitude) * radians
        return atan2(
            sin(deltaLongitude) * cos(latitude2),
            cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(deltaLongitude)
        )
    }
}

/// Visited countries for the globe: city clusters and their reverse-geocoded
/// countries, independent of the current zoom level.
private struct MapWorldState {
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

/// The small point under a photo pin.
private struct MapPinPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private enum MapScreenStyle: String, CaseIterable, Identifiable {
    case satellite
    case standard

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .satellite: return "Satellite"
        case .standard: return "Standard"
        }
    }

    /// Satellite with labels: a real globe from far away and readable
    /// street and place names up close.
    var value: MapStyle {
        switch self {
        case .satellite: return .hybrid(elevation: .realistic)
        case .standard: return .standard(elevation: .realistic)
        }
    }
}

@MainActor
private final class MapNetworkMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var isOffline = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                self?.isOffline = offline
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.example.Moments.map-network"))
    }

    deinit {
        monitor.cancel()
    }
}
