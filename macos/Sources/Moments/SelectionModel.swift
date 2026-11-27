import Foundation
import Observation

/// The window's pages: the sidebar destinations other screens can ask the
/// window to switch to.
enum SidebarDestination: Hashable {
    case library
    case trips
    case recentlyDeleted
}

/// Where the window was before a jump to another page or level: the page,
/// what it showed, the large map and the photo open in the viewer. The
/// window's back button returns to it.
struct NavigationStop: Equatable {
    var page: SidebarDestination
    var libraryScope: LibraryScope?
    var openTripID: String?
    var mapScope: MapScope?
    /// The photo whose place the large map had open, so the map comes back
    /// at that place with its photos.
    var mapItemID: String?
    var viewerRequest: ViewerRequest?
}

/// A request to show photos in the large viewer, with the order to page through.
struct ViewerRequest: Equatable {
    var itemIDs: [String]
    var itemID: String

    /// The same request once `ids` are deleted: the open photo moves on to
    /// the next one left (or the one before); `nil` when none is left.
    func without(_ ids: Set<String>) -> ViewerRequest? {
        guard itemIDs.contains(where: ids.contains) || ids.contains(itemID) else { return self }
        let remaining = itemIDs.filter { !ids.contains($0) }
        guard !remaining.isEmpty else { return nil }
        var next = itemID
        if ids.contains(itemID) {
            let index = itemIDs.firstIndex(of: itemID) ?? 0
            next = itemIDs[index...].first { !ids.contains($0) }
                ?? itemIDs[..<index].last { !ids.contains($0) }
                ?? remaining[0]
        }
        return ViewerRequest(itemIDs: remaining, itemID: next)
    }
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
    /// with `placeName` the heading renames the place. `replacing` is for the
    /// same photos under a new name (a rename or a merge in the heading):
    /// Back then skips the old name instead of returning to it.
    func showInLibrary(_ ids: some Sequence<String>, title: String, personID: String? = nil, clusterID: String? = nil, placeName: String? = nil, replacing: Bool = false) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        if !replacing { rememberCurrentStop() }
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
        didSet {
            mapScopeGeneration &+= 1
            if mapScope == nil { mapOpenPlaceItemID = nil }
        }
    }
    /// Changes each time `mapScope` is assigned, so the map hashes this
    /// instead of the whole set.
    private(set) var mapScopeGeneration = 0

    /// A photo the Map should fly to once it is on screen; the Map only
    /// follows focus changes while it is already showing.
    var mapFocusRequest: String?
    /// A photo of the place the large map has open (its strip of photos),
    /// kept by the map; `nil` while no place is open.
    var mapOpenPlaceItemID: String?

    /// Opens the large map on `ids` (every photo when `nil`), closing the viewer.
    func showMap(title: String, itemIDs ids: Set<String>?) {
        rememberCurrentStop()
        viewerRequest = nil
        mapFocusRequest = nil
        mapOpenPlaceItemID = nil
        mapScope = MapScope(title: title, itemIDs: ids)
    }

    /// Shows one photo on the large map among every photo, closing the viewer.
    func showOnMap(_ itemID: String, title: String) {
        rememberCurrentStop()
        viewerRequest = nil
        select(itemID)
        mapOpenPlaceItemID = nil
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
        rememberCurrentStop()
        viewerRequest = nil
        openTripID = tripID
        requestedDestination = .trips
    }

    /// Shows the photo in the Library grid, closing the viewer.
    func revealInLibrary(_ itemID: String) {
        rememberCurrentStop()
        viewerRequest = nil
        select(itemID)
        requestedDestination = .library
    }

    // MARK: Going back

    /// The page the window shows; the window keeps it current.
    var page: SidebarDestination = .library
    /// Where each jump came from, oldest first. A click in the sidebar starts
    /// over; the back button returns to the newest.
    private(set) var backStack: [NavigationStop] = []
    /// Enough for any way through the app, without holding on to scopes of
    /// thousands of photos forever.
    static let backStackLimit = 30

    /// Where the window is now.
    var currentStop: NavigationStop {
        NavigationStop(
            page: page,
            libraryScope: libraryScope,
            openTripID: openTripID,
            mapScope: mapScope,
            mapItemID: mapScope == nil ? nil : mapOpenPlaceItemID,
            viewerRequest: viewerRequest
        )
    }

    /// Called by every jump to another page or level before it changes anything.
    private func rememberCurrentStop() {
        let here = currentStop
        guard backStack.last != here else { return }
        backStack.append(here)
        if backStack.count > Self.backStackLimit {
            backStack.removeFirst(backStack.count - Self.backStackLimit)
        }
    }

    /// A click in the sidebar: a fresh start, nothing to go back to.
    func forgetBackHistory() {
        backStack = []
    }

    /// One level up from `stop`, for a page opened without a jump (a chapter
    /// clicked on the shelf, a person's photos after the history was cleared):
    /// the large map closes, a person's or place's photos give way to all of
    /// them, a chapter to the shelf.
    private static func levelUp(from stop: NavigationStop) -> NavigationStop? {
        var up = stop
        up.viewerRequest = nil
        if up.mapScope != nil {
            up.mapScope = nil
            up.mapItemID = nil
        } else if up.page == .library, up.libraryScope != nil {
            up.libraryScope = nil
        } else if up.page == .trips, up.openTripID != nil {
            up.openTripID = nil
        } else {
            return nil
        }
        return up
    }

    /// Where the back button leads: where the last jump came from, else one
    /// level up. `nil` on a page's top level with nothing to go back to.
    var backTarget: NavigationStop? {
        let here = currentStop
        if let stop = backStack.last(where: { (stop: NavigationStop) -> Bool in stop != here }) { return stop }
        return Self.levelUp(from: here)
    }

    /// The back button and ⌘[. The open photo closes first; then the window
    /// returns to `backTarget`. Returns the page to show.
    @discardableResult
    func goBack() -> SidebarDestination {
        if viewerRequest != nil {
            viewerRequest = nil
            return page
        }
        let here = currentStop
        while let last = backStack.last, last == here { backStack.removeLast() }
        guard let target = backStack.popLast() ?? Self.levelUp(from: here) else { return page }
        restore(target)
        return target.page
    }

    private func restore(_ stop: NavigationStop) {
        viewerRequest = nil
        libraryScope = stop.libraryScope
        openTripID = stop.openTripID
        mapOpenPlaceItemID = nil
        mapScope = stop.mapScope
        // The map opens again at the place it had open. The photo is
        // selected too, as "Show on Map" does: the map keeps a place open
        // through a zoom only while one of its photos is selected.
        mapFocusRequest = stop.mapScope == nil ? nil : stop.mapItemID
        if stop.mapScope != nil, let itemID = stop.mapItemID { select(itemID) }
        page = stop.page
        viewerRequest = stop.viewerRequest
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
        if let request = viewerRequest {
            let next = request.without(ids)
            if next != request { viewerRequest = next }
        }
        // A photo the back button would reopen is gone too.
        for index in backStack.indices {
            if let request = backStack[index].viewerRequest {
                backStack[index].viewerRequest = request.without(ids)
            }
        }
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
