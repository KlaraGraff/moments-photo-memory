import Foundation
import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

private enum MomentsSection: Hashable {
    case library
    case trips
    case recentlyDeleted
}

private typealias MomentsPalette = Paper

struct ContentView: View {
    @State private var selection: MomentsSection? = .library
    /// Owned by the app so Library filters and scroll survive sidebar switches.
    let libraryState: LibraryViewState
    @Environment(SelectionModel.self) private var shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ImportController.self) private var importController
    /// The shared library lists; fetched once for every page instead of once
    /// per page, and refreshed when something the sidebar groups by changes.
    @Environment(LibraryStore.self) private var store
    @AppStorage(LibraryLaunchState.appStorageKey) private var firstLaunchCompleted = false

    /// A click on a page in the sidebar also leaves the large map, even when
    /// that page was already the one behind it.
    private var sidebarSelection: Binding<MomentsSection?> {
        Binding(
            get: { selection },
            set: { section in
                selection = section
                if shared.mapScope != nil { shared.mapScope = nil }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: sidebarSelection) {
                    // The two pages the app is for: the photos, and the
                    // chapters to look back on. People and places are not
                    // pages: they show on the photos and chapters themselves.
                    Section {
                        sidebarRow("Library", icon: "photo.on.rectangle.angled", section: .library, identifier: "sidebar.library")
                        sidebarRow("Chapters", icon: "book.pages", section: .trips, identifier: "sidebar.trips")
                    }

                    // Shown once something was deleted, like a Trash that
                    // appears when it has something in it.
                    if !deletedItems.isEmpty || selection == .recentlyDeleted {
                        Section {
                            Label {
                                HStack(spacing: 2) {
                                    Text(String(localized: "Recently Deleted"))
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    if !deletedItems.isEmpty {
                                        Text("\(deletedItems.count)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(MomentsPalette.muted)
                                    }
                                }
                            } icon: {
                                Image(systemName: "trash")
                            }
                            .tag(MomentsSection.recentlyDeleted)
                            .accessibilityIdentifier("sidebar.recently-deleted")
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .tint(MomentsPalette.accent)

                // Importing lives in the toolbar's + and the File menu; the
                // sidebar foot keeps the way into Settings.
                HStack {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.callout)
                            .foregroundStyle(MomentsPalette.muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Settings"))
                    .accessibilityLabel(String(localized: "Settings"))
                    .accessibilityIdentifier("sidebar.settings")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(MomentsPalette.sidebar)
            .navigationTitle("Moments")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                if shared.mapScope != nil {
                    // The large map: a small map somewhere was clicked. It
                    // stands in front of the page until Back.
                    MapScreen()
                } else {
                    switch selection ?? .library {
                    case .library:
                        LibraryView(state: libraryState, firstLaunchCompleted: $firstLaunchCompleted)
                    case .trips:
                        TripsScreen()
                    case .recentlyDeleted:
                        RecentlyDeletedScreen()
                    }
                }
            }
            // After a correction to dates, places or people: what changed, and
            // Undo. In the detail column, not over the whole split view, where
            // it is drawn but does not get clicks; the viewer shows its own.
            .overlay(alignment: .bottom) {
                if shared.viewerRequest == nil { CorrectionUndoBar() }
            }
            .toolbar {
                // Each page's + adds that page's thing: photos in the
                // Library; Chapters brings its own.
                if (selection ?? .library) == .library && shared.mapScope == nil {
                    ToolbarItem(placement: .primaryAction) {
                        ImportToolbarButton()
                    }
                }
            }
            #if DEBUG
            .background {
                if MapViewProbe.isEnabled { MapViewProbe() }
            }
            #endif
            // The title bar continues the page's paper instead of a white strip.
            .toolbarBackground(MomentsPalette.content, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            if libraryState.windowWidth != width { libraryState.windowWidth = width }
        }
        // The large photo view is a card over the whole window, sidebar included.
        .overlay {
            if let request = shared.viewerRequest {
                PhotoViewer(request: request, libraryState: libraryState)
                    // Opens and closes like a file preview in Claude: a quick
                    // fade with a slight grow from the middle.
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(reduceMotion ? nil : Motion.snap, value: shared.viewerRequest == nil)
        // "3 moved to Recently Deleted · Undo", over the viewer too.
        .overlay(alignment: .bottom) {
            DeletionUndoBar()
        }
        .animation(reduceMotion ? nil : Motion.snap, value: shared.lastDeletion == nil)
        .modifier(PhotoDeletionConfirmation())
        .sheet(isPresented: Binding(
            get: { shared.dateAdjustmentItemIDs != nil },
            set: { if !$0 { shared.dateAdjustmentItemIDs = nil } }
        )) {
            DateAdjustmentSheet(itemIDs: shared.dateAdjustmentItemIDs ?? [])
        }
        // One accent everywhere, sheets included: no system blue controls.
        .tint(MomentsPalette.accent)
        .onChange(of: selection) { _, _ in
            shared.viewerRequest = nil
        }
        .onChange(of: shared.requestedDestination) { _, destination in
            guard let destination else { return }
            // A scoped jump opens the Library at the top of those photos,
            // not where the full Library was left.
            if destination == .library, shared.libraryScope != nil, !shared.shouldRevealSelectionInLibrary {
                libraryState.topSectionScrollID = nil
            }
            switch destination {
            case .library: selection = .library
            case .trips: selection = .trips
            }
            shared.requestedDestination = nil
        }
        .onAppear {
            if !items.isEmpty { firstLaunchCompleted = true }
            // Photos whose 30 days in Recently Deleted are up go for good.
            RecentlyDeleted.purgeExpired(context: modelContext)
            DeleteShortcutMonitor.install()
            TitleBarDoubleClick.install()
        }
    }

    @Environment(\.modelContext) private var modelContext

    /// The shared library's live photos, not fetched again per sidebar page.
    private var items: [MediaItem] { store.items }

    /// Photos in Recently Deleted, most recently deleted first.
    private var deletedItems: [MediaItem] { store.deletedItems }

    private func sidebarRow(
        _ title: LocalizedStringKey,
        icon: String,
        section: MomentsSection,
        identifier: String
    ) -> some View {
        Label(title, systemImage: icon)
            .tag(section)
            .accessibilityIdentifier(identifier)
    }
}

/// The window's + button: the same two imports as the File menu.
private struct ImportToolbarButton: View {
    @Environment(ImportController.self) private var importController

    var body: some View {
        Menu {
            Button(String(localized: "Import Folder…")) {
                importController.chooseFolder()
            }
            Button(String(localized: "Import from Apple Photos…")) {
                NotificationCenter.default.post(name: .momentsShowPhotosImport, object: nil)
            }
        } label: {
            Label(String(localized: "Import photos"), systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Import photos"))
        .accessibilityIdentifier("toolbar.import")
    }
}

#if DEBUG
/// UI tests only: counts the live map views in the app's windows, so a test
/// can check the map is gone (and stops drawing) once you leave the Map.
private struct MapViewProbe: View {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-MomentsUITestMapProbe")

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("mapviews=\(Self.liveMapViews())")
                .accessibilityIdentifier("debug.mapviews")
        }
    }

    static func liveMapViews() -> Int {
        func count(_ view: NSView) -> Int {
            (view is MKMapView ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) }
        }
        return NSApp.windows.compactMap(\.contentView?.superview).reduce(0) { $0 + count($1) }
    }
}
#endif
