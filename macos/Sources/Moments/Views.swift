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
    /// Owned by the app so Library filters, density and scroll survive sidebar switches.
    let libraryState: LibraryViewState
    @Environment(SelectionModel.self) private var shared

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
            case .places: PlacesScreen()
            case .footprints: FootprintsView()
            case .timeline: TimelineScreen()
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onChange(of: shared.requestedDestination) { _, destination in
            guard let destination else { return }
            switch destination {
            case .library: selection = .library
            case .places: selection = .places
            case .footprints: selection = .footprints
            case .timeline: selection = .timeline
            }
            shared.requestedDestination = nil
        }
    }
}

struct FootprintsView: View {
    var body: some View {
        ContentUnavailableView("Footprints", systemImage: "globe.americas", description: Text("Your shared travel path will appear here."))
            .navigationTitle("Footprints")
    }
}
