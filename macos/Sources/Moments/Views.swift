import Foundation
import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

private enum MomentsSection: Hashable {
    case library
    case review
    case people
    case places
    case footprints
    case timeline
    case trips
    case group(String)
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
    @Query private var items: [MediaItem]
    /// "My groups" only; chapters live on the Chapters page.
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw != "chapter" }, sort: \UserGroup.name)
    private var groups: [UserGroup]
    @Query private var groupItems: [UserGroupItem]
    @Query private var faceObservations: [FaceObservation]
    @Query(sort: \Memory.updatedAt) private var memoryRecords: [Memory]
    @Query private var mediaTags: [MediaTag]
    @Query(sort: \PlaceOverride.id) private var placeOverrides: [PlaceOverride]
    @AppStorage(LibraryLaunchState.appStorageKey) private var firstLaunchCompleted = false
    @State private var groupEditorKind: GroupEditorKind?
    @State private var groupToEdit: UserGroup?
    @State private var groupToDelete: UserGroup?
    @State private var cachedGroupCounts: [String: Int] = [:]

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
                        sidebarRow("People", icon: "person.2", section: .people, identifier: "sidebar.people")
                        sidebarRow("Places", icon: "map", section: .places, identifier: "sidebar.places")
                        sidebarRow("Footprints", icon: "globe.americas", section: .footprints, identifier: "sidebar.footprints")
                        sidebarRow("Timeline", icon: "calendar", section: .timeline, identifier: "sidebar.timeline")
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
                            Label(String(localized: "New group"), systemImage: "plus")
                        }
                        .accessibilityIdentifier("sidebar.new-group")
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

                HStack(spacing: 0) {
                    Button {
                        importController.chooseFolder()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "plus.circle")
                            Text(String(localized: "Import more photos…"))
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(MomentsPalette.muted)
                        .padding(.leading, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.import")
                    // The AI model is set up here too, not only from ⌘, or
                    // after a note fails to organize.
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.callout)
                            .foregroundStyle(MomentsPalette.muted)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .help(String(localized: "AI model settings"))
                    .accessibilityLabel(String(localized: "AI model settings"))
                    .accessibilityIdentifier("sidebar.settings")
                }
            }
            .background(MomentsPalette.sidebar)
            .navigationTitle("Moments")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            Group {
                switch selection ?? .library {
                case .library:
                    LibraryView(state: libraryState, firstLaunchCompleted: $firstLaunchCompleted)
                case .review:
                    ReviewListView()
                case .people:
                    PeopleScreen()
                case .places:
                    PlacesScreen()
                case .footprints:
                    FootprintsScreen()
                case .timeline:
                    TimelineScreen()
                case .trips:
                    TripsScreen()
                case .group(let groupID):
                    GroupDetailView(groupID: groupID, state: libraryState)
                }
            }
            // The title bar continues the page's paper instead of a white strip.
            .toolbarBackground(MomentsPalette.content, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .frame(minWidth: 900, minHeight: 600)
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
            case .places: selection = .places
            case .footprints: selection = .footprints
            case .timeline: selection = .timeline
            case .trips: selection = .trips
            }
            shared.requestedDestination = nil
        }
        .onAppear {
            if !items.isEmpty { firstLaunchCompleted = true }
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
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.updatedAt)
            hasher.combine(item.captureDate)
            hasher.combine(item.kindRaw)
            hasher.combine(item.isScreenshot)
            hasher.combine(item.tripID)
            hasher.combine(item.place?.id)
        }
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
            if let badge, badge > 0 {
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
