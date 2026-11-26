import Foundation

/// The outcome of merging this device's version of a record with the one
/// CloudKit already holds (a `serverRecordChanged` conflict).
public struct SyncMergeResult: Equatable, Sendable {
    /// What both devices should end up with. Save it locally.
    public var merged: SyncRecord
    /// Words that lost a conflict, kept as ``SyncRecordType/memoryRevision``
    /// records so nothing a person wrote disappears. Save and upload them.
    public var keptRevisions: [SyncRecord]
    /// The merged record differs from the server's, so it must be sent again.
    public var needsUpload: Bool
    /// Fields both sides changed to different values.
    public var conflictingFields: [String]
}

/// Three-way merge of one record.
///
/// `base` is the last version this device saw from the server (nil when the
/// device never saw one, for example the same favorite made on two devices).
/// A field only one side changed takes that side's value; a field both sides
/// changed takes the value of the side with the later change time. Ties are
/// broken by the editor's account ID and then by the record's content, the
/// same way on every device, so both devices converge.
public enum SyncMerger {
    public static let conflictReason = "conflict"

    public static func merge(base: SyncRecord?, local: SyncRecord, server: SyncRecord) -> SyncMergeResult {
        precondition(local.key == server.key, "merging two different records")
        let spec = local.type.spec
        let localWins = wins(local, over: server)
        var merged = SyncRecord(type: server.type, id: server.id)
        var conflicts: [String] = []
        var revisions: [SyncRecord] = []

        var names = Set(local.fields.keys).union(server.fields.keys)
        if let base { names.formUnion(base.fields.keys) }

        for name in names.sorted() {
            let localValue = local.fields[name]
            let serverValue = server.fields[name]
            let baseValue = base?.fields[name]
            let merge = spec.field(name)?.merge ?? .latestWins
            let value: SyncValue?
            switch merge {
            case .immutable:
                value = serverValue ?? localValue
            case .stamp:
                value = later(localValue, serverValue)
            case .maximum:
                value = larger(localValue, serverValue)
            case .latestWins:
                if localValue == serverValue {
                    value = localValue
                } else if base != nil && localValue == baseValue {
                    value = serverValue
                } else if base != nil && serverValue == baseValue {
                    value = localValue
                } else {
                    conflicts.append(name)
                    value = localWins ? localValue : serverValue
                    if spec.field(name)?.isAuthoredText == true {
                        let loser = localWins ? server : local
                        let loserValue = localWins ? serverValue : localValue
                        if let text = loserValue?.stringValue, !text.isEmpty {
                            revisions.append(keptRevision(of: loser, text: text))
                        }
                    }
                }
            }
            merged.fields[name] = value
        }

        // The editor follows the side whose change time the merge kept, so
        // "last changed by" stays truthful.
        if let editorField = spec.editorField, spec.field(editorField)?.merge != .immutable {
            merged.fields[editorField] = (localWins ? local : server).fields[editorField]
                ?? (localWins ? server : local).fields[editorField]
        }

        return SyncMergeResult(
            merged: merged,
            keptRevisions: revisions,
            needsUpload: merged.digest != server.digest,
            conflictingFields: conflicts
        )
    }

    /// Whether `a` beats `b` when both changed the same field.
    public static func wins(_ a: SyncRecord, over b: SyncRecord) -> Bool {
        let aStamp = a.stamp ?? .distantPast
        let bStamp = b.stamp ?? .distantPast
        if aStamp != bStamp { return aStamp > bStamp }
        let aEditor = a.editor ?? ""
        let bEditor = b.editor ?? ""
        if aEditor != bEditor { return aEditor < bEditor }
        return a.digest < b.digest
    }

    /// A revision holding words that lost a conflict. Its ID comes from the
    /// record and the words, so retrying the same merge never adds a copy.
    public static func keptRevision(of loser: SyncRecord, text: String) -> SyncRecord {
        let reason = loser.type == .memory ? conflictReason : conflictReason + ":" + loser.type.rawValue
        var revision = SyncRecord(
            type: .memoryRevision,
            id: loser.id + ":conflict:" + SyncDigest.hex(text)
        )
        revision["memoryID"] = .reference(loser.id)
        revision["text"] = .string(text)
        if let editor = loser.editor { revision["editedBy"] = .string(editor) }
        revision["editedAt"] = .date(loser.stamp ?? Date(timeIntervalSince1970: 0))
        revision["baseRevision"] = .int(loser.fields["revision"]?.intValue ?? 0)
        revision["reason"] = .string(reason)
        return revision
    }

    private static func later(_ a: SyncValue?, _ b: SyncValue?) -> SyncValue? {
        guard let aDate = a?.dateValue else { return b ?? a }
        guard let bDate = b?.dateValue else { return a }
        // `<` only: some macOS 27.2 seeds lack Date.>= (see scripts/check_date_operators.py).
        return aDate < bDate ? b : a
    }

    private static func larger(_ a: SyncValue?, _ b: SyncValue?) -> SyncValue? {
        guard let aInt = a?.intValue else { return b ?? a }
        guard let bInt = b?.intValue else { return a }
        return aInt >= bInt ? a : b
    }
}
