import Foundation

/// Something the other person wrote that this device is seeing for the
/// first time: a new memory, a comment on one of this person's memories, or
/// a reply to one of this person's comments. The app turns these into Mac
/// notifications (issue #28); edits to text already here never are one.
public struct SyncArrival: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// The other person wrote a new memory.
        case memory
        /// The other person commented on this person's memory.
        case comment
        /// The other person replied to this person's comment.
        case reply
    }

    public let kind: Kind
    public let recordID: String
    /// The memory the arrival belongs to (the memory itself for `.memory`).
    public let memoryID: String?
    /// The words, trimmed.
    public let text: String

    public init(kind: Kind, recordID: String, memoryID: String?, text: String) {
        self.kind = kind
        self.recordID = recordID
        self.memoryID = memoryID
        self.text = text
    }
}

/// How the arrivals of one fetch are announced: one notice each while there
/// are few, one summary when many came at once, so a long offline stretch
/// never fills the screen.
public enum SyncArrivalNotices {
    public static let individualLimit = 3

    public enum Notice: Equatable, Sendable {
        case single(SyncArrival)
        case summary(count: Int)
    }

    public static func notices(for arrivals: [SyncArrival]) -> [Notice] {
        var seen = Set<String>()
        let unique = arrivals.filter { seen.insert($0.recordID).inserted }
        guard !unique.isEmpty else { return [] }
        if unique.count > individualLimit { return [.summary(count: unique.count)] }
        return unique.map(Notice.single)
    }

    /// Decides whether a record from the server is an arrival. `known` tells
    /// whether this device already had it (a server version or a local copy);
    /// `author` looks up who wrote a memory or comment already on this device.
    static func arrival(
        of record: SyncRecord,
        known: Bool,
        accounts: SyncAccountMap,
        author: (SyncRecordKey) -> String??
    ) -> SyncArrival? {
        guard !known, record.type == .memory || record.type == .comment else { return nil }
        guard accounts.role(of: record.fields["authorAccountID"]?.stringValue) == .partner else { return nil }
        let text = (record.fields["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if record.type == .memory {
            return SyncArrival(kind: .memory, recordID: record.id, memoryID: record.id, text: text)
        }
        let memoryID = record.fields["memoryID"]?.stringValue
        let kind: SyncArrival.Kind
        let about: SyncRecordKey
        if let parent = record.fields["parentCommentID"]?.stringValue {
            kind = .reply
            about = SyncRecordKey(.comment, parent)
        } else if let memoryID {
            kind = .comment
            about = SyncRecordKey(.memory, memoryID)
        } else {
            return nil
        }
        // Only words aimed at this person: their memory, their comment. An
        // unknown parent (not here yet) stays quiet.
        guard let found = author(about), accounts.role(of: found) == .me else { return nil }
        return SyncArrival(kind: kind, recordID: record.id, memoryID: memoryID, text: text)
    }
}
