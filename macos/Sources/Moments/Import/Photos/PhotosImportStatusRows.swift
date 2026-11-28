import SwiftUI

/// Apple Photos in the window's import status bar: an import running, how it
/// ended once the import sheet is closed, new photos found in Photos (also
/// those added while Moments was closed), photos deleted in Photos, and
/// photos found again after the library moved to another Mac. Each line uses
/// the folder import's own row style.
struct PhotosImportStatusRows: View {
    @Environment(PhotosImportController.self) private var photos

    /// Whether there is anything to show, so an empty bar takes no room.
    static func hasContent(_ photos: PhotosImportController) -> Bool {
        photos.state == .importing
            || photos.showsResult
            || showsNewPhotos(photos)
            || photos.showsMissingNotice
            || photos.relinkedCount > 0
    }

    private static func showsNewPhotos(_ photos: PhotosImportController) -> Bool {
        !photos.pendingNewAssetIdentifiers.isEmpty && !photos.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if photos.state == .importing {
                row {
                    if let fraction = photos.progress.fraction {
                        ProgressView(value: fraction)
                            .frame(width: 120)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(photos.progress.message)
                        .lineLimit(1)
                    Text("\(photos.progress.completed)/\(photos.progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Paper.muted)
                    Button("Cancel") { photos.cancel() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("photosImport.cancel")
                }
                .accessibilityIdentifier("photosImport.progress")
            } else if photos.showsResult {
                row {
                    switch photos.state {
                    case .finished:
                        if let summary = photos.summary {
                            Text(String(localized: "\(summary.importedCount) imported · \(summary.skippedCount) already present"))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    case .cancelled:
                        Text(photos.progress.message)
                            .lineLimit(1)
                        Button("Resume") { photos.retry() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("photosImport.resume")
                    case .failed(let message):
                        Text(message)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .help(message)
                        Button("Try Again") { photos.retry() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("photosImport.retry")
                    default:
                        EmptyView()
                    }
                    closeButton("photosImport.result.close") { photos.dismissResult() }
                }
                .accessibilityIdentifier("photosImport.result")
            }
            if Self.showsNewPhotos(photos) {
                row {
                    Text(String(localized: "\(photos.pendingNewAssetIdentifiers.count) new photos in Apple Photos"))
                        .monospacedDigit()
                        .lineLimit(1)
                    Button("Import new photos") { photos.importPendingChanges() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("photosImport.importNew")
                }
                .accessibilityIdentifier("photosImport.newPhotos")
            }
            if photos.showsMissingNotice {
                row {
                    Text(String(localized: "\(photos.missingAssetCount) photos are no longer in Apple Photos"))
                        .monospacedDigit()
                        .lineLimit(1)
                    closeButton("photosImport.missing.close") { photos.dismissMissingNotice() }
                }
                .accessibilityIdentifier("photosImport.missing")
            }
            if photos.relinkedCount > 0 {
                row {
                    Text(String(localized: "Found \(photos.relinkedCount) photos again in Apple Photos"))
                        .monospacedDigit()
                        .lineLimit(1)
                    closeButton("photosImport.relinked.close") { photos.dismissRelinked() }
                }
                .accessibilityIdentifier("photosImport.relinked")
            }
        }
    }

    /// One line: the Apple Photos mark, then what it says.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle")
                .foregroundStyle(Paper.muted)
                .accessibilityHidden(true)
            content()
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
    }

    private func closeButton(_ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Paper.muted)
        .help(String(localized: "Close"))
        .accessibilityLabel(String(localized: "Close"))
        .accessibilityIdentifier(identifier)
    }
}
