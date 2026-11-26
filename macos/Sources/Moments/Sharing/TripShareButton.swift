import CloudKit
import SwiftUI

/// The visible "Share" button in a trip's toolbar. Before anything is shared
/// it opens Settings > Sharing with this trip already chosen; once sharing is
/// set up it adds the trip, or offers to stop sharing it.
struct TripShareButton: View {
    let tripID: String
    let tripName: String
    @Environment(SharingController.self) private var sharing
    @Environment(\.openSettings) private var openSettings
    @State private var confirmStop = false

    var body: some View {
        Group {
            if sharing.isShared(tripID: tripID) {
                Menu {
                    Button(String(localized: "Stop sharing…"), role: .destructive) { confirmStop = true }
                        .accessibilityIdentifier("trips.share.stop")
                } label: {
                    Label(String(localized: "Shared"), systemImage: "person.2.fill")
                }
                .help(String(localized: "Shared with your partner"))
            } else {
                Button {
                    share()
                } label: {
                    Label(String(localized: "Share"), systemImage: "person.2")
                }
                .help(String(localized: "Share this trip with your partner"))
            }
        }
        .accessibilityIdentifier("trips.share")
        .confirmationDialog(String(localized: "Stop sharing “\(tripName)” with your partner?"), isPresented: $confirmStop) {
            Button(String(localized: "Stop sharing this trip"), role: .destructive) {
                sharing.setTrip(tripID, shared: false)
            }
        } message: {
            Text(String(localized: "Your partner will no longer see this trip's photos and memories. What your partner wrote stays on this Mac, and nothing of yours is deleted. You can share it again later."))
        }
    }

    private func share() {
        switch sharing.phase {
        case .invited, .shared(isOwner: true):
            sharing.setTrip(tripID, shared: true)
        default:
            sharing.preselect(tripID: tripID)
            openSettings()
        }
    }
}

/// The small "Shared" mark on a shared trip's cover.
struct SharedTripBadge: View {
    var body: some View {
        Label(String(localized: "Shared"), systemImage: "person.2.fill")
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Paper.raised.opacity(0.92)))
            .foregroundStyle(Paper.ink)
            .accessibilityIdentifier("trips.shared-badge")
    }
}

/// The app delegate in every build. macOS hands it the invitation when the
/// partner opens a share link; the debug unit-test host subclasses it.
class MomentsAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in
            if let sharing = SharingController.current {
                await sharing.accept(metadata)
            } else {
                // Opened from the link before the main window was ready.
                SharingController.pendingInvitation = metadata
            }
        }
    }
}
