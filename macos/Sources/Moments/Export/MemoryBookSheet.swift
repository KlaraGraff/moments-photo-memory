import AppKit
import MomentsCore
import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The state of one memory book export: the chapter as read from the
/// library, then the export's progress. Lives on the main actor; the
/// reading and writing happen in tasks of their own.
@MainActor
@Observable
final class MemoryBookExportModel {
    enum Phase: Equatable {
        case loading
        case ready
        case exporting(MemoryBookProgress)
        case saved(URL, thumbnailsUsed: Int)
        case stopped
        case failed(String)
    }

    var phase = Phase.loading
    var book: MemoryBookCollector.Book?
    var pageEstimate: Int?
    private var exportTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?

    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    func load(_ trip: TimelineTrip, title: String, startDate: Date?, endDate: Date?, container: ModelContainer) async {
        guard book == nil else { return }
        let result = await Task.detached(priority: .userInitiated) {
            try? MemoryBookCollector.book(trip, title: title, startDate: startDate, endDate: endDate, container: container)
        }.value
        book = result
        if result == nil {
            phase = .failed(String(localized: "The chapter could not be read."))
        } else {
            phase = .ready
        }
    }

    /// The PDF's page count for these choices, worked out off the main actor.
    func estimatePages(_ options: MemoryBookOptions, strings: MemoryBookStrings) {
        estimateTask?.cancel()
        guard let book else { return }
        estimateTask = Task { [weak self] in
            let count = await Task.detached(priority: .utility) { () -> Int in
                let prepared = MemoryBookPlan.prepared(book.document, options: options)
                var ratios: [String: Double] = [:]
                for (id, source) in book.sources { if let ratio = source.aspectRatio { ratios[id] = ratio } }
                let input = MemoryBookLayout.Input(document: prepared, strings: strings, aspectRatios: ratios, coverPhotoID: prepared.photos.first?.id, madeWith: "")
                return MemoryBookLayout.pages(input, metrics: MemoryBookPDF.metrics, measure: MemoryBookPDF.measure).count
            }.value
            guard !Task.isCancelled else { return }
            self?.pageEstimate = count
        }
    }

    func export(format: MemoryBookFormat, options: MemoryBookOptions, strings: MemoryBookStrings, to url: URL) {
        guard let book, !isExporting else { return }
        let prepared = MemoryBookPlan.prepared(book.document, options: options)
        let sources = book.sources
        phase = .exporting(MemoryBookProgress(done: 0, total: prepared.photos.count, dayLabel: ""))
        let report: @Sendable (MemoryBookProgress) -> Void = { [weak self] progress in
            let model = self
            Task { @MainActor in
                guard let model, case .exporting = model.phase else { return }
                model.phase = .exporting(progress)
            }
        }
        exportTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                try await MemoryBookExporter.export(prepared, sources: sources, format: format, strings: strings, to: url, progress: report)
            }
            let outcome = await withTaskCancellationHandler {
                await work.result
            } onCancel: {
                work.cancel()
            }
            guard let self else { return }
            switch outcome {
            case let .success(result):
                self.phase = .saved(result.url, thumbnailsUsed: result.thumbnailsUsed)
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            case let .failure(error):
                if error is CancellationError {
                    self.phase = .stopped
                } else {
                    self.phase = .failed(String(localized: "Couldn’t save the memory book: \(error.localizedDescription)"))
                }
            }
        }
    }

    func stop() {
        exportTask?.cancel()
    }

    func cancelAll() {
        exportTask?.cancel()
        estimateTask?.cancel()
    }
}

/// "Export Memory Book…" from a chapter's More menu: the chapter as a PDF
/// ready to print, or a Markdown folder of text and smaller pictures.
struct MemoryBookSheet: View {
    let trip: TimelineTrip
    let title: String
    let startDate: Date?
    let endDate: Date?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AuthorNames.myNameKey) private var myName = ""
    @AppStorage(AuthorNames.partnerNameKey) private var partnerName = ""

    @State private var model = MemoryBookExportModel()
    @State private var format = MemoryBookFormat.pdf
    @State private var options = MemoryBookOptions()
    @State private var editingNames = false

    private var namesFilled: Bool {
        !myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !partnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var strings: MemoryBookStrings {
        MemoryBookExporter.strings(myName: myName, partnerName: partnerName)
    }

    var body: some View {
        PaperSheet(String(localized: "Export Memory Book"), subtitle: subtitle) {
            if model.book == nil, model.phase == .loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                form
            }
        } footer: {
            footer
        }
        .frame(width: 600)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memoryBook.sheet")
        .task {
            if !namesFilled { editingNames = true }
            await model.load(trip, title: title, startDate: startDate, endDate: endDate, container: modelContext.container)
            model.estimatePages(options, strings: strings)
        }
        .onChange(of: options) { _, _ in model.estimatePages(options, strings: strings) }
        .onDisappear { model.cancelAll() }
    }

    private var subtitle: String? {
        let range = strings.dateRange(startDate, endDate)
        return range.isEmpty ? title : "\(title) · \(range)"
    }

    // MARK: Form

    private var counts: (withMemories: Int, all: Int) {
        model.book.map { MemoryBookPlan.photoCounts($0.document) } ?? (0, 0)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    PaperFormLabel(String(localized: "Format"))
                    HStack(spacing: 8) {
                        formatCard(.pdf, title: "PDF", detail: String(localized: "Ready to print, laid out as a book"))
                        formatCard(.markdown, title: String(localized: "Markdown Folder"), detail: String(localized: "Text with smaller pictures, for keeping long term"))
                    }
                }
                GridRow {
                    PaperFormLabel(String(localized: "Photos"))
                    Picker(String(localized: "Photos"), selection: $options.photos) {
                        Text(String(localized: "Only photos with memories (\(counts.withMemories))")).tag(MemoryBookOptions.Photos.withMemories)
                        Text(String(localized: "All photos (\(counts.all))")).tag(MemoryBookOptions.Photos.all)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .accessibilityIdentifier("memoryBook.photos")
                }
                GridRow {
                    PaperFormLabel(String(localized: "Also include"))
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(String(localized: "Trip and day memories"), isOn: $options.includesChapterAndDayMemories)
                            .accessibilityIdentifier("memoryBook.includeCollection")
                        Toggle(String(localized: "Place notes"), isOn: $options.includesPlaceNotes)
                            .accessibilityIdentifier("memoryBook.includePlaceNotes")
                        Toggle(String(localized: "Comments on memories"), isOn: $options.includesComments)
                            .accessibilityIdentifier("memoryBook.includeComments")
                    }
                    .toggleStyle(.checkbox)
                }
                GridRow {
                    PaperFormLabel(String(localized: "Names"))
                    names
                }
                if format == .pdf {
                    GridRow {
                        PaperFormLabel(String(localized: "Paper"))
                        Text(String(localized: "A4 portrait"))
                    }
                }
            }
            .disabled(model.isExporting)

            if let notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Paper.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("memoryBook.notice")
            }
            Text(specLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Paper.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memoryBook.spec")
        }
    }

    private func formatCard(_ value: MemoryBookFormat, title: String, detail: String) -> some View {
        let selected = format == value
        return Button {
            format = value
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .foregroundStyle(selected ? Paper.accent : Paper.ink)
            .background(selected ? Paper.accent.opacity(0.10) : Paper.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Paper.accent.opacity(selected ? 0.35 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("memoryBook.format.\(value.rawValue)")
    }

    @ViewBuilder
    private var names: some View {
        VStack(alignment: .leading, spacing: 5) {
            if editingNames || !namesFilled {
                HStack(spacing: 8) {
                    TextField(String(localized: "Your name"), text: $myName)
                        .textFieldStyle(.paper)
                        .frame(width: 150)
                        .accessibilityIdentifier("memoryBook.myName")
                    TextField(String(localized: "Your partner's name"), text: $partnerName)
                        .textFieldStyle(.paper)
                        .frame(width: 150)
                        .accessibilityIdentifier("memoryBook.partnerName")
                }
            } else {
                HStack(spacing: 8) {
                    Text(String(localized: "\(myName) and \(partnerName)"))
                        .accessibilityIdentifier("memoryBook.names")
                    Button(String(localized: "Change…")) { editingNames = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("memoryBook.changeNames")
                }
            }
            Text(String(localized: "Each memory in the book shows who wrote it. These are the same names as in Settings."))
                .font(.caption)
                .foregroundStyle(Paper.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One thing worth knowing before exporting, if any.
    private var notice: String? {
        guard let book = model.book else { return nil }
        if MemoryBookPlan.hasNoWriting(book.document) {
            return String(localized: "No one has written a memory in this chapter yet, so the book will have only photos and dates.")
        }
        let shown = Set(MemoryBookPlan.prepared(book.document, options: options).photos.map(\.id))
        let previews = book.previewOnlyIDs.intersection(shown).count
        if previews > 0, format == .pdf {
            let name = AuthorNames.label(isOwn: false, myName: myName, partnerName: partnerName)
            return String(localized: "\(name)’s photos that are only shared previews on this Mac: \(previews). The previews are used and may print a little soft.")
        }
        return nil
    }

    private var specLine: String {
        let count = model.book.map { MemoryBookPlan.prepared($0.document, options: options).photos.count } ?? 0
        switch format {
        case .pdf:
            return String(localized: "A4 portrait · about \(model.pageEstimate ?? 1) pages · photos at 300 dpi · no location or camera data")
        case .markdown:
            return String(localized: "1 .md file + \(count) pictures (1,600 pixels on the long side) · no location or camera data")
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case let .exporting(progress):
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(width: 120)
                .accessibilityIdentifier("memoryBook.progressBar")
            Text(String(localized: "Laying out \(progress.dayLabel) · \(progress.done) / \(progress.total)"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Paper.muted)
                .lineLimit(1)
                .accessibilityIdentifier("memoryBook.progress")
            Spacer(minLength: 0)
            Button(String(localized: "Stop Export")) { model.stop() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("memoryBook.stop")
        case let .saved(url, thumbnails):
            VStack(alignment: .trailing, spacing: 2) {
                Label(String(localized: "Saved to “\(FileManager.default.displayName(atPath: url.deletingLastPathComponent().path))”"), systemImage: "checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Paper.accent)
                    .accessibilityIdentifier("memoryBook.saved")
                if thumbnails > 0 {
                    Text(String(localized: "\(thumbnails) photos couldn’t be read in full, so thumbnails were used"))
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                        .accessibilityIdentifier("memoryBook.thumbnails")
                }
            }
            Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("memoryBook.done")
        default:
            message
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("memoryBook.cancel")
            Button(isFailed ? String(localized: "Try Again") : String(localized: "Export…")) { chooseDestination() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.book == nil || !namesFilled)
                .accessibilityIdentifier("memoryBook.export")
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var message: some View {
        switch model.phase {
        case .stopped:
            Text(String(localized: "Stopped. No half-finished file was left behind."))
                .font(.callout)
                .foregroundStyle(Paper.muted)
                .accessibilityIdentifier("memoryBook.stopped")
        case let .failed(text):
            Text(text)
                .font(.callout)
                .foregroundStyle(Paper.accent)
                .lineLimit(2)
                .accessibilityIdentifier("memoryBook.error")
        default:
            if !namesFilled, model.book != nil {
                Text(String(localized: "Fill in both names first"))
                    .font(.callout)
                    .foregroundStyle(Paper.muted)
                    .accessibilityIdentifier("memoryBook.namesNeeded")
            }
        }
    }

    // MARK: Export

    private func chooseDestination() {
        guard namesFilled, model.book != nil else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let name = MemoryBookExporter.fileName(title)
        switch format {
        case .pdf:
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = name + ".pdf"
        case .markdown:
            panel.nameFieldStringValue = String(localized: "\(name) Memory Book")
        }
        let chosenFormat = format
        let chosenOptions = options
        let words = strings
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.export(format: chosenFormat, options: chosenOptions, strings: words, to: url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
