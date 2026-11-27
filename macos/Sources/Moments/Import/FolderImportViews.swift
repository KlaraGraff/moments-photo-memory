import SwiftUI
import UniformTypeIdentifiers

/// Folders that were imported and can't be found any more, one line each
/// in the Library's import status bar, with a way to show Moments where the
/// folder is now. At most three, so the bar stays small at 900×600.
struct MissingFolderRows: View {
    @Environment(ImportController.self) private var controller

    var body: some View {
        if !controller.missingFolders.isEmpty, !controller.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(controller.missingFolders.prefix(3)) { folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.questionmark")
                            .foregroundStyle(Paper.muted)
                            .accessibilityHidden(true)
                        Text(String(localized: "Can't find the folder “\(folder.name)”"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Locate…") { controller.locate(folder) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("import.missingFolder.locate")
                        Button {
                            controller.dismissMissingFolder(folder)
                        } label: {
                            Image(systemName: "xmark")
                                .imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Paper.muted)
                        .help(String(localized: "Close"))
                        .accessibilityLabel(String(localized: "Close"))
                        .accessibilityIdentifier("import.missingFolder.close")
                    }
                    .font(.caption)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("import.missingFolder")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Folders, photos and videos dragged from Finder onto the window are
/// imported, as with Import Folder…. While something is dragged over the
/// window, a frame says what letting go does.
struct ImportDropTarget: ViewModifier {
    @Environment(ImportController.self) private var controller
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, !controller.isRunning else { return false }
                controller.importDropped(files)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted && !controller.isRunning
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Paper.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(Paper.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            Label(String(localized: "Drop to import"), systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .foregroundStyle(Paper.accent)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Paper.content, in: Capsule())
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("import.dropTarget")
                }
            }
    }
}
