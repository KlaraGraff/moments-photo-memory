import AppKit
import SwiftData
import SwiftUI

/// Recently Deleted, as in Photos: what was deleted from Moments in the last
/// 30 days, newest first, each with the days it has left. Recover puts photos
/// back where they were; Delete removes them from Moments for good.
struct RecentlyDeletedScreen: View {
    @Environment(SelectionModel.self) private var shared
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt != nil }, sort: \MediaItem.deletedAt, order: .reverse)
    private var items: [MediaItem]
    @State private var selected: Set<String> = []
    @State private var anchor: String?
    /// The photos waiting for "Delete for good?".
    @State private var pendingPurge: [String]?

    private var own: [MediaItem] { items.filter { RecentlyDeleted.canDelete($0) } }

    /// The selection, or everything when nothing is selected.
    private var targets: [MediaItem] {
        selected.isEmpty ? own : own.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
                .padding(.horizontal, PaperMetrics.screenInset)
                .padding(.top, PaperMetrics.screenTopInset)
                .padding(.bottom, 14)
            if items.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Nothing in Recently Deleted"), systemImage: "trash")
                } description: {
                    Text(String(localized: "Photos you delete wait here for 30 days."))
                }
                .foregroundStyle(Paper.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 200), spacing: 14)], spacing: 16) {
                        ForEach(items, id: \.id) { item in
                            cell(item)
                        }
                    }
                    .padding(.horizontal, PaperMetrics.screenInset)
                    .padding(.bottom, 24)
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { selected = [] }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Paper.canvas)
        .navigationTitle(String(localized: "Recently Deleted"))
        .navigationSubtitle(items.isEmpty ? "" : String(localized: "\(items.count) items"))
        .onAppear { RecentlyDeleted.purgeExpired(context: modelContext) }
        .onChange(of: items.map(\.id)) { _, ids in
            selected.formIntersection(ids)
        }
        .alert(
            Self.purgeTitle(pendingPurge?.count ?? 0),
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            presenting: pendingPurge
        ) { ids in
            Button(String(localized: "Delete"), role: .destructive) {
                pendingPurge = nil
                RecentlyDeleted.deletePermanently(PhotoDeletion.fetch(ids, context: modelContext), context: modelContext)
                selected.subtract(ids)
            }
            .accessibilityIdentifier("recently-deleted.purge.confirm")
            Button(String(localized: "Cancel"), role: .cancel) { pendingPurge = nil }
        } message: { _ in
            Text(String(localized: "Their notes and memories go with them, and this can't be undone. Your original files on this Mac and in Apple Photos are not touched."))
        }
    }

    /// What happens here, and Recover / Delete for the selection or for all.
    /// Icons and words while there is room, icons only when the window is narrow.
    private var actionBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(localized: "Photos here are removed from Moments after 30 days. Your original files stay where they are."))
                .font(.callout)
                .foregroundStyle(Paper.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                actions(showsTitles: true)
                actions(showsTitles: false)
            }
        }
    }

    private func actions(showsTitles: Bool) -> some View {
        HStack(spacing: 8) {
            actionButton(
                selected.isEmpty ? String(localized: "Recover All") : String(localized: "Recover"),
                icon: "arrow.uturn.backward",
                identifier: "recently-deleted.recover",
                showsTitle: showsTitles
            ) {
                withAnimation(Motion.snap) {
                    RecentlyDeleted.recover(targets, context: modelContext)
                    selected = []
                }
            }
            actionButton(
                selected.isEmpty ? String(localized: "Delete All") : String(localized: "Delete"),
                icon: "trash",
                identifier: "recently-deleted.delete",
                showsTitle: showsTitles
            ) {
                pendingPurge = targets.map(\.id)
            }
        }
        .fixedSize()
        .disabled(targets.isEmpty)
    }

    private func actionButton(_ title: String, icon: String, identifier: String, showsTitle: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if showsTitle {
                Label(title, systemImage: icon)
            } else {
                Label(title, systemImage: icon).labelStyle(.iconOnly)
            }
        }
        .controlSize(.regular)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func cell(_ item: MediaItem) -> some View {
        let isSelected = selected.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(item: item, width: 280, height: 280)
                .aspectRatio(1, contentMode: .fit)
                // Waiting to go: a little faded, like Photos.
                .opacity(0.86)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Paper.accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        Image(systemName: "video.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(color: Paper.shadow.opacity(0.4), radius: 2)
                            .padding(7)
                    }
                }
            Text(Self.daysLeftText(RecentlyDeleted.daysLeft(item)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Paper.muted)
        }
        .contentShape(Rectangle())
        // One gesture, so a single click doesn't wait out the double-click time.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                shared.openViewer(item.id, in: items.map(\.id))
            } else {
                click(item.id)
            }
        }
        .contextMenu {
            Button(String(localized: "Recover")) {
                RecentlyDeleted.recover(menuTargets(item), context: modelContext)
                selected = []
            }
            Button(String(localized: "Delete Now"), role: .destructive) {
                pendingPurge = menuTargets(item).map(\.id)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title.isEmpty ? String(localized: "Photo") : item.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { click(item.id) }
        .accessibilityIdentifier("recently-deleted.photo.\(item.id)")
    }

    private func menuTargets(_ item: MediaItem) -> [MediaItem] {
        selected.contains(item.id) ? own.filter { selected.contains($0.id) } : own.filter { $0.id == item.id }
    }

    /// The grid's own click rules: a click selects, ⌘ adds or removes, ⇧ extends.
    private func click(_ id: String) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let order = items.map(\.id)
        if flags.contains(.shift), let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            selected.formUnion(order[min(from, to)...max(from, to)])
        } else if flags.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        } else {
            selected = selected == [id] ? [] : [id]
            anchor = id
        }
    }

    static func daysLeftText(_ days: Int) -> String {
        days <= 1 ? String(localized: "Last day") : String(localized: "\(days) days left")
    }

    static func purgeTitle(_ count: Int) -> String {
        count == 1
            ? String(localized: "Delete this photo for good?")
            : String(localized: "Delete \(count) photos for good?")
    }
}
