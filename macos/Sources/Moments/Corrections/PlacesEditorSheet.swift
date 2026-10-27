import SwiftData
import SwiftUI

/// Rename or merge places, opened from the Place filter (Library and Map).
/// A rename gives every place and photo listed under a name a new one;
/// merging gives the selected places one name, so the filters and the Map
/// show them as one. Only this person's names change, and Undo takes it back.
struct PlacesEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SelectionModel.self) private var selection
    @Query private var items: [MediaItem]
    @AppStorage(LibraryFilterKeys.place) private var placeFilterID = ""

    @State private var search = ""
    @State private var checked: Set<String> = []
    @State private var renamingKey: String?
    @State private var renameText = ""
    /// The last change made here; the window's Undo bar is behind the sheet.
    @State private var lastCorrection: CorrectionUndo?
    @FocusState private var isRenaming: Bool

    private var groups: [PlaceNames.Group] { PlaceNames.groups(for: items) }

    private var shownGroups: [PlaceNames.Group] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(query) || checked.contains($0.key) }
    }

    private var checkedGroups: [PlaceNames.Group] { groups.filter { checked.contains($0.key) } }

    var body: some View {
        PaperSheet(
            String(localized: "Places"),
            subtitle: String(localized: "Rename a place, or tick places that are the same and merge them. Places with the same name are one place in the filters and on the map.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(String(localized: "Search places"), text: $search)
                    .textFieldStyle(.paper)
                    .accessibilityIdentifier("places.editor.search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shownGroups) { group in row(group) }
                    }
                }
                .paperWell(padding: 4)
                .frame(minHeight: 180, maxHeight: .infinity)
            }
        } footer: {
            if let correction = lastCorrection, !correction.isDone {
                HStack(spacing: 8) {
                    Text(correction.message)
                        .font(.callout)
                        .foregroundStyle(Paper.muted)
                        .lineLimit(1)
                    Button(String(localized: "Undo")) {
                        correction.perform(in: modelContext)
                        if selection.lastCorrection === correction { selection.lastCorrection = nil }
                        lastCorrection = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Paper.accent)
                    .accessibilityIdentifier("places.editor.undo")
                }
                Spacer(minLength: 0)
            }
            if checkedGroups.count >= 2 {
                Menu {
                    Section(String(localized: "Keep the name")) {
                        ForEach(checkedGroups) { target in
                            Button(target.name) { merge(into: target) }
                        }
                    }
                } label: {
                    Text(String(localized: "Merge \(checkedGroups.count) Places"))
                }
                .fixedSize()
                .accessibilityIdentifier("places.editor.merge")
            }
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("places.editor.done")
        }
        .frame(width: 440, height: 520)
    }

    private func row(_ group: PlaceNames.Group) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { checked.contains(group.key) },
                set: { isOn in if isOn { checked.insert(group.key) } else { checked.remove(group.key) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(group.name)
            .accessibilityIdentifier("places.editor.check.\(group.key)")

            if renamingKey == group.key {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Paper.ink)
                    .focused($isRenaming)
                    .onAppear { DispatchQueue.main.async { isRenaming = true } }
                    .onSubmit { commitRename(group) }
                    .onExitCommand { renamingKey = nil }
                    .onChange(of: isRenaming) { _, focused in
                        if !focused, renamingKey == group.key { commitRename(group) }
                    }
                    .accessibilityIdentifier("places.editor.name-field")
            } else {
                Text(group.name)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { startRename(group) }
            }
            Spacer(minLength: 8)
            Text(String(localized: "\(group.itemIDs.count) photos"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Paper.muted)
            Button { startRename(group) } label: {
                Image(systemName: "pencil")
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Paper.muted)
            .help(String(localized: "Rename"))
            .accessibilityLabel(String(localized: "Rename"))
            .accessibilityIdentifier("places.editor.rename.\(group.key)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(checked.contains(group.key) ? Paper.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("places.editor.row.\(group.key)")
    }

    private func startRename(_ group: PlaceNames.Group) {
        renameText = group.name
        renamingKey = group.key
    }

    private func commitRename(_ group: PlaceNames.Group) {
        guard renamingKey == group.key else { return }
        renamingKey = nil
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != group.name else { return }
        let changes = PlaceNames.rename(key: group.key, to: value, items: items, context: modelContext)
        record(changes, message: String(localized: "Renamed “\(group.name)” to “\(value)”"), moving: [group.key], to: PlaceNames.key(value))
    }

    private func merge(into target: PlaceNames.Group) {
        let sources = checkedGroups.map(\.key).filter { $0 != target.key }
        let changes = PlaceNames.merge(sources, into: target.key, items: items, context: modelContext)
        checked = []
        record(changes, message: String(localized: "Merged \(sources.count + 1) places into “\(target.name)”"), moving: sources, to: target.key)
    }

    private func record(_ changes: PlaceNames.Changes, message: String, moving oldKeys: [String], to newKey: String) {
        guard !changes.isEmpty else { return }
        try? modelContext.save()
        // A filter on a name that just went away follows it to the new one,
        // and back again on Undo.
        let previousFilter = placeFilterID
        let movedFilter: String? = oldKeys.contains(where: { PlaceNames.optionPrefix + $0 == placeFilterID })
            ? PlaceNames.optionPrefix + newKey
            : nil
        if let movedFilter { placeFilterID = movedFilter }
        let correction = CorrectionUndo(
            message: message,
            actionName: String(localized: "Rename Place"),
            restore: { context in
                PlaceNames.restore(changes, context: context)
                let defaults = UserDefaults.standard
                if let movedFilter, defaults.string(forKey: LibraryFilterKeys.place) == movedFilter {
                    defaults.set(previousFilter, forKey: LibraryFilterKeys.place)
                }
            }
        )
        lastCorrection = correction
        selection.recordCorrection(correction, context: modelContext)
    }
}
