import SwiftUI
import SwiftData

/// Runs the four "reorganize" jobs — chapters, places, bursts and people —
/// one after another, so a page can offer them behind one button. Only one
/// run at a time; a finished run shows a short toast.
@MainActor
@Observable
final class ReorganizeController {
    enum Kind: Hashable {
        case all
        case people
        case places
        case chapters

        var identifier: String {
            switch self {
            case .all: return "reorganize.all"
            case .people: return "reorganize.people"
            case .places: return "reorganize.places"
            case .chapters: return "reorganize.chapters"
            }
        }

        var title: String {
            switch self {
            case .all: return String(localized: "Reorganize all memories")
            case .people: return String(localized: "Regroup people")
            case .places: return String(localized: "Fill in places again")
            case .chapters: return String(localized: "Rearrange chapters")
            }
        }

        /// One line on what the run does.
        var summary: String {
            switch self {
            case .all:
                return String(localized: "Rearranges chapters, fills in places, finds bursts and regroups people, one after another.")
            case .people:
                return String(localized: "Groups all faces again by the current rules and asks the “same person?” questions again.")
            case .places:
                return String(localized: "Looks up names for places that have none yet.")
            case .chapters:
                return String(localized: "Regroups trips, long stays, frequent places and big days by the latest rules.")
            }
        }

        /// One muted line on what stays as it is.
        var kept: String {
            switch self {
            case .all:
                return String(localized: "What you confirmed on each page stays: named people, chapters you changed, stacks you split.")
            case .people:
                return String(localized: "Named people and faces you confirmed stay, and so do your yes/no answers. Hidden people, skipped questions and loose faces are regrouped.")
            case .places:
                return String(localized: "Place names you typed stay as they are.")
            case .chapters:
                return String(localized: "Chapters you renamed, adjusted, or gave a cover or memory stay, and so do photos you moved by hand. Big days you deleted are considered again.")
            }
        }
    }

    private(set) var running: Kind?
    private(set) var stepText = ""
    private(set) var lastResult: String?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private weak var people: PeopleScanController?
    @ObservationIgnored private weak var stacks: PhotoStackAnalyzer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var toast: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var startedPeopleScan = false

    func configure(container: ModelContainer, people: PeopleScanController, stacks: PhotoStackAnalyzer) {
        self.container = container
        self.people = people
        self.stacks = stacks
    }

    /// Starts a run; a second run while one is going is ignored.
    func run(_ kind: Kind, allPlaces: Bool = false) {
        guard running == nil, let container else { return }
        let id = UUID()
        runID = id
        running = kind
        startedPeopleScan = false
        lastResult = nil
        stepText = Self.stepText(kind, step: 1)
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.perform(kind, allPlaces: allPlaces, container: container)
            self.finish(result, id: id)
        }
    }

    /// Stops the run. Steps that already finished keep their result.
    func stop() {
        runID = UUID()
        task?.cancel()
        task = nil
        if startedPeopleScan {
            people?.cancel()
            startedPeopleScan = false
        }
        running = nil
        stepText = ""
        lastResult = nil
        show(String(localized: "Stopped"))
    }

    private func perform(_ kind: Kind, allPlaces: Bool, container: ModelContainer) async -> String {
        do {
            switch kind {
            case .all:
                stepText = Self.stepText(.all, step: 1)
                _ = try ChapterReorganize.run(context: container.mainContext)
                try Task.checkCancellation()
                stepText = Self.stepText(.all, step: 2)
                _ = try await PlaceReorganize.run(container: container, all: false)
                try Task.checkCancellation()
                stepText = Self.stepText(.all, step: 3)
                stacks?.reanalyzeAll()
                try Task.checkCancellation()
                stepText = Self.stepText(.all, step: 4)
                try regroupPeople(context: container.mainContext)
            case .chapters:
                stepText = Self.stepText(.chapters, step: 1)
                _ = try ChapterReorganize.run(context: container.mainContext)
            case .places:
                stepText = Self.stepText(.places, step: 1)
                _ = try await PlaceReorganize.run(container: container, all: allPlaces)
            case .people:
                stepText = Self.stepText(.people, step: 1)
                try regroupPeople(context: container.mainContext)
            }
            return String(localized: "Finished")
        } catch is CancellationError {
            return String(localized: "Stopped")
        } catch {
            return String(localized: "Could not finish")
        }
    }

    private func regroupPeople(context: ModelContext) throws {
        _ = try PeopleReorganize.reset(context: context)
        startedPeopleScan = true
        people?.start()
    }

    private func finish(_ result: String, id: UUID) {
        guard runID == id else { return }
        task = nil
        running = nil
        stepText = ""
        startedPeopleScan = false
        show(result)
    }

    private func show(_ text: String) {
        lastResult = text
        toast?.cancel()
        toast = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Motion.confirmationLifetime)
            guard !Task.isCancelled else { return }
            self?.lastResult = nil
        }
    }

    private static func stepText(_ kind: Kind, step: Int) -> String {
        switch (kind, step) {
        case (.all, 1): return String(localized: "1/4 Arranging chapters…")
        case (.all, 2): return String(localized: "2/4 Filling in places…")
        case (.all, 3): return String(localized: "3/4 Looking for bursts…")
        case (.all, 4): return String(localized: "4/4 Regrouping people…")
        case (.chapters, _): return String(localized: "Arranging chapters…")
        case (.places, _): return String(localized: "Filling in places…")
        default: return String(localized: "Regrouping people…")
        }
    }
}

/// The toolbar button of a page: a bordered "reorganize" button that asks
/// first, then shows the running step and a stop button.
struct ReorganizeToolbarButton: View {
    let kind: ReorganizeController.Kind

    @Environment(ReorganizeController.self) private var controller
    @Environment(ImportController.self) private var importController
    @Environment(PhotosImportController.self) private var photosImportController
    @State private var showingOptions = false
    @State private var allPlaces = false

    private var isImporting: Bool {
        importController.isRunning || photosImportController.isRunning
    }

    var body: some View {
        HStack(spacing: 8) {
            if controller.running == nil, let result = controller.lastResult {
                // The short result of the last run stays for 2.5 seconds.
                Text(result)
                    .font(.callout)
                    .foregroundStyle(Paper.muted)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if controller.running != nil {
                runningRow
            } else {
                button
            }
        }
        .accessibilityIdentifier(kind.identifier)
    }

    private var button: some View {
        Button {
            showingOptions = true
        } label: {
            Label(kind.title, systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .disabled(isImporting)
        .help(isImporting ? String(localized: "You can reorganize once the import has finished") : kind.title)
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            options
        }
    }

    private var runningRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(controller.stepText)
                .font(.callout)
                .foregroundStyle(Paper.muted)
                .lineLimit(1)
            Button(String(localized: "Stop")) {
                controller.stop()
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(kind.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Paper.ink)
                Text(verbatim: "?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Paper.muted)
                    .accessibilityHidden(true)
            }
            Text(kind.summary)
                .font(.callout)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(kind.kept)
                .font(.callout)
                .foregroundStyle(Paper.muted)
                .fixedSize(horizontal: false, vertical: true)
            if kind == .places {
                Toggle(String(localized: "Look up every place again (about one a second; slow with many places)"), isOn: $allPlaces)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(String(localized: "Cancel")) { showingOptions = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Start")) {
                    showingOptions = false
                    controller.run(kind, allPlaces: allPlaces)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
