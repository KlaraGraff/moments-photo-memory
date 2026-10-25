import CoreLocation
import Combine
import Foundation
import MapKit
import Network
import SwiftData
import SwiftUI
import MomentsCore

/// Native map workspace for clustered photo places and chronological routes.
/// The sidebar owns navigation; this screen only reads and updates shared
/// selection state.
struct PlacesScreen: View {
    @Query(sort: \MediaItem.captureDate) private var items: [MediaItem]
    @Query private var places: [Place]
    @Environment(SelectionModel.self) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cameraPosition: MapCameraPosition
    @State private var latitudeDelta = PlacesScreen.defaultLatitudeDelta
    @State private var mapStyle: PlacesMapStyle = .standard
    @State private var selectedClusterID: String?
    @State private var isLoading = true
    @StateObject private var networkMonitor = PlacesNetworkMonitor()

    private let viewModel = PlacesViewModel()

    private static let defaultLatitudeDelta = 30.0

    init() {
        _cameraPosition = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    span: MKCoordinateSpan(latitudeDelta: Self.defaultLatitudeDelta, longitudeDelta: Self.defaultLatitudeDelta)
                )
            )
        )
    }

    /// Clustering and routes are rebuilt only when items, the Library filter or
    /// the zoom level change, not on every render or selection change.
    @State private var cachedSnapshot: PlacesViewModel.Snapshot?

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

    private var selectedCluster: PlaceCluster? {
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
        let ids = Set(selectedCluster.stopIDs)
        return items
            .filter { ids.contains($0.id) && selection.isVisible($0.id) }
            .sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            mapView
                .overlay(alignment: .topTrailing) { mapToolbar }
                .overlay(alignment: .bottom) { bottomStrip }

            if isLoading {
                loadingState
            } else if snapshot.isEmpty {
                emptyState
            }

            if networkMonitor.isOffline {
                mapStatus(text: "Map tiles unavailable", systemImage: "wifi.exclamationmark", style: .warning)
                    .padding(.top, 12)
            }
        }
        .navigationTitle("Places")
        .task(id: snapshotKey) {
            cachedSnapshot = viewModel.snapshot(
                items: items,
                visibleItemIDs: selection.visibleItemIDs,
                latitudeDelta: latitudeDelta
            )
        }
        .task {
            isLoading = false
            updateCameraIfNeeded()
        }
        .onChange(of: items.map(\.id)) { _, _ in
            updateCameraIfNeeded()
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
            updateCameraIfNeeded()
        }
        .onChange(of: latitudeDelta) { _, _ in
            if let selectedClusterID,
               !snapshot.clusters.contains(where: { $0.id == selectedClusterID }) {
                self.selectedClusterID = nil
            }
        }
    }

    private var mapView: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom, .rotate, .pitch]) {
            ForEach(snapshot.routeSegments) { segment in
                if let from = segment.from.center, let to = segment.to.center {
                    MapPolyline(
                        coordinates: [from.coordinate, to.coordinate],
                        contourStyle: .geodesic
                    )
                    .stroke(.blue.opacity(0.75), lineWidth: 3)

                    Annotation(coordinate: midpoint(from, to), anchor: .center) {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .rotationEffect(.radians(routeBearing(from, to)))
                            .accessibilityHidden(true)
                    } label: {
                        EmptyView()
                    }
                }
            }

            ForEach(snapshot.clusters) { cluster in
                if let center = cluster.center {
                    Annotation(coordinate: center.coordinate, anchor: .bottom) {
                        clusterAnnotation(cluster)
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
        .accessibilityIdentifier("places.map")
        .accessibilityLabel("Places map")
        .onMapCameraChange(frequency: .onEnd) { context in
            latitudeDelta = context.region.span.latitudeDelta
        }
    }

    private var mapToolbar: some View {
        HStack(spacing: 8) {
            Picker("Map style", selection: $mapStyle) {
                ForEach(PlacesMapStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Button("Fit all", systemImage: "arrow.up.left.and.arrow.down.right") {
                fitAll()
            }
            .labelStyle(.iconOnly)
            .help("Fit all")
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(14)
    }

    @ViewBuilder
    private var bottomStrip: some View {
        if let selectedCluster, !selectedItems.isEmpty {
            VStack(spacing: 8) {
                HStack {
                    Text(clusterDisplayName(selectedCluster))
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text(selectedItems.count, format: .number)
                            .font(.caption.monospacedDigit())
                        Text("photos")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close", systemImage: "xmark") {
                        selectedClusterID = nil
                        selection.clear()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close photo strip")
                }
                .padding(.horizontal, 12)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(selectedItems) { item in
                            Button {
                                select(itemID: item.id)
                            } label: {
                                photoCard(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: 720)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var loadingState: some View {
        mapStatus(text: "Loading map…", systemImage: "map", style: .normal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No geotagged photos",
            systemImage: "mappin.slash",
            description: Text("Add a location to see places and routes.")
        )
        .frame(maxWidth: 320)
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func mapStatus(text: LocalizedStringKey, systemImage: String, style: MapStatusStyle) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(style.background, in: Capsule())
            .overlay(Capsule().stroke(style.border, lineWidth: 1))
    }

    private func clusterAnnotation(_ cluster: PlaceCluster) -> some View {
        let isSelected = selectedCluster?.id == cluster.id
        return Button {
            select(cluster: cluster)
        } label: {
            ZStack {
                if cluster.level == .spot, cluster.stopIDs.count == 1, let stopID = cluster.stopIDs.first {
                    photoThumbnail(for: stopID, selected: isSelected)
                } else {
                    Text("\(cluster.stopIDs.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 38, minHeight: 38)
                        .background(isSelected ? Color.accentColor : Color.teal, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(radius: 4, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clusterDisplayName(cluster))
        .accessibilityValue(Text("\(cluster.stopIDs.count) photos"))
        .accessibilityIdentifier("places.annotation.\(cluster.id)")
    }

    private func photoThumbnail(for itemID: String, selected: Bool) -> some View {
        Image(systemName: "photo")
            .font(.body)
            .foregroundStyle(selected ? Color.white : Color.accentColor)
            .frame(width: 38, height: 38)
            .background(selected ? Color.accentColor : Color.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? .white : .accentColor, lineWidth: 2))
            .shadow(radius: 4, y: 2)
    }

    private func photoCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 112, height: 66)
                Image(systemName: item.kind == .video ? "video" : "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(item.title.isEmpty ? item.id : item.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.55))
            }
            if let date = item.captureDate {
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, alignment: .leading)
    }

    private func clusterDisplayName(_ cluster: PlaceCluster) -> String {
        if let name = cluster.name, !name.isEmpty {
            return name
        }
        let nearestPlace = places
            .filter { $0.latitude != nil && $0.longitude != nil }
            .compactMap { place -> (Place, Double)? in
                guard let latitude = place.latitude, let longitude = place.longitude,
                      let center = cluster.center else { return nil }
                return (place, center.distance(to: GeoPoint(latitude: latitude, longitude: longitude)))
            }
            .min { $0.1 < $1.1 }
        if let nearestPlace, nearestPlace.1 <= 1_500, !nearestPlace.0.name.isEmpty {
            return nearestPlace.0.name
        }
        switch cluster.level {
        case .city: return "City cluster"
        case .area: return "Area cluster"
        case .spot: return "Spot"
        }
    }

    private func select(cluster: PlaceCluster) {
        selectedClusterID = cluster.id
        let ids = viewModel.selectionIDs(for: cluster)
        let focus = cluster.stopIDs.first
        selection.select(ids, focus: focus)
    }

    private func select(itemID: String) {
        selection.select([itemID], focus: itemID)
    }

    private func focus(on itemID: String?) {
        guard let itemID, let coordinate = snapshot.coordinateByID[itemID] else { return }
        let region = viewModel.focusRegion(for: coordinate)
        moveCamera(to: region)
        selectedClusterID = snapshot.cluster(containing: itemID)?.id
    }

    private func fitAll() {
        let region = viewModel.initialRegion(for: snapshot.stops)
        moveCamera(to: region)
    }

    private func updateCameraIfNeeded() {
        guard !snapshot.stops.isEmpty else { return }
        if cameraPosition.region == nil || cameraPosition.region?.center.latitude == 0 && cameraPosition.region?.center.longitude == 0 {
            fitAll()
        }
    }

    private func moveCamera(to region: MKCoordinateRegion) {
        if reduceMotion {
            cameraPosition = .region(region)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                cameraPosition = .region(region)
            }
        }
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

private enum PlacesMapStyle: String, CaseIterable, Identifiable {
    case standard
    case imagery

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .standard: return "Standard"
        case .imagery: return "Imagery"
        }
    }

    var value: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .realistic)
        case .imagery: return .imagery(elevation: .realistic)
        }
    }
}

private enum MapStatusStyle {
    case normal
    case warning

    var foreground: Color {
        switch self {
        case .normal: return .primary
        case .warning: return .orange
        }
    }

    var background: AnyShapeStyle {
        switch self {
        case .normal: return AnyShapeStyle(.regularMaterial)
        case .warning: return AnyShapeStyle(Color.orange.opacity(0.12))
        }
    }

    var border: Color {
        switch self {
        case .normal: return .primary.opacity(0.12)
        case .warning: return .orange.opacity(0.45)
        }
    }
}

@MainActor
private final class PlacesNetworkMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var isOffline = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                self?.isOffline = offline
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.example.Moments.places-network"))
    }

    deinit {
        monitor.cancel()
    }
}
