import AppKit
import SwiftData
import SwiftUI

// Comments and replies under a memory, and a memory's edit history (issue
// #28). Both people comment on any memory; each deletes only their own
// comments. A reply stays one step in, under the comment that started the
// thread, however deep the conversation goes.

/// One comment and every reply under it, in the order they were written.
struct CommentThread: Identifiable {
    let root: Comment
    let replies: [Comment]
    var id: String { root.id }
}

enum CommentThreads {
    /// Groups a memory's comments into threads. A reply whose comment was
    /// deleted (or has not arrived yet) starts a thread of its own, so it is
    /// never hidden.
    static func threads(_ comments: [Comment]) -> [CommentThread] {
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rootID(of comment: Comment) -> String {
            var current = comment
            var seen: Set<String> = [comment.id]
            while let parentID = current.parentCommentID, let parent = byID[parentID], seen.insert(parentID).inserted {
                current = parent
            }
            return current.id
        }
        let ordered = comments.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var replies: [String: [Comment]] = [:]
        var roots: [Comment] = []
        for comment in ordered {
            let root = rootID(of: comment)
            if root == comment.id {
                roots.append(comment)
            } else {
                replies[root, default: []].append(comment)
            }
        }
        return roots.map { CommentThread(root: $0, replies: replies[$0.id] ?? []) }
    }

    /// Whether this Mac's person wrote the comment, and may delete it.
    static func isOwn(_ comment: Comment) -> Bool {
        AuthorNames.isLocal(comment.authorAccountID)
    }

    /// The other person's replies that stay when `comment` is deleted.
    static func repliesThatStay(after comment: Comment, in comments: [Comment]) -> [Comment] {
        comments.filter { $0.parentCommentID == comment.id && !isOwn($0) }
    }
}

/// What is being typed in each comment field, so moving to another photo or
/// page never loses it. Kept for this run of the app only.
@MainActor
@Observable
final class CommentDrafts {
    static let shared = CommentDrafts()
    var texts: [String: String] = [:]

    static func key(memoryID: String, parentID: String?) -> String {
        "\(memoryID)|\(parentID ?? "")"
    }
}

/// The line over a memory: whose it is (when both people wrote one) and a
/// link to its edit history once it has been changed.
struct MemoryByline: View {
    let memory: Memory
    let showsName: Bool
    let name: String
    @State private var showsHistory = false

    var body: some View {
        if showsName || !memory.revisions.isEmpty {
            HStack(spacing: 8) {
                if showsName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.accent)
                        .lineLimit(1)
                }
                if !memory.revisions.isEmpty {
                    Button(String(localized: "Edit history")) { showsHistory = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityIdentifier("library.memory.history.\(memory.id)")
                        .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                            MemoryHistory(memory: memory, name: name)
                        }
                }
            }
        }
    }
}

/// Every version of a memory, newest first. Read only.
struct MemoryHistory: View {
    let memory: Memory
    let name: String

    private var older: [MemoryRevision] {
        memory.revisions.sorted { ($0.editedAt, $0.id) > ($1.editedAt, $1.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "\(name)’s memory · Edit history"))
                .font(.headline)
                .foregroundStyle(Paper.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    version(
                        label: Text(String(localized: "Now")) + Text(verbatim: " · ") + Text(memory.updatedAt, format: .dateTime.month().day().hour().minute()),
                        text: memory.text
                    )
                    ForEach(older, id: \.id) { revision in
                        Divider()
                        version(label: label(for: revision), text: revision.text)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 320)
        .background(Paper.raised)
        .accessibilityIdentifier("library.memory.historyList.\(memory.id)")
    }

    private func label(for revision: MemoryRevision) -> Text {
        let date = Text(revision.editedAt, format: .dateTime.month().day().hour().minute())
        guard revision.reason == "conflict" else { return date }
        return date + Text(verbatim: " · ") + Text(String(localized: "Version from another Mac"))
    }

    private func version(label: Text, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label
                .font(.caption)
                .foregroundStyle(Paper.muted)
            Text(text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(Paper.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Comments under one memory. In the viewer the threads show in place; in
/// the grid, where there is little room, only "2 comments" shows, and a
/// click opens the same threads in a popover. With no comments the grid
/// shows nothing at all.
struct MemoryComments: View {
    let memory: Memory
    var isLarge = false
    @Query private var comments: [Comment]
    @State private var showsPopover = false

    init(memory: Memory, isLarge: Bool = false) {
        self.memory = memory
        self.isLarge = isLarge
        let memoryID = memory.id
        _comments = Query(filter: #Predicate<Comment> { $0.memoryID == memoryID }, sort: \Comment.createdAt)
    }

    var body: some View {
        if isLarge {
            CommentThreadList(memoryID: memory.id, comments: comments)
        } else if !comments.isEmpty {
            Button(String(localized: "\(comments.count) comments")) { showsPopover = true }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("library.comments.count.\(memory.id)")
                .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                    ScrollView {
                        CommentThreadList(memoryID: memory.id, comments: comments)
                            .padding(16)
                    }
                    .frame(width: 340)
                    .frame(maxHeight: 420)
                    .background(Paper.raised)
                }
        }
    }
}

/// The threads, each reply one step in, and the Comment button under them.
private struct CommentThreadList: View {
    let memoryID: String
    let comments: [Comment]
    /// The comment being answered, or `memoryID` for a new comment.
    @State private var composingFor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CommentThreads.threads(comments)) { thread in
                VStack(alignment: .leading, spacing: 6) {
                    CommentRow(comment: thread.root, comments: comments) { composingFor = thread.root.id }
                    ForEach(thread.replies, id: \.id) { reply in
                        CommentRow(comment: reply, comments: comments) { composingFor = reply.id }
                    }
                    .padding(.leading, 16)
                    if let parentID = composingFor, parentID != memoryID,
                       parentID == thread.root.id || thread.replies.contains(where: { $0.id == parentID }) {
                        CommentComposer(memoryID: memoryID, parentID: parentID) { composingFor = nil }
                            .padding(.leading, 16)
                    }
                }
            }
            if composingFor == memoryID {
                CommentComposer(memoryID: memoryID, parentID: nil) { composingFor = nil }
            } else {
                Button(String(localized: "Comment")) { composingFor = memoryID }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("library.comment.new.\(memoryID)")
            }
        }
        .accessibilityIdentifier("library.comments.\(memoryID)")
    }
}

private struct CommentRow: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AuthorNames.myNameKey) private var myName = ""
    @AppStorage(AuthorNames.partnerNameKey) private var partnerName = ""
    let comment: Comment
    let comments: [Comment]
    let reply: () -> Void
    @State private var confirmsDelete = false

    private var isOwn: Bool { CommentThreads.isOwn(comment) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(AuthorNames.label(isOwn: isOwn, myName: myName, partnerName: partnerName))
                    .foregroundStyle(LibraryPalette.accent)
                Text(comment.createdAt, format: .dateTime.month().day())
                    .foregroundStyle(Paper.muted)
            }
            .font(.caption)
            .lineLimit(1)
            Text(comment.text)
                .font(.system(.callout, design: .serif))
                .foregroundStyle(Paper.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button(String(localized: "Reply"), action: reply)
                    .accessibilityIdentifier("library.comment.reply.\(comment.id)")
                if isOwn {
                    Button(String(localized: "Delete")) { confirmsDelete = true }
                        .accessibilityIdentifier("library.comment.delete.\(comment.id)")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .contextMenu {
            Button(String(localized: "Reply"), action: reply)
            if isOwn {
                Button(String(localized: "Delete"), role: .destructive) { confirmsDelete = true }
            }
        }
        .accessibilityIdentifier("library.comment.\(comment.id)")
        .confirmationDialog(String(localized: "Delete this comment?"), isPresented: $confirmsDelete) {
            Button(String(localized: "Delete"), role: .destructive) { delete() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if !CommentThreads.repliesThatStay(after: comment, in: comments).isEmpty {
                Text(String(localized: "Replies from \(AuthorNames.label(isOwn: false, myName: myName, partnerName: partnerName)) stay."))
            }
        }
    }

    /// Deletes this person's own comment; Edit > Undo puts it back.
    private func delete() {
        guard isOwn else { return }
        let saved = CommentSnapshot(comment)
        let context = modelContext
        context.delete(comment)
        context.saveOrReport()
        guard let undoManager = NSApp.mainWindow?.undoManager else { return }
        undoManager.registerUndo(withTarget: CommentDrafts.shared) { _ in
            MainActor.assumeIsolated {
                context.insert(saved.restored())
                context.saveOrReport()
            }
        }
        undoManager.setActionName(String(localized: "Delete Comment"))
    }
}

/// A deleted comment, to bring back on Undo with the same identity.
private struct CommentSnapshot {
    let id: String
    let memoryID: String
    let parentCommentID: String?
    let text: String
    let authorAccountID: String
    let createdAt: Date
    let updatedAt: Date

    init(_ comment: Comment) {
        id = comment.id
        memoryID = comment.memoryID
        parentCommentID = comment.parentCommentID
        text = comment.text
        authorAccountID = comment.authorAccountID
        createdAt = comment.createdAt
        updatedAt = comment.updatedAt
    }

    func restored() -> Comment {
        Comment(id: id, memoryID: memoryID, parentCommentID: parentCommentID, text: text,
                authorAccountID: authorAccountID, createdAt: createdAt, updatedAt: .now)
    }
}

/// One line for a new comment or reply. Return sends, Option-Return starts a
/// new line, Escape cancels. Leaving it empty leaves nothing behind.
private struct CommentComposer: View {
    @Environment(\.modelContext) private var modelContext
    let memoryID: String
    let parentID: String?
    let done: () -> Void
    @FocusState private var isFocused: Bool

    private var key: String { CommentDrafts.key(memoryID: memoryID, parentID: parentID) }

    private var text: Binding<String> {
        Binding(
            get: { CommentDrafts.shared.texts[key] ?? "" },
            set: { CommentDrafts.shared.texts[key] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: text, prompt: Text(String(localized: "Write a comment…")), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .serif))
                .foregroundStyle(Paper.ink)
                .lineLimit(1...6)
                .focused($isFocused)
                .padding(.vertical, 3)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Paper.rule).frame(height: 1)
                }
                .onSubmit(send)
                .onExitCommand(perform: cancel)
                .onAppear { DispatchQueue.main.async { isFocused = true } }
                .accessibilityIdentifier("library.comment.field.\(parentID ?? memoryID)")
            Text(String(localized: "Return to send · Esc to cancel"))
                .font(.caption2)
                .foregroundStyle(Paper.muted)
        }
    }

    private func send() {
        let value = (CommentDrafts.shared.texts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        CommentDrafts.shared.texts[key] = nil
        defer { done() }
        guard !value.isEmpty else { return }
        modelContext.insert(Comment(memoryID: memoryID, parentCommentID: parentID, text: value))
        modelContext.saveOrReport()
    }

    private func cancel() {
        CommentDrafts.shared.texts[key] = nil
        done()
    }
}
