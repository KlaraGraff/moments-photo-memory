import Foundation
import MomentsCore
import UserNotifications

/// Mac notifications for what the other person wrote (issue #28): a new
/// memory, a comment on this person's memory, a reply to this person's
/// comment. Edits, words from this person's other Mac and the first download
/// of a share never notify (`SyncArrivalNotices`, `CloudSyncEngine`).
/// They are on by default; System Settings › Notifications turns them off,
/// so the app has no switch of its own.
@MainActor
enum PartnerNotifier {
    /// Notifications longer than this are cut with an ellipsis.
    static let bodyLimit = 140

    struct Content: Equatable {
        var title: String
        var body: String
        /// The memory a click should open, when there is one.
        var memoryID: String?
    }

    /// What each notice says. `partner` is the other person's label from
    /// Settings, or "Partner".
    static func content(for notice: SyncArrivalNotices.Notice, partner: String) -> Content {
        switch notice {
        case .summary(let count):
            return Content(
                title: String(localized: "\(partner) wrote \(count) memories and comments"),
                body: String(localized: "Open Moments to see them."),
                memoryID: nil
            )
        case .single(let arrival):
            let title: String
            switch arrival.kind {
            case .memory: title = String(localized: "\(partner) wrote a memory")
            case .comment: title = String(localized: "\(partner) commented on your memory")
            case .reply: title = String(localized: "\(partner) replied to you")
            }
            return Content(title: title, body: shortened(arrival.text), memoryID: arrival.memoryID)
        }
    }

    static func shortened(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > bodyLimit else { return flat }
        return String(flat.prefix(bodyLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Posts the arrivals of one fetch, asking for permission the first time.
    static func post(_ arrivals: [SyncArrival], defaults: UserDefaults = .standard) {
        let notices = SyncArrivalNotices.notices(for: arrivals)
        guard !notices.isEmpty else { return }
        let partner = AuthorNames.label(isOwn: false, defaults: defaults)
        let contents = notices.map { content(for: $0, partner: partner) }
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            for content in contents {
                let note = UNMutableNotificationContent()
                note.title = content.title
                note.body = content.body
                note.sound = .default
                if let memoryID = content.memoryID { note.userInfo = ["memoryID": memoryID] }
                note.threadIdentifier = "moments.partner"
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: note, trigger: nil))
            }
        }
    }
}
