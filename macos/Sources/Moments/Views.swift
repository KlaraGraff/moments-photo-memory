import SwiftUI
import SwiftData
import MapKit

private enum MomentsSection: Hashable {
    case library
    case places
    case footprints
    case timeline
}

struct ContentView: View {
    @State private var selection: MomentsSection? = .library

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Moments") {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                        .tag(MomentsSection.library)
                    Label("Places", systemImage: "map")
                        .tag(MomentsSection.places)
                    Label("Footprints", systemImage: "globe.americas")
                        .tag(MomentsSection.footprints)
                    Label("Timeline", systemImage: "calendar")
                        .tag(MomentsSection.timeline)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Moments")
        } detail: {
            switch selection ?? .library {
            case .library: LibraryView()
            case .places: PlacesView()
            case .footprints: FootprintsView()
            case .timeline: TimelineView()
            }
        }
        .frame(minWidth: 760, minHeight: 500)
    }
}

struct LibraryView: View {
    @Query private var items: [MediaItem]

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No memories yet", systemImage: "photo.on.rectangle", description: Text("Add a photo or import a synthetic demo to begin."))
            } else {
                List(items.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.kind == .video ? "video" : "photo")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title.isEmpty ? item.id : item.title)
                                .font(.headline)
                            Text(item.id)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let date = item.captureDate {
                                Text(date, format: .dateTime.year().month().day())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if item.source == .demo {
                            Text("Synthetic demo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Library")
    }
}

struct PlacesView: View {
    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0.005, longitude: 0.003), span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03))))
            .navigationTitle("Places")
    }
}

struct FootprintsView: View {
    var body: some View {
        ContentUnavailableView("Footprints", systemImage: "globe.americas", description: Text("Your shared travel path will appear here."))
            .navigationTitle("Footprints")
    }
}

struct TimelineView: View {
    @Query private var items: [MediaItem]

    private var groupedItems: [(Date, [MediaItem])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.captureDate ?? .distantPast)
        }
        return groups.sorted { $0.key < $1.key }
    }

    var body: some View {
        List(groupedItems, id: \.0) { date, dayItems in
            Section {
                ForEach(dayItems) { item in
                    Label(item.title.isEmpty ? item.id : item.title, systemImage: "circle.fill")
                }
            } header: {
                Text(date, format: .dateTime.year().month().day())
            }
        }
        .navigationTitle("Timeline")
    }
}
