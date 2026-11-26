import AppKit
import CloudKit
import SwiftData
import SwiftUI

/// Settings > Sharing: invite the other person, choose which trips are
/// shared, see how syncing is going, and stop sharing. Follows the approved
/// mock-up (handoff/sharing-mock-2026-11-26.html).
struct SharingSettingsPage: View {
    @Environment(SharingController.self) private var sharing
    /// Without a library there is nothing to share (and no store to query).
    var hasStore = true

    var body: some View {
        Group {
            switch hasStore ? sharing.phase : .unavailable {
            case .unavailable:
                SharingMessage(
                    symbol: "icloud.slash",
                    title: String(localized: "Sharing isn't available in this copy"),
                    detail: String(localized: "This copy of Moments is not signed for iCloud. Install the signed version to share with your partner.")
                )
            case .checking:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SharingMessage(
                    symbol: "icloud",
                    title: String(localized: "Sign in to iCloud first"),
                    detail: String(localized: "Shared memories are kept in your own iCloud, and only the two of you can see them. Sign in under System Settings > Apple Account, then come back here."),
                    action: (String(localized: "Open System Settings"), {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                            NSWorkspace.shared.open(url)
                        }
                    })
                )
            case .notShared, .invited, .shared:
                // Only reached with a store: the controller is configured
                // with the app's model container.
                SharingLibraryPage()
            }
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .background(Paper.canvas)
        .tint(Paper.accent)
        .accessibilityIdentifier("settings.sharing")
    }
}

/// A centered message for the states without a library page.
private struct SharingMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(Paper.accent)
            Text(title)
                .font(.system(.title3, design: .serif).weight(.medium))
                .foregroundStyle(Paper.ink)
            Text(detail)
                .font(.callout)
                .foregroundStyle(Paper.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let action {
                Button(action.0, action: action.1).padding(.top, 6)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The pages that list trips: invite, owner and partner.
private struct SharingLibraryPage: View {
    @Environment(SharingController.self) private var sharing
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]
    @State private var chosen: Set<String> = []
    @State private var isInviting = false
    @State private var showingAddTrips = false
    @State private var tripToUnshare: Trip?
    @State private var confirmStop = false
    @State private var confirmLeave = false
    @State private var anchor = SharingPickerAnchor.Holder()

    var body: some View {
        Group {
            switch sharing.phase {
            case .notShared:
                invitePage
            case .invited:
                ownerPage(waiting: true)
            case .shared(let isOwner):
                if isOwner { ownerPage(waiting: false) } else { partnerPage }
            default:
                EmptyView()
            }
        }
        .onAppear { chosen.formUnion(sharing.preselectedTripIDs) }
        .sheet(isPresented: $showingAddTrips) { addTripsSheet }
        .confirmationDialog(unshareTitle, isPresented: Binding(get: { tripToUnshare != nil }, set: { if !$0 { tripToUnshare = nil } })) {
            Button(String(localized: "Stop sharing this trip"), role: .destructive) {
                if let trip = tripToUnshare { sharing.setTrip(trip.id, shared: false) }
                tripToUnshare = nil
            }
        } message: {
            Text(String(localized: "Your partner will no longer see this trip's photos and memories. What your partner wrote stays on this Mac, and nothing of yours is deleted. You can share it again later."))
        }
        .confirmationDialog(String(localized: "Stop sharing with your partner?"), isPresented: $confirmStop) {
            Button(String(localized: "Stop sharing"), role: .destructive) { Task { await sharing.stopSharing() } }
        } message: {
            Text(String(localized: "Your partner is removed and every shared trip disappears on their Mac. What they wrote stays on this Mac, and your photos and memories are not deleted. To record together again, send a new invitation."))
        }
        .confirmationDialog(String(localized: "Leave the share?"), isPresented: $confirmLeave) {
            Button(String(localized: "Leave"), role: .destructive) { Task { await sharing.leave() } }
        } message: {
            Text(String(localized: "The shared trips disappear from this Mac. What you wrote has already been synced and stays with your partner. To join again, ask for a new invitation."))
        }
    }

    // MARK: Pages

    private var invitePage: some View {
        Form {
            Section {
                Text(String(localized: "Choose the trips to share, then invite your partner. Once they join, they can see these trips' photos and memories and keep writing. Trips you don't choose stay on this Mac. Originals are never uploaded, only a smaller preview."))
                    .font(.callout)
                    .foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(String(localized: "Record together"))
            }
            Section {
                tripChecklist
            } header: {
                Text(String(localized: "Trips to share")) + Text(verbatim: " · ") + Text(String(localized: "\(chosen.count) chosen"))
            } footer: {
                HStack {
                    Text(String(localized: "You can add more from a trip later."))
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                    Spacer()
                    inviteButton(title: String(localized: "Invite your partner…"))
                        .disabled(chosen.isEmpty || isInviting)
                }
            }
            errorSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func ownerPage(waiting: Bool) -> some View {
        Form {
            Section(String(localized: "Recording together with")) {
                HStack(spacing: 10) {
                    avatar(waiting ? "?" : String(partnerName.prefix(1)), color: Paper.partner)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(waiting ? String(localized: "Invitation sent") : partnerName)
                        Text(waiting
                             ? String(localized: "Your partner joins by opening the link on their Mac, in Moments.")
                             : joinedDetail)
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                    Spacer()
                    pill(waiting ? String(localized: "Waiting") : String(localized: "Joined"), positive: !waiting)
                }
                if waiting {
                    HStack(spacing: 14) {
                        inviteButton(title: String(localized: "Send the invitation again…"))
                        Button(String(localized: "Withdraw invitation"), role: .destructive) { confirmStop = true }
                            .buttonStyle(.link)
                    }
                }
            }
            syncSection(allowSyncNow: true)
            Section {
                ForEach(sharedTrips) { trip in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trip.effectiveName)
                            Text(tripDetail(trip)).font(.caption).foregroundStyle(Paper.muted)
                        }
                        Spacer()
                        Button(String(localized: "Stop sharing…")) { tripToUnshare = trip }
                            .buttonStyle(.link)
                    }
                }
            } header: {
                Text(String(localized: "Shared trips")) + Text(verbatim: " · \(sharedTrips.count)")
            } footer: {
                HStack {
                    Button(String(localized: "Add trips…")) {
                        chosen = sharing.sharedTripIDs
                        showingAddTrips = true
                    }
                    Spacer()
                    Button(String(localized: "Stop sharing"), role: .destructive) { confirmStop = true }
                        .buttonStyle(.link)
                }
            }
            errorSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var partnerPage: some View {
        Form {
            Section(String(localized: "Recording together with")) {
                HStack(spacing: 10) {
                    avatar(String(partnerName.prefix(1)), color: Paper.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "\(partnerName) shares \(receivedTrips.count) trips with you"))
                        Text(String(localized: "You can look at the photos, write your own memories, keep favorites and rename places. Memories someone else wrote are read-only."))
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    pill(String(localized: "Joined"), positive: true)
                }
            }
            syncSection(allowSyncNow: false)
            Section {
                ForEach(receivedTrips) { trip in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trip.effectiveName)
                        Text(String(localized: "\(trip.items.count) photos · previews")).font(.caption).foregroundStyle(Paper.muted)
                    }
                }
            } header: {
                Text(String(localized: "Trips you received"))
            } footer: {
                HStack {
                    Text(String(localized: "The originals are on your partner's Mac; here you see smaller previews."))
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                    Spacer()
                    Button(String(localized: "Leave"), role: .destructive) { confirmLeave = true }
                        .buttonStyle(.link)
                }
            }
            errorSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var addTripsSheet: some View {
        PaperSheet(String(localized: "Trips to share")) {
            ScrollView { tripChecklist.padding(.vertical, 4) }
                .frame(minHeight: 240, maxHeight: 360)
        } footer: {
            Button(String(localized: "Cancel")) { showingAddTrips = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Share")) {
                for trip in trips where chosen.contains(trip.id) != sharing.isShared(tripID: trip.id) {
                    sharing.setTrip(trip.id, shared: chosen.contains(trip.id))
                }
                showingAddTrips = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(width: 460)
    }

    // MARK: Pieces

    private var tripChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ownTrips) { trip in
                Toggle(isOn: Binding(
                    get: { chosen.contains(trip.id) },
                    set: { on in if on { chosen.insert(trip.id) } else { chosen.remove(trip.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(trip.effectiveName)
                        Text(tripDateLine(trip)).font(.caption).foregroundStyle(Paper.muted)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("sharing.trip.\(trip.id)")
            }
        }
    }

    private func syncSection(allowSyncNow: Bool) -> some View {
        Section(String(localized: "Sync")) {
            HStack(spacing: 8) {
                Circle()
                    .fill(sharing.sync.lastError == nil ? Paper.positive : Paper.accent)
                    .frame(width: 7, height: 7)
                Text(syncLine)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if sharing.sync.isSyncing {
                    ProgressView().controlSize(.small)
                } else if allowSyncNow {
                    Button(String(localized: "Sync now")) { sharing.scheduleSync(after: 0) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = sharing.lastError {
            Section {
                Text(error).font(.caption).foregroundStyle(Paper.accent)
            }
        }
    }

    private func inviteButton(title: String) -> some View {
        Button(title) {
            isInviting = true
            Task {
                defer { isInviting = false }
                guard let share = try? await sharing.makeShare(tripIDs: chosen.isEmpty ? sharing.sharedTripIDs : chosen),
                      let item = sharing.invitationItem(for: share),
                      let view = anchor.view else { return }
                NSSharingServicePicker(items: [item]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
        }
        .buttonStyle(.borderedProminent)
        .background(SharingPickerAnchor(holder: anchor))
        .accessibilityIdentifier("sharing.invite")
    }

    private func avatar(_ letter: String, color: Color) -> some View {
        Text(letter)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(color))
    }

    private func pill(_ text: String, positive: Bool) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(positive ? Paper.positive : Paper.accent)
            .background(Capsule().fill(Paper.well))
    }

    // MARK: Data

    /// Trips made on this Mac (a received trip cannot be shared onward).
    private var ownTrips: [Trip] {
        trips.filter { trip in !trip.isSuggestion && !trip.items.isEmpty && !trip.items.allSatisfy { $0.sourceRaw == SyncModelCoding.sharedSourceRaw } }
    }

    private var sharedTrips: [Trip] {
        trips.filter { sharing.isShared(tripID: $0.id) }
    }

    private var receivedTrips: [Trip] {
        trips.filter { trip in trip.items.contains { $0.sourceRaw == SyncModelCoding.sharedSourceRaw } }
    }

    private var partnerName: String {
        let saved = UserDefaults.standard.string(forKey: "moments.people.partnerName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved! : String(localized: "Your partner")
    }

    private var joinedDetail: String {
        let count = sharedTrips.reduce(0) { total, trip in
            total + trip.items.reduce(0) { $0 + $1.memories.filter { $0.author == .partner }.count }
        }
        return String(localized: "Has written \(count) memories")
    }

    private var syncLine: String {
        if let error = sharing.sync.lastError { return error }
        if sharing.sync.pendingCount > 0 {
            return String(localized: "\(sharing.sync.pendingCount) changes waiting to be sent")
        }
        if let last = sharing.sync.lastSync {
            return String(localized: "Up to date · \(last.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Waiting for the first sync")
    }

    private var unshareTitle: String {
        String(localized: "Stop sharing “\(tripToUnshare?.effectiveName ?? "")” with your partner?")
    }

    private func tripDateLine(_ trip: Trip) -> String {
        let photos = String(localized: "\(trip.items.count) photos")
        guard let start = trip.startDate else { return photos }
        let range = trip.endDate.map { (start...max(start, $0)).formatted(.interval.month(.abbreviated).day()) }
            ?? start.formatted(.dateTime.month(.abbreviated).day())
        return range + " · " + photos
    }

    private func tripDetail(_ trip: Trip) -> String {
        let memories = trip.items.flatMap(\.memories)
        let mine = memories.filter { $0.author == .me }.count
        let theirs = memories.count - mine
        return String(localized: "\(trip.items.count) photos · you \(mine) memories, your partner \(theirs)")
    }
}

/// An invisible view that the system sharing panel opens from.
struct SharingPickerAnchor: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

extension Paper {
    /// The partner's colour on avatars (a muted plum next to terracotta).
    static let partner = Color(red: 0.541, green: 0.353, blue: 0.549)
    /// Up to date, joined.
    static let positive = Color(red: 0.365, green: 0.478, blue: 0.310)
}
