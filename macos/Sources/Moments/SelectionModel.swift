import Observation

/// The small piece of cross-screen selection state shared by the native views.
///
/// `MomentsApp` injects one instance with SwiftUI's environment. Library owns
/// the selection gesture; Places and Timeline can read `selectedItemIDs` and
/// use `focusedItemID` when they need to reveal one item.
@MainActor
@Observable
final class SelectionModel {
    /// Media item ids currently selected across the app.
    var selectedItemIDs: Set<String> = []

    /// The item another screen should bring into view, if any.
    var focusedItemID: String?

    /// Selects one item and makes it the cross-screen focus.
    func select(_ id: String) {
        selectedItemIDs = [id]
        focusedItemID = id
    }

    /// Replaces the selection and focuses the supplied item, or the first id.
    func select(_ ids: some Sequence<String>, focus: String? = nil) {
        let set = Set(ids)
        selectedItemIDs = set
        focusedItemID = focus ?? set.sorted().first
    }

    /// Adds or removes one item without changing the current focus unless it is removed.
    func toggle(_ id: String) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
            if focusedItemID == id { focusedItemID = selectedItemIDs.sorted().first }
        } else {
            selectedItemIDs.insert(id)
            focusedItemID = id
        }
    }

    /// Clears all selected and focused items.
    func clear() {
        selectedItemIDs.removeAll()
        focusedItemID = nil
    }

    func isSelected(_ id: String) -> Bool {
        selectedItemIDs.contains(id)
    }
}
