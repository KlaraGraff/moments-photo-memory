import SwiftUI
import SwiftData

/// A trip's or a day's memories, written where they happened: each memory
/// with who wrote it, then an empty ruled line to write another. Return
/// saves, Option-Return starts a new line, Escape cancels, and clicking
/// elsewhere saves. Your own memories change in place when clicked; your
/// partner's are read-only. Stored as `CollectionMemory`, the same records
/// AI-organized notes write, so both show up here and in the Library.
struct TripMemoryLines: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: NoteMemoryScope
    let key: String
    let memories: [CollectionMemory]
    let prompt: String
    let identifier: String
    @State private var draft = ""
    @State private var editingID: String?
    @State private var editText = ""
    @State private var savedCount = 0
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case new
        case edit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(memories, id: \.id) { memory in
                if editingID == memory.id {
                    ruledField(text: $editText, prompt: prompt, field: .edit)
                        .onSubmit { saveEdit() }
                        .onExitCommand {
                            editingID = nil
                            focus = nil
                        }
                        // The field appears first, then takes focus.
                        .onAppear { DispatchQueue.main.async { focus = .edit } }
                        .accessibilityIdentifier("\(identifier).edit")
                } else {
                    memoryRow(memory)
                }
            }
            ruledField(text: $draft, prompt: prompt, field: .new)
                .onSubmit { saveNew() }
                .onExitCommand {
                    draft = ""
                    focus = nil
                }
                .accessibilityIdentifier(identifier)
                .overlay(alignment: .trailing) {
                    TransientCheckmark(trigger: savedCount, label: String(localized: "Saved"))
                        .allowsHitTesting(false)
                }
        }
        .onChange(of: focus) { old, new in
            if old == .new, new != .new { saveNew() }
            if old == .edit, new != .edit { saveEdit() }
        }
        // Switching screens can remove the field in the same update that
        // ends editing; the words are still saved.
        .onDisappear {
            saveNew()
            saveEdit()
        }
    }

    private func ruledField(text: Binding<String>, prompt: String, field: Field) -> some View {
        let focused = focus == field
        return TextField("", text: text, prompt: Text(prompt), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .serif))
            .foregroundStyle(Paper.ink)
            .lineLimit(1...6)
            .focused($focus, equals: field)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                // Focus deepens the ruled line instead of switching to a bright one.
                Rectangle()
                    .fill(focused ? Paper.muted.opacity(0.7) : Paper.rule)
                    .frame(height: focused ? 1.5 : 1)
                    .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: focused)
            }
            .help(String(localized: "Return saves. Option-Return starts a new line."))
    }

    private func memoryRow(_ memory: CollectionMemory) -> some View {
        let isOwn = memory.authorAccountID == MomentsAccount.localID
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(memory.text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "— \(isOwn ? String(localized: "Me") : String(localized: "Partner"))")
                .font(.caption)
                .foregroundStyle(Paper.accent)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOwn { beginEditing(memory) }
        }
        .help(isOwn ? String(localized: "Click to edit") : "")
        .contextMenu {
            if isOwn {
                Button(String(localized: "Edit")) { beginEditing(memory) }
                Button(String(localized: "Delete"), role: .destructive) {
                    if editingID == memory.id { editingID = nil }
                    modelContext.delete(memory)
                    try? modelContext.save()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifier).memory")
    }

    private func beginEditing(_ memory: CollectionMemory) {
        saveNew()
        editText = memory.text
        editingID = memory.id
    }

    private func saveNew() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        modelContext.insert(CollectionMemory(scope: scope, scopeKey: key, text: text))
        try? modelContext.save()
        draft = ""
        if focus == .new { focus = nil }
        savedCount += 1
    }

    /// An emptied memory keeps its words; deleting is a separate, explicit step.
    private func saveEdit() {
        guard let id = editingID else { return }
        editingID = nil
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let memory = memories.first(where: { $0.id == id }),
              !text.isEmpty, text != memory.text else { return }
        memory.text = text
        memory.updatedAt = .now
        try? modelContext.save()
        savedCount += 1
    }
}
