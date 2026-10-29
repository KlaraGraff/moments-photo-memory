import Foundation
import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

private enum MomentsSection: Hashable {
    case library
    case people
    case map
    case timeline
    case trips
    case group(String)
    case recentlyDeleted
}

enum GroupEditorKind: String, Equatable, Identifiable {
    case newManual
    case newSmart

    var id: String { rawValue }
}

private typealias MomentsPalette = Paper

struct ContentView: View {
    @State private var selection: MomentsSection? = .library
    /// Owned by the app so Library filters and scroll survive sidebar switches.
    let libraryState: LibraryViewState
    @Environment(SelectionModel.self) private var shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ImportController.self) private var importController
    @Environment(LibraryProjectionStore.self) private var projectionStore
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil }) private var items: [MediaItem]
    /// "My groups" only; chapters live on the Chapters page, and stack
    /// records are not groups anyone made.
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw != "chapter" && $0.kindRaw != "stack" }, sort: \UserGroup.name)
    private var groups: [UserGroup]
    @Query private var groupItems: [UserGroupItem]
    @Query private var faceObservations: [FaceObservation]
    @Query(sort: \Memory.updatedAt) private var memoryRecords: [Memory]
    @Query private var mediaTags: [MediaTag]
    @Query(sort: \PlaceOverride.id) private var placeOverrides: [PlaceOverride]
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt != nil }) private var deletedItems: [MediaItem]
    @AppStorage(LibraryLaunchState.appStorageKey) private var firstLaunchCompleted = false
    @State private var groupEditorKind: GroupEditorKind?
    @State private var groupToEdit: UserGroup?
    @State private var groupToDelete: UserGroup?
    @State private var cachedGroupCounts: [String: Int] = [:]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section {
                        sidebarRow("Library", icon: "photo.on.rectangle.angled", section: .library, identifier: "sidebar.library")
                        sidebarRow("People", icon: "person.2", section: .people, identifier: "sidebar.people")
                        sidebarRow("Map", icon: "map.circle", section: .map, identifier: "sidebar.map")
                        sidebarRow("Timeline", icon: "timeline.selection", section: .timeline, identifier: "sidebar.timeline")
                        sidebarRow("Chapters", icon: "book.pages", section: .trips, identifier: "sidebar.trips")
                    }

                    Section {
                        ForEach(groups, id: \.id) { group in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: group.kind == .smart ? "sparkles" : "folder")
                                    .foregroundStyle(MomentsPalette.accent)
                                Text(group.name)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Text("\(groupItemCount(group))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(MomentsPalette.muted)
                                Text(group.kind == .smart ? String(localized: "Smart") : String(localized: "Manual"))
                                    .font(.caption2)
                                    .foregroundStyle(MomentsPalette.muted)
                            }
                            .tag(MomentsSection.group(group.id))
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("sidebar.group.\(group.id)")
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                receiveDrop(providers, into: group)
                            }
                            .contextMenu {
                                Button(String(localized: "Rename")) {
                                    groupToEdit = group
                                    groupEditorKind = group.kind == .smart ? .newSmart : .newManual
                                }
                                if UserGroupRuleEngine.canDelete(group) {
                                    Button(String(localized: "Delete group"), role: .destructive) {
                                        groupToDelete = group
                                    }
                                }
                            }
                        }

                        Menu {
                            Button(String(localized: "New manual group")) {
                                groupToEdit = nil
                                groupEditorKind = .newManual
                            }
                            Button(String(localized: "New smart group")) {
                                groupToEdit = nil
                                groupEditorKind = .newSmart
                            }
                        } label: {
                            // A quiet row like the ones above it, not a bordered button.
                            Label {
                                Text(String(localized: "New group"))
                                    .foregroundStyle(MomentsPalette.muted)
                            } icon: {
                                Image(systemName: "plus")
                                    .foregroundStyle(MomentsPalette.accent)
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .accessibilityIdentifier("sidebar.new-group")
                    } header: {
                        Text(String(localized: "My groups"))
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(MomentsPalette.muted)
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
                // sidebar foot keeps only the way into Settings.
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
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(MomentsPalette.sidebar)
            .navigationTitle("Moments")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch selection ?? .library {
                case .library:
                    LibraryView(state: libraryState, firstLaunchCompleted: $firstLaunchCompleted)
                case .people:
                    PeopleScreen()
                case .map:
                    MapScreen()
                case .timeline:
                    TimelineScreen()
                case .trips:
                    TripsScreen()
                case .group(let groupID):
                    GroupDetailView(groupID: groupID, state: libraryState)
                case .recentlyDeleted:
                    RecentlyDeletedScreen()
                }
            }
            // After a correction to dates, places or people: what changed, and
            // Undo. In the detail column, not over the whole split view, where
            // it is drawn but does not get clicks; the viewer shows its own.
            .overlay(alignment: .bottom) {
                if shared.viewerRequest == nil { CorrectionUndoBar() }
            }
            .toolbar {
                // Each page's + adds that page's thing; People and Trips bring their own.
                if selection != .people && selection != .trips && selection != .recentlyDeleted {
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
        .sheet(isPresented: Binding(
            get: { shared.isShowingPlacesEditor },
            set: { shared.isShowingPlacesEditor = $0 }
        )) {
            PlacesEditorSheet()
        }
        // One accent everywhere, sheets included: no system blue controls.
        .tint(MomentsPalette.accent)
        .onChange(of: selection) { _, _ in
            shared.viewerRequest = nil
            #if DEBUG
            if PageProbe.isEnabled {
                PageProbe.shellReady()
                DispatchQueue.main.async { PageProbe.contentReady() }
            }
            #endif
        }
        #if DEBUG
        .onChange(of: shared.viewerRequest) { _, _ in
            if PageProbe.isEnabled {
                PageProbe.shellReady()
                DispatchQueue.main.async { PageProbe.contentReady() }
            }
        }
        .onChange(of: shared.openTripID) { _, _ in
            if PageProbe.isEnabled {
                PageProbe.shellReady()
                DispatchQueue.main.async { PageProbe.contentReady() }
            }
        }
        #endif
        .onChange(of: shared.requestedDestination) { _, destination in
            guard let destination else { return }
            // A scoped jump opens the Library at the top of those photos,
            // not where the full Library was left.
            if destination == .library, shared.libraryScope != nil, !shared.shouldRevealSelectionInLibrary {
                libraryState.topSectionScrollID = nil
            }
            switch destination {
            case .library: selection = .library
            case .people: selection = .people
            case .map: selection = .map
            case .timeline: selection = .timeline
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
        .onChange(of: groupCountsKey, initial: true) { _, _ in
            refreshGroupCounts()
        }
        .sheet(item: $groupEditorKind) { kind in
            GroupEditorSheet(kind: kind, group: groupToEdit, onDismiss: { groupToEdit = nil })
        }
        .alert(String(localized: "Delete group?"), isPresented: Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        ), presenting: groupToDelete) { group in
            Button(String(localized: "Delete"), role: .destructive) {
                guard UserGroupRuleEngine.canDelete(group) else { return }
                for membership in groupItems where membership.groupID == group.id {
                    modelContext.delete(membership)
                }
                modelContext.delete(group)
                try? modelContext.save()
                if case .group(group.id) = selection { selection = .library }
                groupToDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { groupToDelete = nil }
        } message: { group in
            Text(String(format: String(localized: "Delete group message"), group.name))
        }
    }

    @Environment(\.modelContext) private var modelContext

    private func groupItemCount(_ group: UserGroup) -> Int {
        cachedGroupCounts[group.id] ?? 0
    }

    private var groupCountsKey: Int {
        #if DEBUG
        ScrollProbe.count("sidebar.groupCountsKey")
        #endif
        var hasher = Hasher()
        // The projection revision changes once after a complete snapshot is
        // published. Rehashing every MediaItem and faulting every Place here
        // on each sidebar switch made a 20k library block navigation.
        hasher.combine(projectionStore.revision)
        // Place renames reach rules through overrides.
        for override in placeOverrides {
            hasher.combine(override.id)
            hasher.combine(override.nameOverride)
        }
        for group in groups {
            hasher.combine(group.id)
            hasher.combine(group.kind.rawValue)
            hasher.combine(group.updatedAt)
            hasher.combine(group.rules.mode.rawValue)
            for rule in group.rules.rules {
                hasher.combine(rule.field.rawValue)
                hasher.combine(rule.op.rawValue)
                hasher.combine(rule.value)
                hasher.combine(rule.secondaryValue)
            }
        }
        for membership in groupItems {
            hasher.combine(membership.groupID)
            hasher.combine(membership.mediaID)
            hasher.combine(membership.excluded)
        }
        for observation in faceObservations {
            hasher.combine(observation.id)
            hasher.combine(observation.mediaID)
            hasher.combine(observation.personID)
            hasher.combine(observation.confirmed)
        }
        for memory in memoryRecords {
            hasher.combine(memory.id)
            hasher.combine(memory.mediaID)
            hasher.combine(memory.updatedAt)
            hasher.combine(memory.revision)
        }
        for mediaTag in mediaTags {
            hasher.combine(mediaTag.id)
            hasher.combine(mediaTag.mediaID)
            hasher.combine(mediaTag.tagID)
            hasher.combine(mediaTag.updatedAt)
        }
        return hasher.finalize()
    }

    private func refreshGroupCounts() {
        var counts: [String: Int] = [:]
        let personIndex = UserGroupRuleEngine.makePersonIndex(faceObservations)
        for group in groups {
            counts[group.id] = UserGroupRuleEngine.visibleItems(for: group, from: items, memberships: groupItems, observations: faceObservations, personIDsByMediaID: personIndex).count
        }
        cachedGroupCounts = counts
    }

    private func receiveDrop(_ providers: [NSItemProvider], into group: UserGroup) -> Bool {
        for provider in providers {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let id = object as? String else { return }
                DispatchQueue.main.async {
                    guard let item = items.first(where: { $0.id == id }) else { return }
                    UserGroupRuleEngine.add(item, to: group, memberships: groupItems, context: modelContext)
                    try? modelContext.save()
                }
            }
        }
        return true
    }

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
