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
    @Environment(SelectionModel.self) private var selection
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(LibraryProjectionStore.self) private var projectionStore
    @Environment(\.modelContext) private var modelContext
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
    /// Nearest-place lookup is O(clusters × places); cache it before MapKit
    /// asks for annotation labels during every graph update.
    @State private var cachedClusterDisplayNames: [String: String] = [:]
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

    /// A whole-world map cannot usefully show every city pin. Aggregate the
    /// city clusters into coarse regional count pins so MapKit lays out a few
    /// dozen views instead of thousands; zooming in recomputes the detailed
    /// city/area/spot clusters.
    private var displayedClusters: [PlaceCluster] {
        Self.worldClusters(from: snapshot.clusters, aggregate: isWorldView || snapshot.level == .city)
    }

    private var snapshotKey: Int {
        var hasher = Hasher()
        hasher.combine(projectionStore.revision)
        hasher.combine(projectionStore.projection.mapStops.count)
        for id in selection.visibleItemIDs?.sorted() ?? [] { hasher.combine(id) }
        hasher.combine(viewModel.level(for: latitudeDelta))
        return hasher.finalize()
    }

    private var worldInputKey: Int {
        var hasher = Hasher()
        hasher.combine(projectionStore.revision)
        for id in selection.visibleItemIDs?.sorted() ?? [] { hasher.combine(id) }
        return hasher.finalize()
    }

    private var worldInput: FootprintsInput {
        let visible = selection.visibleItemIDs
        let stops = projectionStore.projection.mapStops.filter { visible?.contains($0.id) ?? true }
        return FootprintsInput(stops: stops)
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

    /// Every photo of the selected place, a burst's shots included.
    private var selectedClusterItems: [MediaItem] {
        guard let selectedCluster else { return [] }
        return selectedCluster.stopIDs
            .compactMap { itemsByID[$0] }
            .filter { selection.isVisible($0.id) }
            .sorted { ($0.effectiveCaptureDate ?? .distantPast, $0.id) < ($1.effectiveCaptureDate ?? .distantPast, $1.id) }
    }

    /// The strip's photos: a burst shows once, as its cover, as in the Library.
    private var selectedItems: [MediaItem] {
        let sorted = selectedClusterItems
        let shown = Set(stacks.collapse(sorted.map(\.id)).map(\.id))
        return sorted.filter { shown.contains($0.id) }
    }

    var body: some View {
        let currentWorldInput = worldInput
        // The Library's filters, kept in step with it, behind a search field
        // and a Filter button: pick a person to see only the places you
        // were with them.
        mapArea
        .compactLibraryFilters()
        .navigationTitle("Map")
        .task(id: snapshotKey) {
            let stops = currentWorldInput.stops
            let delta = latitudeDelta
            let projection = projectionStore.projection
            let built = await Task.detached(priority: .utility) {
                let snapshot = viewModel.snapshot(stops: stops, latitudeDelta: delta)
                let clusters = Self.worldClusters(from: snapshot.clusters, aggregate: snapshot.level == .city)
                let names = Self.clusterDisplayNames(for: clusters, projection: projection)
                return (snapshot: snapshot, names: names)
            }.value
            cachedClusterDisplayNames = built.names
            cachedSnapshot = built.snapshot
            // "Show on Map" from another screen: fly there once the pins exist.
            if let requested = selection.mapFocusRequest {
                selection.mapFocusRequest = nil
                focus(on: requested)
            }
        }
        .task(id: worldInputKey) {
            await refreshWorld(for: currentWorldInput)
        }
        .onChange(of: selection.focusedItemID) { _, focusedItemID in
            focus(on: focusedItemID)
        }
        // A request made while the map is already showing (e.g. from the viewer).
        .onChange(of: selection.mapFocusRequest) { _, requested in
            guard let requested else { return }
            selection.mapFocusRequest = nil
            focus(on: requested)
        }
        .onChange(of: selection.selectedItemIDs) { _, selectedItemIDs in
            clearSelectedClusterIfNeeded(selectedItemIDs, in: snapshot)
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
            .overlay(alignment: .top) { topBar }
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

            ForEach(displayedClusters) { cluster in
                if let center = cluster.center {
                    Annotation(coordinate: center.coordinate, anchor: .bottom) {
                        if isWorldView {
                            worldPhotoPin(cluster)
                        } else {
                            photoPin(cluster)
                        }
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
        // A burst counts once.
        let photoCount = stacks.foldedCount(cluster.stopIDs)
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
                    if photoCount > 1 {
                        Text(photoCount, format: .number)
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
        .accessibilityValue(Text(String(localized: "\(photoCount) photos")))
        .accessibilityIdentifier("map.marker.\(cluster.stopIDs.first ?? cluster.id)")
    }

    /// At globe scale a library can contain thousands of city clusters. A
    /// thumbnail task for every annotation makes MapKit's first layout fight
    /// the map itself. The count pin keeps the same selection and accessibility
    /// contract; zooming in restores the photo pin above.
    private func worldPhotoPin(_ cluster: PlaceCluster) -> some View {
        let photoCount = stacks.foldedCount(cluster.stopIDs)
        return Button {
            pinClicked(cluster)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Paper.accent, Color.white)
                    .shadow(color: Paper.shadow.opacity(0.28), radius: 3, y: 1)
                if photoCount > 1 {
                    Text(photoCount, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Paper.accent, in: Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: 1))
                        .offset(x: 8, y: -6)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(clusterDisplayName(cluster))
        .accessibilityLabel(clusterDisplayName(cluster))
        .accessibilityValue(Text(String(localized: "\(photoCount) photos")))
        .accessibilityIdentifier("map.marker.\(cluster.stopIDs.first ?? cluster.id)")
    }

    // MARK: Overlays

    /// The countries card and the map controls share one row, so they can
    /// never overlap: when the window is narrow the buttons drop their words
    /// first, then the map style becomes a small menu.
    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            if isWorldView, !world.snapshot.cityClusters.isEmpty {
                worldSummary.fixedSize()
            }
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                mapToolbar(.full)
                mapToolbar(.iconButtons)
                mapToolbar(.compact)
            }
        }
        .padding(14)
    }

    private enum ToolbarFit { case full, iconButtons, compact }

    private func mapToolbar(_ fit: ToolbarFit) -> some View {
        HStack(spacing: 8) {
            if fit == .compact {
                Menu {
                    Picker("Map style", selection: $mapStyle) {
                        ForEach(MapScreenStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "map")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Map style")
            } else {
                Picker("Map style", selection: $mapStyle) {
                    ForEach(MapScreenStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Two different jobs, so two buttons: back out to every country,
            // or frame exactly the places the photos were taken.
            Group {
                Button("Whole world", systemImage: "globe.europe.africa") {
                    showGlobe()
                }
                .help("Back out to the globe with every country you visited")
                .accessibilityIdentifier("map.globe")

                Button("Zoom to photos", systemImage: "photo.on.rectangle") {
                    fitAll()
                }
                .help("Zoom in to the places your photos were taken")
                .disabled(snapshot.stops.isEmpty)
                .accessibilityIdentifier("map.fit")
            }
            .labelStyle(fit == .full ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
        }
        .fixedSize()
        .padding(8)
        .paperFloatingPanel(cornerRadius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.toolbar")
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
                                    Text(String(localized: "\(country.photoCount) photos"))
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
                    Button {
                        selection.showInLibrary(selectedClusterItems.map(\.id), title: clusterDisplayName(selectedCluster))
                    } label: {
                        Text(clusterDisplayName(selectedCluster))
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Library")
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
                        selection.showInLibrary(selectedClusterItems.map(\.id), title: clusterDisplayName(selectedCluster))
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
                            .contextMenu {
                                Button("Open photo") { open(itemID: item.id) }
                                Button("Show in Library") { selection.revealInLibrary(item.id) }
                                if let tripID = item.tripID {
                                    Button("Show Trip") { selection.showTrip(tripID) }
                                }
                            }
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

    /// No pins: either nothing has a location yet, or the filters left out
    /// every photo that does. Each says so, and the second offers a way back.
    private var emptyState: some View {
        Group {
            if !projectionStore.projection.mapStops.isEmpty {
                ContentUnavailableView {
                    Label("No photos match these filters", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Change or clear the filters above to see more places.")
                } actions: {
                    Button("Clear filters") { LibraryFilterKeys.clearAll() }
                        .accessibilityIdentifier("map.clear-filters")
                }
            } else {
                ContentUnavailableView(
                    "No geotagged photos",
                    systemImage: "mappin.slash",
                    description: Text("Add a location to see places and routes.")
                )
            }
        }
        .frame(maxWidth: 320)
        .padding(24)
        .paperFloatingPanel()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityIdentifier("map.empty")
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
            if let date = item.effectiveCaptureDate {
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
        if let stopID = cluster.stopIDs.first,
           let name = projectionStore.projection.photoByID[stopID]?.placeName,
           !name.isEmpty {
            return name
        }
        if let cached = cachedClusterDisplayNames[cluster.id] {
            return cached
        }
        // Preserve a correct label during the first render before the task
        // has filled the cache. Normal map rendering takes the cached path.
        return nearestPlaceName(for: cluster) ?? String(localized: "Unknown place")
    }

    private nonisolated static func clusterDisplayNames(
        for clusters: [PlaceCluster],
        projection: LibraryProjection
    ) -> [String: String] {
        var names: [String: String] = [:]
        names.reserveCapacity(clusters.count)
        for cluster in clusters {
            if let name = cluster.name, !name.isEmpty {
                names[cluster.id] = name
            } else if let stopID = cluster.stopIDs.first,
                      let name = projection.photoByID[stopID]?.placeName,
                      !name.isEmpty {
                names[cluster.id] = name
            } else {
                names[cluster.id] = cluster.center.flatMap {
                    projection.placeIndex.nearestName(to: $0, within: 1_500)
                } ?? String(localized: "Unknown place")
            }
        }
        return names
    }

    private nonisolated static func worldClusters(from clusters: [PlaceCluster], aggregate: Bool) -> [PlaceCluster] {
        guard aggregate else { return clusters }
        let grid = 5.0
        var buckets: [String: (clusters: [PlaceCluster], points: [GeoPoint])] = [:]
        for cluster in clusters {
            guard let center = cluster.center else { continue }
            let key = "\(Int(floor(center.latitude / grid))),\(Int(floor(center.longitude / grid)))"
            buckets[key, default: ([], [])].clusters.append(cluster)
            buckets[key, default: ([], [])].points.append(center)
        }
        return buckets.map { key, bucket in
            PlaceCluster(
                id: "world:\(key)",
                level: .city,
                stopIDs: bucket.clusters.flatMap(\.stopIDs),
                center: GeoPoint.centre(of: bucket.points),
                firstDate: bucket.clusters.map(\.firstDate).min() ?? .distantPast
            )
        }
        .sorted {
            if $0.firstDate != $1.firstDate { return $0.firstDate < $1.firstDate }
            return $0.id < $1.id
        }
    }

    private func nearestPlaceName(for cluster: PlaceCluster) -> String? {
        guard let center = cluster.center else { return nil }
        // The projection already owns a coarse spatial index. Scanning every
        // SwiftData Place for every cluster made Map's first render quadratic
        // at library scale and kept the page probe from reaching later pages.
        return projectionStore.projection.placeIndex.nearestName(to: center, within: 1_500)
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
        loadItems(for: cluster.stopIDs)
        selectedClusterID = cluster.id
        selection.select(viewModel.selectionIDs(for: cluster), focus: cluster.stopIDs.first)
    }

    /// The map's first frame only needs immutable projection data. Materialize
    /// SwiftData models after a person opens a place so thumbnails and viewer
    /// actions remain available without fetching the whole library up front.
    private func loadItems(for ids: [String]) {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return }
        Task { @MainActor in
            let fetched = (try? modelContext.fetch(FetchDescriptor<MediaItem>())) ?? []
            guard !Task.isCancelled else { return }
            for item in fetched where wanted.contains(item.id) {
                itemsByID[item.id] = item
            }
        }
    }

    private func closePanel() {
        // A selection made in another screen with no visible strip stays.
        guard selectedCluster != nil, !selectedItems.isEmpty else { return }
        selectedClusterID = nil
        selection.clear()
    }

    private func clearSelectedClusterIfNeeded(_ selectedItemIDs: Set<String>, in snapshot: PlacesViewModel.Snapshot) {
        guard let selectedClusterID else { return }
        guard let cluster = snapshot.clusters.first(where: { $0.id == selectedClusterID }) else { return }
        if selectedItemIDs.isDisjoint(with: cluster.stopIDs) {
            self.selectedClusterID = nil
        }
    }

    /// A photo in the strip opens in the large viewer, paging through the strip.
    private func open(itemID: String) {
        lastMarkerSelection = Date()
        selection.select([itemID], focus: itemID)
        selection.openViewer(itemID, in: selectedClusterItems.map(\.id))
    }

    private func focus(on itemID: String?) {
        // A pin clicked here is already on screen; only selections made in
        // other screens move the camera.
        guard Date().timeIntervalSince(lastMarkerSelection) > 0.4 else { return }
        guard let itemID, let coordinate = snapshot.coordinateByID[itemID] else { return }
        moveCamera(to: .region(viewModel.focusRegion(for: coordinate)), isGlobe: false)
        selectedClusterID = snapshot.cluster(containing: itemID)?.id
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
        let snapshot = await Task.detached(priority: .utility) {
            FootprintsCalculator.snapshot(for: input)
        }.value
        guard !Task.isCancelled else { return }
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

/// Lets one control switch between label styles depending on the room it has.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
