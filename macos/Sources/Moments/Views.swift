import SwiftUI
import SwiftData
import MapKit

private enum MomentsSection: Hashable {
    case library
    case review
    case places
    case footprints
    case timeline
}

private enum MomentsPalette {
    static let sidebar = Color(red: 0.969, green: 0.906, blue: 0.863)
    static let content = Color(red: 0.984, green: 0.945, blue: 0.918)
    static let ink = Color(red: 0.227, green: 0.165, blue: 0.141)
    static let muted = Color(red: 0.478, green: 0.365, blue: 0.314)
    static let accent = Color(red: 0.690, green: 0.290, blue: 0.184)
}

struct ContentView: View {
    @State private var selection: MomentsSection? = .library
    /// Owned by the app so Library filters and scroll survive sidebar switches.
    let libraryState: LibraryViewState
    @Environment(SelectionModel.self) private var shared
    @Environment(ImportController.self) private var importController
    @Query private var items: [MediaItem]
    @AppStorage(LibraryLaunchState.appStorageKey) private var firstLaunchCompleted = false

    private var reviewCount: Int {
        items.reduce(into: 0) { count, item in
            if item.needsImportReview { count += 1 }
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section {
                        sidebarRow("Library", icon: "photo.on.rectangle.angled", section: .library, identifier: "sidebar.library")
                        sidebarRow("To review", icon: "checkmark.circle", section: .review, identifier: "sidebar.review", badge: reviewCount)
                        // People is intentionally absent until issue #31 lands.
                        sidebarRow("Places", icon: "map", section: .places, identifier: "sidebar.places")
                        sidebarRow("Footprints", icon: "globe.americas", section: .footprints, identifier: "sidebar.footprints")
                        sidebarRow("Timeline", icon: "calendar", section: .timeline, identifier: "sidebar.timeline")
                    }

                    Section {
                        Label(String(localized: "Manual groups"), systemImage: "folder")
                        Label(String(localized: "Recent trips"), systemImage: "sparkles")
                        Label(String(localized: "Create group"), systemImage: "plus")
                            .foregroundStyle(MomentsPalette.muted.opacity(0.48))
                            .disabled(true)
                    } header: {
                        Text(String(localized: "My groups"))
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(MomentsPalette.muted)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .tint(MomentsPalette.accent)

                Divider()
                Button {
                    importController.chooseFolder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text(String(localized: "Import more photos…"))
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(MomentsPalette.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.import")
            }
            .background(MomentsPalette.sidebar)
            .navigationTitle("Moments")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            switch selection ?? .library {
            case .library:
                LibraryView(state: libraryState, firstLaunchCompleted: $firstLaunchCompleted)
            case .review:
                ReviewListView()
            case .places:
                PlacesScreen()
            case .footprints:
                FootprintsScreen()
            case .timeline:
                TimelineScreen()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
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
        .onAppear {
            if !items.isEmpty { firstLaunchCompleted = true }
        }
    }

    @ViewBuilder
    private func sidebarRow(
        _ title: String,
        icon: String,
        section: MomentsSection,
        identifier: String,
        badge: Int? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Label(LocalizedStringKey(title), systemImage: icon)
            Spacer(minLength: 4)
            if let badge {
                Text("\(badge)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MomentsPalette.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(MomentsPalette.accent.opacity(0.12), in: Capsule())
            }
        }
        .tag(section)
        .accessibilityIdentifier(identifier)
    }
}
