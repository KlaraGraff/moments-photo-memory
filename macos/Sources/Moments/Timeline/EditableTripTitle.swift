import SwiftUI
import SwiftData

/// A trip's name that turns into a field on double-click, like a Finder
/// name: Return or clicking elsewhere saves, Escape cancels. The typed name
/// goes into `overrideName`, so the default name is kept underneath and an
/// emptied field goes back to it.
struct EditableTripTitle: View {
    @Environment(\.modelContext) private var modelContext
    let tripID: String
    let title: String
    var font: Font = .system(size: 21, weight: .medium, design: .serif)
    /// A single click; it waits until the click cannot become a double-click,
    /// so starting a rename never runs it.
    var onClick: (() -> Void)? = nil
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(Paper.ink)
                .focused($isFocused)
                .frame(minWidth: 180)
                .fixedSize()
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Paper.muted.opacity(0.7))
                        .frame(height: 1.5)
                }
                // The field appears first, then takes focus.
                .onAppear { DispatchQueue.main.async { isFocused = true } }
                .onSubmit { commit() }
                .onExitCommand { isEditing = false }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .accessibilityIdentifier("trip.rename.\(tripID)")
        } else {
            Text(title)
                .font(font)
                .foregroundStyle(Paper.ink)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    draft = title
                    isEditing = true
                }
                .onTapGesture(count: 1) { onClick?() }
                .help(String(localized: "Double-click to rename"))
                .accessibilityIdentifier("trip.title.\(tripID)")
                .accessibilityAction(named: Text(String(localized: "Rename"))) {
                    draft = title
                    isEditing = true
                }
        }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != title else { return }
        let id = tripID
        guard let trip = try? modelContext.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first else { return }
        TripRenaming.rename(trip, to: value, context: modelContext)
    }
}

enum TripRenaming {
    /// An empty name goes back to the trip's default name.
    @MainActor
    static func rename(_ trip: Trip, to name: String, context: ModelContext) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.overrideName = value.isEmpty || value == trip.name ? nil : value
        trip.updatedAt = .now
        try? context.save()
    }
}
