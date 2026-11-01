import SwiftUI
import SwiftData

@main
struct MomentsApp: App {
    #if DEBUG
    @NSApplicationDelegateAdaptor(UnitTestHostDelegate.self) private var unitTestHostDelegate
    #endif
    private let modelContainer: ModelContainer?
    private let storeError: MomentsStoreError?
    @State private var selection = SelectionModel()
    @State private var libraryState = LibraryViewState()
    @State private var importController = ImportController()
    @State private var noteService = PhotoNoteService()
    @State private var peopleController = PeopleScanController()
    @State private var photoStacks = PhotoStackModel()
    @State private var stackAnalyzer = PhotoStackAnalyzer()
    @State private var projectionStore = LibraryProjectionStore()
    @State private var photosImportController = PhotosImportController(importer: PhotosImporter(source: PhotoKitAssetSource()))
    @State private var showingPhotosImport = false

    #if DEBUG
    private var isUITestSmallWindow: Bool {
        ProcessInfo.processInfo.arguments.contains("-MomentsUITestSmallWindow")
    }

    /// -MomentsUITestStartSmall: opens at 900 × 600 but, unlike
    /// -MomentsUITestSmallWindow, can be resized and zoomed afterwards.
    private var isUITestStartSmall: Bool {
        ProcessInfo.processInfo.arguments.contains("-MomentsUITestStartSmall")
    }

    /// -MomentsUITestWindowWidth <points>: a fixed window width, e.g. maple's 1111.
    private var uiTestWindowWidth: CGFloat? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestWindowWidth"), index + 1 < arguments.count,
              let width = Double(arguments[index + 1]) else { return nil }
        return CGFloat(width)
    }

    private var isUITestDarkMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-MomentsUITestDarkMode")
    }

    private static var uiTestStoreDirectory: URL? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-MomentsUITestStoreDirectory"),
              index + 1 < ProcessInfo.processInfo.arguments.count else {
            return nil
        }
        let path = ProcessInfo.processInfo.arguments[index + 1]
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `-MomentsUITestStressCount <n>` adds n synthetic items for scrolling checks.
    private static var uiTestStressCount: Int? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-MomentsUITestStressCount"),
              index + 1 < ProcessInfo.processInfo.arguments.count else { return nil }
        return Int(ProcessInfo.processInfo.arguments[index + 1])
    }

    /// `-MomentsUITestStressSpacing <seconds>` spaces them out in time (two
    /// minutes apart otherwise), so grouping by month gives many small sections.
    private static var uiTestStressSpacing: TimeInterval {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-MomentsUITestStressSpacing"),
              index + 1 < ProcessInfo.processInfo.arguments.count else { return 120 }
        return TimeInterval(ProcessInfo.processInfo.arguments[index + 1]) ?? 120
    }
    #endif

    init() {
        _ = AppLanguage.atLaunch
        #if DEBUG
        // Each UI test starts at the default photos per row (or its launch
        // argument), whatever an earlier test chose with − and +.
        if ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") {
            UserDefaults.standard.removeObject(forKey: LibraryThumbnailSize.storageKey)
            UserDefaults.standard.removeObject(forKey: LibraryThumbnailSize.legacyLevelKey)
        }
        #endif
        LibraryThumbnailSize.migrateLegacyLevel()
        #if DEBUG
        FlashProbe.startIfRequested()
        ScrollProbe.startIfRequested()
        ResizeProbe.startIfRequested()
        PageProbe.startIfRequested()
        StressLibrary.prepareIfRequested()
        #endif
        do {
            #if DEBUG
            // Tests must never touch the user's store: -MomentsUITesting
            // uses an in-memory store, -MomentsUITestStoreDirectory a
            // throwaway on-disk store that survives relaunches.
            // A unit-test host must not open the user's store either.
            let isUnitTestHost = UnitTestHostDelegate.isUnitTestHost
            let testStoreDirectory = Self.uiTestStoreDirectory
            let testStoreURL = testStoreDirectory?.appending(path: "Moments.store")
            let isUITesting = ProcessInfo.processInfo.arguments.contains("-MomentsUITesting")
                || (isUnitTestHost && testStoreURL == nil)
            // Filters live in user defaults; a test run starts without the
            // ones a previous run left behind.
            if isUITesting { LibraryFilterKeys.clearAll() }
            let container: ModelContainer
            if isUITesting || testStoreURL != nil {
                container = try MomentsPersistence.makeContainer(inMemory: isUITesting, url: testStoreURL)
            } else {
                container = try Self.openUserStore()
            }
            #else
            let container = try Self.openUserStore()
            #endif
            #if DEBUG
            // The on-disk UI-test store holds only what the test imports.
            if Self.uiTestStoreDirectory == nil {
                try? DemoSeeder.seedIfNeeded(context: container.mainContext)
                if ProcessInfo.processInfo.arguments.contains("-MomentsUITestReviewItems") {
                    try? DemoSeeder.flagUndatedDemoItemsForReview(context: container.mainContext)
                }
                if ProcessInfo.processInfo.arguments.contains("-MomentsUITestPeople") {
                    try? DemoSeeder.seedPeopleForUITests(context: container.mainContext)
                }
                if ProcessInfo.processInfo.arguments.contains("-MomentsUITestBurst") {
                    try? DemoSeeder.addSyntheticBurst(context: container.mainContext)
                }
                if ProcessInfo.processInfo.arguments.contains("-MomentsUITestImportSource") {
                    try? DemoSeeder.addSyntheticImportSource(context: container.mainContext)
                }
            }
            if isUITesting || testStoreURL != nil, let count = Self.uiTestStressCount {
                try? DemoSeeder.generateSyntheticLibrary(count: count, spacing: Self.uiTestStressSpacing, context: container.mainContext)
            }
            #endif
            modelContainer = container
            storeError = nil
        } catch let error as MomentsStoreError {
            modelContainer = nil
            storeError = error
        } catch {
            modelContainer = nil
            storeError = nil
        }
    }

    /// Opens the user's store; an unreadable store is backed up and replaced
    /// with a new empty one, and the user is told once where the backup is.
    private static func openUserStore() throws -> ModelContainer {
        try MomentsPersistence.openWithRecovery().container
    }

    @ViewBuilder
    private var appContent: some View {
        // The B1 paper design is light only; sheets inherit the window's appearance.
        Group {
            if let modelContainer {
                ContentView(libraryState: libraryState)
                    .environment(selection)
                    .environment(importController)
                    .environment(noteService)
                    .environment(peopleController)
                    .environment(photoStacks)
                    .environment(projectionStore)
                    .modelContainer(modelContainer)
                    .onAppear {
                        importController.configure(container: modelContainer)
                        peopleController.configure(container: modelContainer)
                        photosImportController.configure(container: modelContainer)
                        stackAnalyzer.configure(container: modelContainer)
                        stackAnalyzer.analyzeIfNeeded()
                        photoStacks.refresh(container: modelContainer)
                        projectionStore.refresh(container: modelContainer)
                        #if DEBUG
                        PageProbe.attach(container: modelContainer, selection: selection, people: peopleController, stacks: stackAnalyzer)
                        StressLibrary.startIfRequested(container: modelContainer)
                        #endif
                    }
                    // Map and Chapters only read the stacks, so new results
                    // are folded in here, whichever screen is showing.
                    .onChange(of: photoStacks.analysisRevision) {
                        photoStacks.analysisChanged()
                    }
                    // Posted after every import: new photos may be bursts.
                    .onReceive(NotificationCenter.default.publisher(for: .momentsPeopleScanRequested)) { _ in
                        peopleController.scanIfNeeded()
                        stackAnalyzer.analyzeIfNeeded()
                        photoStacks.refresh(container: modelContainer)
                        projectionStore.refresh(container: modelContainer)
                    }
                    // Every SwiftData save can change dates, coordinates,
                    // place names, notes or deletion state. Coalesce bursts
                    // of saves so the shared read model catches up without
                    // rebuilding once per edited field or import batch.
                    .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
                        projectionStore.scheduleRefresh(container: modelContainer)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .momentsShowPhotosImport)) { _ in
                        showingPhotosImport = true
                    }
                    .sheet(isPresented: $showingPhotosImport) {
                        PhotosImportSheet(controller: photosImportController)
                    }
                    .modifier(StoreRecoveryAlert())
                    #if DEBUG
                    .frame(width: uiTestWindowWidth ?? (isUITestSmallWindow ? 900 : nil), height: isUITestSmallWindow ? 600 : nil)
                    .onAppear {
                        // Simulates a Mac in Dark Mode; the window below must stay light.
                        if isUITestDarkMode { NSApp.appearance = NSAppearance(named: .darkAqua) }
                        if isUITestStartSmall {
                            DispatchQueue.main.async {
                                NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 900, height: 600))
                            }
                        }
                    }
                    #endif
            } else {
                StoreUnavailableView(isProtectedLegacyStore: storeError != nil)
            }
        }
        .preferredColorScheme(.light)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UnitTestHostDelegate.isUnitTestHost {
                // Unit tests only need the process; render nothing and keep the window hidden.
                UnitTestHostWindowHider()
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Folder…") { importController.chooseFolder() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Import from Apple Photos…") { showingPhotosImport = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings {
            Group {
                if let modelContainer {
                    SettingsView(hasStore: true)
                        .modelContainer(modelContainer)
                } else {
                    SettingsView(hasStore: false)
                }
            }
            .environment(peopleController)
            .environment(photosImportController)
            .preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)
    }
}

private struct StoreUnavailableView: View {
    let isProtectedLegacyStore: Bool

    var body: some View {
        ContentUnavailableView(
            "Moments store unavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text(
                isProtectedLegacyStore
                    ? String(localized: "A legacy store contains non-demo data. It was left untouched; back it up before migrating.")
                    : String(localized: "Moments could not open its local store. Your existing data was left untouched.")
            )
        )
        .frame(minWidth: 520, minHeight: 280)
        .padding(32)
    }
}

/// One-time notice after an unreadable store was moved to a backup folder.
private struct StoreRecoveryAlert: ViewModifier {
    @AppStorage(StoreRecoveryNotice.defaultsKey) private var backupPath = ""

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "Your library couldn't be opened"),
            isPresented: Binding(get: { !backupPath.isEmpty }, set: { if !$0 { backupPath = "" } })
        ) {
            Button(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting(backupPaths.map { URL(fileURLWithPath: $0) })
                backupPath = ""
            }
            Button(String(localized: "OK"), role: .cancel) { backupPath = "" }
        } message: {
            Text(String(format: String(localized: "Moments couldn't open its data, so it saved a copy to %@ and started a new, empty library. Your original photos are not affected."), displayedPaths))
        }
    }

    private var backupPaths: [String] {
        backupPath.split(separator: "\n").map(String.init)
    }

    private var displayedPaths: String {
        backupPaths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
    }
}
