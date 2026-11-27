import Foundation
import Observation

/// Sidebar destinations other screens can ask the window to switch to.
enum SidebarDestination: Hashable {
    case library
    case trips
}

/// A request to show photos in the large viewer, with the order to page through.
struct ViewerRequest: Equatable {
    var itemIDs: [String]
    var itemID: String
}

/// Photos the Library was asked to show on their own: the photos of a person
/// whose face was clicked, the photos taken at a place whose name was clicked.
/// The Library shows a heading for it with one button back to every photo.
struct LibraryScope: Equatable {
    var title: String
    var itemIDs: Set<String>
    /// The person these are the photos of, so the heading can show the face
    /// and take a new name.
    var personID: String? = nil
    /// An unnamed group of faces these are the photos of: the heading asks
    /// "Who is this?".
    var clusterID: String? = nil
    /// The place name these are the photos of, so the heading can take a new
    /// name for the place.
    var placeName: String? = nil
}

/// The photos the large map shows. A small map anywhere (on a photo, in a
/// chapter, over the Chapters shelf, in a Library heading) opens the large
/// one with the photos it stood for.
struct MapScope: Equatable {
    var title: String
    /// `nil` for every photo.
    var itemIDs: Set<String>?
}

/// Shared cross-screen state, injected once with `.environment(_:)` on the
/// window and read with `@Environment(SelectionModel.self)`.
///
/// - Library owns `visibleItemIDs` (what its search or scope leaves) and
///   writes it whenever they change; it trims the selection to them.
/// - Any screen may change the selection; `focusedItemID` is the one item the
///   other screens should reveal (fly the map to it, scroll to it).
@MainActor
@Observable
final class SelectionModel {
    /// Media item ids currently selected, in any screen.
    var selectedItemIDs: Set<String> = []
    /// The item to bring into view; `nil` means keep the current viewport.
    var focusedItemID: String?
    /// Ids that pass the Library filters; `nil` means no filter is active.
    var visibleItemIDs: Set<String>? {
        didSet { visibleGeneration &+= 1 }
    }
    /// Changes each time `visibleItemIDs` is assigned. Pages hash this
    /// instead of the whole set.
    private(set) var visibleGeneration = 0
    /// True while a Library filter chip or the search is on. The Library
    /// publishes every photo it shows even then, so other pages narrow to
    /// `visibleItemIDs` only while this is true.
    var libraryFiltersActive = false
    /// The photos the large map and Chapters show: `nil` for all of them.
    var filteredItemIDs: Set<String>? {
        libraryFiltersActive ? visibleItemIDs : nil
    }
    /// A screen asks to switch the sidebar; the window clears it after switching.
    /// Opening Library is a reveal request: the photo in focus is scrolled to.
    var requestedDestination: SidebarDestination? {
        didSet {
            // Going to a page leaves the large map.
            if requestedDestination != nil { mapScope = nil }
            if requestedDestination == .library {
                shouldRevealSelectionInLibrary = true
                // A reveal jump must not land in an older scope that hides
                // the photo; showInLibrary sets its own scope afterwards.
                libraryScope = nil
            }
        }
    }
    /// Library consumes this after its collections have been built so the
    /// focused item wins over the previously remembered scroll anchor.
    var shouldRevealSelectionInLibrary = false
    /// The photo open in the large viewer and the order it pages through.
    var viewerRequest: ViewerRequest?

    func openViewer(_ itemID: String, in itemIDs: [String]) {
        viewerRequest = ViewerRequest(itemIDs: itemIDs.isEmpty ? [itemID] : itemIDs, itemID: itemID)
    }
    /// The trip open on the Trips screen, kept while visiting other screens.
    var openTripID: String?
    /// Where a Shift-click range starts: the last item clicked without Shift.
    var anchorItemID: String?

    /// Set by `showInLibrary`; cleared by the Library's back button.
    var libraryScope: LibraryScope?

    /// Photos whose date and time the window's Adjust Date and Time sheet is open for.
    var dateAdjustmentItemIDs: [String]?
    /// The last correction to dates, places or people, while its Undo bar shows.
    var lastCorrection: CorrectionUndo?

    /// Opens Adjust Date and Time for `itemID`, or for the whole selection
    /// when the photo is part of it, as a context menu in Photos does.
    func adjustDateAndTime(for itemID: String) {
        dateAdjustmentItemIDs = selectedItemIDs.contains(itemID) ? Array(selectedItemIDs) : [itemID]
    }

    init() {}

    /// A click on a photo, the way Photos and Finder grids handle it:
    /// a plain click selects just that photo and a second plain click
    /// deselects it, Command adds or removes one photo, and Shift selects
    /// everything between the anchor and this photo in `order`.
    func click(_ id: String, command: Bool = false, shift: Bool = false, order: [String] = []) {
        if shift {
            if let anchor = anchorItemID ?? focusedItemID,
               let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
                selectedItemIDs.formUnion(order[min(from, to)...max(from, to)])
            } else {
                // No visible anchor: Shift-click adds this photo and starts a new range.
                selectedItemIDs.insert(id)
                anchorItemID = id
            }
            focusedItemID = id
            return
        }
        anchorItemID = id
        if command {
            toggle(id)
        } else if selectedItemIDs == [id] {
            clear()
        } else {
            select(id)
        }
    }

    /// Replaces the selection and reveals `focus` (or the first id).
    func select(_ ids: some Sequence<String>, focus: String? = nil) {
        let set = Set(ids)
        selectedItemIDs = set
        focusedItemID = focus ?? set.sorted().first
    }

    /// Selects one item and makes it the cross-screen focus.
    func select(_ id: String) {
        select([id], focus: id)
    }

    /// Adds or removes one item; focus moves only when the focused item is removed.
    func toggle(_ id: String) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
            if focusedItemID == id { focusedItemID = selectedItemIDs.sorted().first }
        } else {
            selectedItemIDs.insert(id)
            focusedItemID = id
        }
    }

    /// Switches to the Library showing only `ids`, scrolled to the top. With
    /// `personID` or `clusterID` the heading shows that face and its name;
    /// with `placeName` the heading renames the place.
    func showInLibrary(_ ids: some Sequence<String>, title: String, personID: String? = nil, clusterID: String? = nil, placeName: String? = nil) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        viewerRequest = nil
        selectedItemIDs = []
        focusedItemID = nil
        requestedDestination = .library
        libraryScope = LibraryScope(title: title, itemIDs: set, personID: personID, clusterID: clusterID, placeName: placeName)
        // Nothing to reveal: the scoped grid opens at its top.
        shouldRevealSelectionInLibrary = false
    }

    /// The photos the large map is showing; `nil` while it is closed.
    var mapScope: MapScope? {
        didSet { mapScopeGeneration &+= 1 }
    }
    /// Changes each time `mapScope` is assigned, so the map hashes this
    /// instead of the whole set.
    private(set) var mapScopeGeneration = 0

    /// A photo the Map should fly to once it is on screen; the Map only
    /// follows focus changes while it is already showing.
    var mapFocusRequest: String?

    /// Opens the large map on `ids` (every photo when `nil`), closing the viewer.
    func showMap(title: String, itemIDs ids: Set<String>?) {
        viewerRequest = nil
        mapFocusRequest = nil
        mapScope = MapScope(title: title, itemIDs: ids)
    }

    /// Shows one photo on the large map among every photo, closing the viewer.
    func showOnMap(_ itemID: String, title: String) {
        viewerRequest = nil
        select(itemID)
        mapFocusRequest = itemID
        mapScope = MapScope(title: title, itemIDs: nil)
    }

    /// True when the large map shows this photo.
    func isOnMap(_ id: String) -> Bool {
        guard filteredItemIDs?.contains(id) ?? true else { return false }
        return mapScope?.itemIDs?.contains(id) ?? true
    }

    /// Opens a trip on the Trips screen, closing the viewer.
    func showTrip(_ tripID: String) {
        viewerRequest = nil
        openTripID = tripID
        requestedDestination = .trips
    }

    /// Shows the photo in the Library grid, closing the viewer.
    func revealInLibrary(_ itemID: String) {
        viewerRequest = nil
        select(itemID)
        requestedDestination = .library
    }

    func isSelected(_ id: String) -> Bool {
        selectedItemIDs.contains(id)
    }

    func clear() {
        selectedItemIDs = []
        focusedItemID = nil
        anchorItemID = nil
        shouldRevealSelectionInLibrary = false
    }

    /// True when the item passes the Library filters.
    func isVisible(_ id: String) -> Bool {
        visibleItemIDs?.contains(id) ?? true
    }

    // MARK: Deleting

    /// Photos waiting for "Delete from Moments?" to be confirmed; the window shows the alert.
    var pendingDeletion: PendingDeletion?
    /// The last move to Recently Deleted, for the window's Undo bar.
    var lastDeletion: DeletionNotice?

    /// Takes deleted photos out of the selection and the viewer: the viewer
    /// moves on to the next photo, or closes when none is left.
    func forget(deleted ids: Set<String>) {
        selectedItemIDs.subtract(ids)
        if let focused = focusedItemID, ids.contains(focused) { focusedItemID = selectedItemIDs.sorted().first }
        if let anchor = anchorItemID, ids.contains(anchor) { anchorItemID = nil }
        guard let request = viewerRequest, request.itemIDs.contains(where: ids.contains) || ids.contains(request.itemID) else { return }
        let remaining = request.itemIDs.filter { !ids.contains($0) }
        guard !remaining.isEmpty else {
            viewerRequest = nil
            return
        }
        var next = request.itemID
        if ids.contains(request.itemID) {
            let index = request.itemIDs.firstIndex(of: request.itemID) ?? 0
            next = request.itemIDs[index...].first { !ids.contains($0) }
                ?? request.itemIDs[..<index].last { !ids.contains($0) }
                ?? remaining[0]
        }
        viewerRequest = ViewerRequest(itemIDs: remaining, itemID: next)
    }
}

/// Photos someone asked to delete, waiting for the confirmation.
struct PendingDeletion: Equatable {
    /// The photos this person may delete.
    var itemIDs: [String]
    /// Photos in the request that the partner added; they stay.
    var othersCount: Int
}

/// "Moved to Recently Deleted · Undo" after a delete.
struct DeletionNotice: Equatable {
    let id = UUID()
    let itemIDs: [String]
    /// What ⌘Z's registration is filed under, so the bar's Undo can drop it.
    let undoTarget: DeletionUndoTarget

    static func == (lhs: DeletionNotice, rhs: DeletionNotice) -> Bool { lhs.id == rhs.id }
}

final class DeletionUndoTarget {}
