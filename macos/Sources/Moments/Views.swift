import SwiftUI
import SwiftData
import MapKit

private enum MomentsSection: Hashable {
    case library
    case places
    case footprints
    case timeline
}

@MainActor
struct ContentView: View {
    @State private var selection: MomentsSection? = .library
    let libraryState: LibraryViewState

    init(libraryState: LibraryViewState) {
        self.libraryState = libraryState
    }

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
            case .library: LibraryView(state: libraryState)
            case .places: PlacesView()
            case .footprints: FootprintsView()
            case .timeline: TimelineView()
            }
        }
        .frame(minWidth: 760, minHeight: 500)
    }
}

struct PlacesView: View {
    @Environment(SelectionModel.self) private var selection

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
    @Environment(SelectionModel.self) private var selection
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
                    Label(item.title.isEmpty ? item.id : item.title, systemImage: selection.isSelected(item.id) ? "checkmark.circle.fill" : "circle.fill")
                        .onTapGesture { selection.select(item.id) }
                }
            } header: {
                Text(date, format: .dateTime.year().month().day())
            }
        }
        .navigationTitle("Timeline")
    }
}
