import Observation

/// Sidebar destinations other screens can ask the window to switch to.
enum SidebarDestination: Hashable {
    case library
    case places
    case footprints
    case timeline
    case trips
}

/// A request to show photos in the large viewer, with the order to page through.
struct ViewerRequest: Equatable {
    var itemIDs: [String]
    var itemID: String
}

/// Photos another screen asked the Library to show on their own, such as one
/// city from Footprints. It narrows only the Library grid (shown there as a
/// removable chip); the maps keep following the regular Library filters.
struct LibraryScope: Equatable {
    var title: String
    var itemIDs: Set<String>
}

/// Shared cross-screen state, injected once with `.environment(_:)` on the
/// window and read with `@Environment(SelectionModel.self)`.
///
/// - Library owns `visibleItemIDs` (the result of its filters) and writes it
///   whenever filters change; Places and Timeline only read it.
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
    var visibleItemIDs: Set<String>?
    /// A screen asks to switch the sidebar; the window clears it after switching.
    /// Opening Library is a reveal request because it is used by Timeline's
    /// place jump action.
    var requestedDestination: SidebarDestination? {
        didSet {
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

    /// Set by `showInLibrary`; cleared from the Library's chip.
    var libraryScope: LibraryScope?

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

    /// Switches to the Library showing only `ids`, scrolled to the top.
    func showInLibrary(_ ids: some Sequence<String>, title: String) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        selectedItemIDs = []
        focusedItemID = nil
        requestedDestination = .library
        libraryScope = LibraryScope(title: title, itemIDs: set)
        // Nothing to reveal: the scoped grid opens at its top.
        shouldRevealSelectionInLibrary = false
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
}
