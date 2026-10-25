import Observation

/// Sidebar destinations other screens can ask the window to switch to.
enum SidebarDestination: Hashable {
    case library
    case places
    case footprints
    case timeline
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
    var requestedDestination: SidebarDestination?

    init() {}

    /// Replaces the selection and reveals `focus` (or the first id).
    func select(_ ids: some Sequence<String>, focus: String? = nil) {
        let set = Set(ids)
        selectedItemIDs = set
        focusedItemID = focus ?? set.sorted().first
    }

    func clear() {
        selectedItemIDs = []
        focusedItemID = nil
    }

    /// True when the item passes the Library filters.
    func isVisible(_ id: String) -> Bool {
        visibleItemIDs?.contains(id) ?? true
    }
}
