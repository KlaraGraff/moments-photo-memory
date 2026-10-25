import Foundation
import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

private enum MomentsSection: Hashable {
    case library
    case review
    case places
    case footprints
    case timeline
    case group(String)
}

enum GroupEditorKind: String, Equatable, Identifiable {
    case newManual
    case newSmart

    var id: String { rawValue }
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
    @Query(sort: \UserGroup.name) private var groups: [UserGroup]
    @Query private var groupItems: [UserGroupItem]
    @AppStorage(LibraryLaunchState.appStorageKey) private var firstLaunchCompleted = false
    @State private var groupEditorKind: GroupEditorKind?
    @State private var groupToEdit: UserGroup?
    @State private var groupToDelete: UserGroup?

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
                        ForEach(groups, id: \.id) { group in
                            HStack(spacing: 8) {
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
                            Label(String(localized: "+ New group"), systemImage: "plus")
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
            case .group(let groupID):
                GroupDetailView(groupID: groupID, state: libraryState)
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
        UserGroupRuleEngine.visibleItems(for: group, from: items, memberships: groupItems).count
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
