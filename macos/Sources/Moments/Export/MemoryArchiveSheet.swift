import AppKit
import MomentsCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Backup's "Written words" row: "Export All Memories…".
struct MemoryArchiveSettingsRow: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showingExport = false

    var body: some View {
        LabeledContent(String(localized: "Written words")) {
            Button(String(localized: "Export All Memories…")) { showingExport = true }
                .accessibilityIdentifier("settings.export-memories")
        }
        .sheet(isPresented: $showingExport) {
            MemoryArchiveSheet()
                .modelContext(modelContext)
        }
    }
}

/// Everything both people wrote, as one Markdown file without photos, that
/// any text app can open: photo memories, trip and day memories, place
/// notes and comments, each with who wrote it.
struct MemoryArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AuthorNames.myNameKey) private var myName = ""
    @AppStorage(AuthorNames.partnerNameKey) private var partnerName = ""

    @State private var input: MemoryArchive.Input?
    @State private var didLoad = false
    @State private var order = MemoryArchive.Order.byChapter
    @State private var options = MemoryBookOptions()
    @State private var isSaving = false
    @State private var savedURL: URL?
    @State private var errorText: String?

    private var namesFilled: Bool {
        !myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !partnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        PaperSheet(String(localized: "Export All Memories"), subtitle: String(localized: "Saves what you both wrote as one text file, without photos.")) {
            if input == nil, errorText == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                form
            }
        } footer: {
            footer
        }
        .frame(width: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memoryArchive.sheet")
        .task { await load() }
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                PaperFormLabel(String(localized: "Contents"))
                Text(contents)
                    .font(.callout.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("memoryArchive.contents")
            }
            GridRow {
                PaperFormLabel(String(localized: "Order"))
                Picker(String(localized: "Order"), selection: $order) {
                    Text(String(localized: "By chapter, then by date")).tag(MemoryArchive.Order.byChapter)
                    Text(String(localized: "By date only")).tag(MemoryArchive.Order.byDate)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("memoryArchive.order")
            }
            GridRow {
                PaperFormLabel(String(localized: "Include"))
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(String(localized: "Trip and day memories"), isOn: $options.includesChapterAndDayMemories)
                    Toggle(String(localized: "Place descriptions"), isOn: $options.includesPlaceNotes)
                    Toggle(String(localized: "Comments on memories"), isOn: $options.includesComments)
                }
                .toggleStyle(.checkbox)
            }
            GridRow {
                PaperFormLabel(String(localized: "Names"))
                HStack(spacing: 8) {
                    TextField(String(localized: "Your name"), text: $myName)
                        .textFieldStyle(.paper)
                        .frame(width: 150)
                        .accessibilityIdentifier("memoryArchive.myName")
                    TextField(String(localized: "Your partner's name"), text: $partnerName)
                        .textFieldStyle(.paper)
                        .frame(width: 150)
                        .accessibilityIdentifier("memoryArchive.partnerName")
                }
            }
        }
        .disabled(isSaving)
    }

    private var contents: String {
        let counts = input.map(MemoryArchive.counts) ?? MemoryArchive.counts(MemoryArchive.Input())
        return String(localized: "Photo memories: \(counts.photoMemories) · Trip and day memories: \(counts.chapterAndDayMemories) · Place descriptions: \(counts.placeNotes) · Comments: \(counts.comments)")
    }

    @ViewBuilder
    private var footer: some View {
        if let savedURL {
            Label(String(localized: "Saved to “\(FileManager.default.displayName(atPath: savedURL.deletingLastPathComponent().path))”"), systemImage: "checkmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Paper.accent)
                .accessibilityIdentifier("memoryArchive.saved")
            Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("memoryArchive.done")
        } else {
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(Paper.accent)
                    .lineLimit(2)
            } else if !namesFilled, input != nil {
                Text(String(localized: "Fill in both names first"))
                    .font(.callout)
                    .foregroundStyle(Paper.muted)
            }
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("memoryArchive.cancel")
            Button(String(localized: "Export…")) { export() }
                .keyboardShortcut(.defaultAction)
                .disabled(input == nil || !namesFilled || isSaving)
                .accessibilityIdentifier("memoryArchive.export")
        }
    }

    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        let container = modelContext.container
        let loaded = await Task.detached(priority: .userInitiated) {
            try? MemoryBookCollector.archive(container: container)
        }.value
        if let loaded {
            input = loaded
        } else {
            errorText = String(localized: "The library could not be read.")
        }
    }

    private func export() {
        guard let input, namesFilled, !isSaving else { return }
        errorText = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = String(localized: "Our memories") + ".md"
        let book = MemoryBookExporter.strings(myName: myName, partnerName: partnerName)
        let mine = AuthorNames.label(isOwn: true, myName: myName, partnerName: partnerName)
        let theirs = AuthorNames.label(isOwn: false, myName: myName, partnerName: partnerName)
        let today = Date.now.formatted(date: .long, time: .omitted)
        let strings = MemoryArchive.Strings(
            book: book,
            title: String(localized: "Our memories"),
            subtitle: String(localized: "\(mine) and \(theirs) · exported on \(today)"),
            notInAChapter: String(localized: "Memories not in a chapter"),
            placeNotes: String(localized: "Place descriptions")
        )
        let order = order
        let options = options
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            isSaving = true
            Task {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                    let text = MemoryArchive.markdown(input, order: order, options: options, strings: strings)
                    return Result { try MemoryBookExporter.exportArchive(text, to: url) }
                }.value
                isSaving = false
                switch result {
                case .success:
                    savedURL = url
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case let .failure(error):
                    errorText = String(localized: "Couldn’t save the memory book: \(error.localizedDescription)")
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
