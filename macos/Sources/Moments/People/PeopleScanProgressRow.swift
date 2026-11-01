import SwiftUI

/// The scan progress row, in a view of its own so a progress tick redraws only
/// this row instead of the whole People page body with every card.
struct PeopleScanProgressRow: View {
    @Environment(PeopleScanController.self) private var scanner

    var body: some View {
        if scanner.isScanning || scanner.progress.total > 0 && scanner.progress.completed < scanner.progress.total {
            HStack(spacing: 9) {
                if scanner.progress.isPaused { ProgressView().controlSize(.small) } else { ProgressView(value: Double(scanner.progress.completed), total: Double(max(scanner.progress.total, 1))).frame(width: 130) }
                Text(String(format: String(localized: "Finding faces progress"), scanner.progress.completed, scanner.progress.total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Paper.muted)
                if scanner.progress.skippedUnavailable > 0 {
                    Text(String(format: String(localized: "Skipped unavailable"), scanner.progress.skippedUnavailable))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Paper.muted)
                }
                if scanner.progress.isPaused { Text(String(localized: "Paused to save battery")).font(.caption).foregroundStyle(Paper.muted) }
                Button(String(localized: "Cancel")) { scanner.cancel() }.buttonStyle(.borderless)
            }
        }
    }
}
