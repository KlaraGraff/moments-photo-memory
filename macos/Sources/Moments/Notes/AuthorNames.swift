import Foundation

/// What the two people are called next to what they wrote. Each Mac keeps
/// its own pair in UserDefaults (Settings › Sharing); nothing here is stored
/// with the memories or synced, so renaming changes every label at once.
enum AuthorNames {
    static let myNameKey = "moments.people.myName"
    static let partnerNameKey = "moments.people.partnerName"

    /// The person using this Mac: records written here carry
    /// `MomentsAccount.localID`, and records from before accounts carry none.
    static func isLocal(_ accountID: String?) -> Bool {
        accountID == nil || accountID == MomentsAccount.localID
    }

    /// The label for one side: the name typed in Settings, or "Me" / "Partner".
    static func label(isOwn: Bool, myName: String, partnerName: String) -> String {
        let typed = (isOwn ? myName : partnerName).trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return isOwn ? String(localized: "Me") : String(localized: "Partner")
    }

    static func label(isOwn: Bool, defaults: UserDefaults = .standard) -> String {
        label(
            isOwn: isOwn,
            myName: defaults.string(forKey: myNameKey) ?? "",
            partnerName: defaults.string(forKey: partnerNameKey) ?? ""
        )
    }
}

extension Memory {
    /// Written by the person using this Mac. A memory with no account is one
    /// from before accounts, whose `author` still says who wrote it.
    var isOwn: Bool {
        if let authorAccountID { return authorAccountID == MomentsAccount.localID }
        return author == .me
    }
}

extension MediaItem {
    /// Every memory on the photo with words in it, oldest first, from both people.
    var writtenMemories: [Memory] {
        memories
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// The memory this Mac's person edits on the photo: their newest one.
    var ownMemory: Memory? {
        memories.filter(\.isOwn).max { $0.updatedAt < $1.updatedAt }
    }

    var hasWrittenMemory: Bool {
        memories.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
