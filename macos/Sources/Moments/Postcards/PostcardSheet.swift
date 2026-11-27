import AppKit
import MomentsCore
import SwiftUI
import UniformTypeIdentifiers

/// Makes a print-ready postcard from one photo: pick a style, choose what
/// the front says, write the back, and save a two-page PDF that an online
/// print shop can print as it is. Opened from the large viewer. Nothing is
/// uploaded; the file is saved where the person chooses. The message is the
/// card's own: editing it does not change the photo's memories.
struct PostcardSheet: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss

    @State private var content = PostcardContent()
    @State private var showDate = true
    @State private var showPlace = true
    @State private var side = PostcardSide.front
    /// The photo as the viewer has it (up to about 2,000 pixels).
    @State private var photo: CGImage?
    /// A smaller copy, so the preview redraws quickly while dragging or typing.
    @State private var previewPhoto: CGImage?
    @State private var preview: CGImage?
    @State private var dragStart: CGPoint?
    @State private var isExporting = false
    @State private var savedFolder: String?
    @State private var errorText: String?
    @State private var didLoad = false

    private static let previewWidth: CGFloat = 420

    var body: some View {
        PaperSheet(String(localized: "Make Postcard"), subtitle: subtitle) {
            HStack(alignment: .top, spacing: 22) {
                previewColumn
                controls
                    .frame(width: 246)
            }
        } footer: {
            if let savedFolder {
                Label(String(localized: "Saved to “\(savedFolder)”"), systemImage: "checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Paper.accent)
                    .accessibilityIdentifier("postcard.saved")
            }
            Button(savedFolder == nil ? String(localized: "Cancel") : String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("postcard.cancel")
            Button(String(localized: "Export PDF…")) { export() }
                .keyboardShortcut(.defaultAction)
                .disabled(photo == nil || isExporting)
                .accessibilityIdentifier("postcard.export")
        }
        .frame(width: 760)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("postcard.sheet")
        .task { await loadPhoto() }
        .onChange(of: content) { _, _ in renderPreview() }
        .onChange(of: side) { _, _ in renderPreview() }
        .onChange(of: showDate) { _, _ in applyCaptions() }
        .onChange(of: showPlace) { _, _ in applyCaptions() }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: 10) {
            Picker(String(localized: "Side"), selection: $side) {
                Text(String(localized: "Picture Side")).tag(PostcardSide.front)
                Text(String(localized: "Message Side")).tag(PostcardSide.back)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("postcard.side")

            ZStack {
                if let preview {
                    Image(decorative: preview, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: Paper.shadow.opacity(0.16), radius: 6, y: 2)
                        .gesture(dragToCrop, including: side == .front ? .all : .none)
                        .accessibilityIdentifier("postcard.preview")
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: Self.previewWidth, height: previewHeight)

            Text(hint)
                .font(.caption)
                .foregroundStyle(Paper.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "The striped edge is bleed and is trimmed off after printing."))
                .font(.caption)
                .foregroundStyle(Paper.muted.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// Room for a portrait card too, so the sheet keeps its size.
    private var previewHeight: CGFloat {
        let page = PostcardRenderer.spec.pageSize(content.orientation)
        return min(Self.previewWidth * page.height / page.width, 300)
    }

    private var hint: String {
        switch side {
        case .front:
            return String(localized: "Drag the photo to change the crop.")
        case .back:
            if content.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(localized: "An empty message prints as blank lines for handwriting.")
            }
            return String(localized: "Long messages are set in a smaller size.")
        }
    }

    private var dragToCrop: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let photo else { return }
                let start = dragStart ?? content.focus
                if dragStart == nil { dragStart = start }
                let page = PostcardRenderer.spec.pageSize(content.orientation)
                let shown = displayedPreviewSize
                guard shown.width > 0 else { return }
                let millimetresPerPoint = page.width / shown.width
                let frame = PostcardFrontLayout(template: content.template, orientation: content.orientation).photo
                content.focus = PostcardCrop.focus(
                    afterDragging: CGSize(
                        width: value.translation.width * millimetresPerPoint,
                        height: value.translation.height * millimetresPerPoint
                    ),
                    from: start,
                    imageSize: CGSize(width: photo.width, height: photo.height),
                    frame: frame.size
                )
            }
            .onEnded { _ in dragStart = nil }
    }

    /// The preview's size on screen, fitted into its box.
    private var displayedPreviewSize: CGSize {
        let page = PostcardRenderer.spec.pageSize(content.orientation)
        let box = CGSize(width: Self.previewWidth, height: previewHeight)
        let scale = min(box.width / page.width, box.height / page.height)
        return CGSize(width: page.width * scale, height: page.height * scale)
    }

    private func renderPreview() {
        let width = Int(displayedPreviewSize.width * 2)
        preview = PostcardRenderer.previewImage(side, content, image: previewPhoto, pixelWidth: max(width, 200))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel(String(localized: "Style"))
                HStack(spacing: 8) {
                    templateButton(.fullBleed, String(localized: "Full Bleed"))
                    templateButton(.border, String(localized: "White Border"))
                    templateButton(.note, String(localized: "Note Strip"))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(String(localized: "On the Front"))
                Toggle(String(localized: "Date"), isOn: $showDate)
                    .disabled(item.effectiveCaptureDate == nil)
                    .accessibilityIdentifier("postcard.showDate")
                Toggle(String(localized: "Place"), isOn: $showPlace)
                    .disabled(item.namedPlace == nil)
                    .accessibilityIdentifier("postcard.showPlace")
            }
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(String(localized: "Message on the Back"))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $content.message)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .accessibilityIdentifier("postcard.message")
                    if content.message.isEmpty {
                        Text(String(localized: "This photo has no memories yet. Write a few lines, or leave it empty to write by hand."))
                            .font(.callout)
                            .foregroundStyle(Paper.muted.opacity(0.75))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 128)
                .background(Paper.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .paperFocusRing(false)
                if let fitNote {
                    Text(fitNote)
                        .font(.caption)
                        .foregroundStyle(Paper.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("postcard.fitNote")
                }
            }
            if let lowResolution {
                Text(lowResolution)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Paper.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("postcard.lowResolution")
            }
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(Paper.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(specLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Paper.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Paper.muted)
    }

    private func templateButton(_ template: PostcardTemplate, _ name: String) -> some View {
        let selected = content.template == template
        return Button {
            content.template = template
            content.focus = CGPoint(x: 0.5, y: 0.5)
            side = .front
        } label: {
            VStack(spacing: 5) {
                TemplateThumbnail(template: template)
                    .frame(height: 34)
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Paper.accent : Paper.ink)
            .background(selected ? Paper.accent.opacity(0.10) : Paper.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Paper.accent.opacity(selected ? 0.35 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("postcard.template.\(template.rawValue)")
    }

    private var fitNote: String? {
        let fit = PostcardRenderer.messageFit(content.message)
        return fit.fitsCompletely ? nil : String(localized: "Too long to fit: the end will be cut off.")
    }

    private var lowResolution: String? {
        guard let photo else { return nil }
        let frame = PostcardFrontLayout(template: content.template, orientation: content.orientation).photo
        let source = PostcardCrop.sourceRect(imageSize: CGSize(width: photo.width, height: photo.height), frame: frame.size, focus: content.focus)
        guard PostcardCrop.effectiveDPI(source: source, frameMillimetres: frame.size) < PostcardCrop.lowResolutionDPI else { return nil }
        return String(localized: "This photo is only \(photo.width) × \(photo.height) pixels and may look blurry when printed. You can still export it.")
    }

    private var specLine: String {
        let trim = PostcardRenderer.spec.trimSize(content.orientation)
        return String(localized: "\(Int(trim.width)) × \(Int(trim.height)) mm · 3 mm bleed · 300 dpi · CMYK · 2-page PDF")
    }

    private var subtitle: String? {
        let parts = [item.effectiveCaptureDate?.formatted(date: .long, time: .omitted), item.namedPlace].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Loading and export

    private func loadPhoto() async {
        guard !didLoad else { return }
        didLoad = true
        content.stampLabel = String(localized: "Stamp")
        content.message = PostcardText.defaultMessage(from: item.memories.map {
            PostcardText.Memory(text: $0.text, createdAt: $0.createdAt)
        })
        applyCaptions()
        // The photo as the viewer shows it; the thumbnail when that cannot be
        // read (the sheet then says the photo is small).
        var image = await PhotoViewerImageCache.shared.load(item, allowDownload: true)
        if image == nil {
            image = await ThumbnailCache.shared.image(for: item, width: 1_600, height: 1_200)
        }
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorText = String(localized: "The photo could not be loaded.")
            renderPreview()
            return
        }
        photo = cgImage
        previewPhoto = Self.scaled(cgImage, maximumSide: 1_000)
        content.orientation = PostcardOrientation(pixelWidth: cgImage.width, pixelHeight: cgImage.height)
        renderPreview()
    }

    private func applyCaptions() {
        let date = item.effectiveCaptureDate?.formatted(.dateTime.year().month(.defaultDigits).day())
        content.dateText = showDate ? date : nil
        content.placeText = showPlace ? item.namedPlace : nil
    }

    private static func scaled(_ image: CGImage, maximumSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maximumSide else { return image }
        let factor = Double(maximumSide) / Double(longest)
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func export() {
        guard let photo, !isExporting else { return }
        errorText = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName + ".pdf"
        let snapshot = content
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            Task {
                let data = await Task.detached(priority: .userInitiated) {
                    PostcardRenderer.pdfData(snapshot, image: photo)
                }.value
                isExporting = false
                do {
                    guard let data else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url, options: .atomic)
                    savedFolder = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    errorText = String(localized: "Couldn't save the postcard: \(error.localizedDescription)")
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private var fileName: String {
        guard let date = item.effectiveCaptureDate else { return String(localized: "Postcard") }
        let day = date.formatted(.iso8601.year().month().day())
        return String(localized: "Postcard \(day)")
    }
}

/// The little picture of a style on its button.
private struct TemplateThumbnail: View {
    let template: PostcardTemplate

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let photo = PostcardFrontLayout(template: template, orientation: .landscape).photo
            let page = PostcardRenderer.spec.pageSize(.landscape)
            let sx = size.width / page.width
            let sy = size.height / page.height
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(red: 0.992, green: 0.980, blue: 0.965))
                LinearGradient(colors: [Color(red: 0.95, green: 0.79, blue: 0.64), Color(red: 0.37, green: 0.59, blue: 0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(width: photo.width * sx, height: photo.height * sy)
                    .offset(x: photo.minX * sx, y: photo.minY * sy)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .aspectRatio(154.0 / 106.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
