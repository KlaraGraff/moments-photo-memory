import SwiftUI
import MomentsCore

/// A slim bar at the bottom of Chapters while the model organizes, and
/// after: how many chapters it made, with Undo.
struct ChapterAIStatusBar: View {
    @Environment(ChapterAIController.self) private var chapterAI

    var body: some View {
        switch chapterAI.state {
        case .idle:
            EmptyView()
        case let .running(progress):
            bar {
                ProgressView().controlSize(.small)
                Text(Self.text(for: progress))
                    .foregroundStyle(Paper.ink)
                    .monospacedDigit()
                    .accessibilityIdentifier("chapterAI.progress")
                Spacer(minLength: 8)
            }
        case let .done(message):
            bar {
                Image(systemName: "sparkles")
                    .foregroundStyle(Paper.accent)
                Text(message)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(2)
                    .accessibilityIdentifier("chapterAI.done")
                Spacer(minLength: 8)
                if chapterAI.lastRun != nil {
                    Button(String(localized: "Undo")) { chapterAI.undoLastRun() }
                        .accessibilityIdentifier("chapterAI.undo")
                }
                closeButton
            }
        case let .failed(message):
            bar {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Paper.muted)
                Text(message)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(3)
                Spacer(minLength: 8)
                closeButton
            }
        }
    }

    static func text(for progress: ChapterAIOrganizer.Progress) -> String {
        switch progress.phase {
        case .describing where progress.total > 0:
            return String(localized: "Looking at photos · \(progress.done) of \(progress.total)")
        case .describing:
            return String(localized: "Getting ready…")
        case .organizing:
            return String(localized: "Finding chapters · \(progress.done) of \(progress.total)")
        case .writing:
            return String(localized: "Writing chapters…")
        }
    }

    private var closeButton: some View {
        Button { chapterAI.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Paper.muted)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Close"))
        .accessibilityLabel(String(localized: "Close"))
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: 560)
            .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Paper.shadow.opacity(0.06), radius: 1, y: 1)
            .shadow(color: Paper.shadow.opacity(0.12), radius: 14, y: 5)
            .padding(.horizontal, 16)
    }
}

/// The Chapters toolbar button that has the model organize the library again.
struct ChapterAIToolbarButton: View {
    @Environment(ChapterAIController.self) private var chapterAI
    @AppStorage(ChapterAISettings.enabledKey) private var isEnabled = true

    var body: some View {
        if isEnabled {
            Button { chapterAI.organizeLibrary() } label: {
                Label(String(localized: "Organize with AI"), systemImage: "sparkles")
            }
            .disabled(chapterAI.isRunning)
            .help(String(localized: "Organize with AI"))
            .accessibilityIdentifier("chapterAI.organize")
        }
    }
}

/// Settings › AI Model › Chapters.
struct ChapterAISettingsSection: View {
    @AppStorage(ChapterAISettings.enabledKey) private var isEnabled = true
    @AppStorage(ChapterAISettings.visionKey) private var visionRaw = ChapterAIVision.allPhotos.rawValue

    var body: some View {
        Section {
            Toggle(String(localized: "Organize Chapters with AI"), isOn: $isEnabled)
            Picker(String(localized: "What the model looks at"), selection: $visionRaw) {
                Text(String(localized: "Every photo")).tag(ChapterAIVision.allPhotos.rawValue)
                Text(String(localized: "A few photos a day")).tag(ChapterAIVision.sampled.rawValue)
                Text(String(localized: "No photos, text only")).tag(ChapterAIVision.textOnly.rawValue)
            }
            .disabled(!isEnabled)
        } header: {
            Text(String(localized: "Chapters"))
        } footer: {
            Text(String(localized: "Uses your Anthropic key. Small copies of your photos without location data, place names, people's names and your notes are sent to Anthropic. Photos kept only in iCloud are skipped. Each photo is looked at once: about US$0.25 for 5,000 photos with Haiku."))
        }
    }
}
