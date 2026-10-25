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
    @State private var photosImportController = PhotosImportController(importer: PhotosImporter(source: PhotoKitAssetSource()))
    @State private var showingPhotosImport = false

    #if DEBUG
    private var isUITestSmallWindow: Bool {
        ProcessInfo.processInfo.arguments.contains("-MomentsUITestSmallWindow")
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
    #endif

    init() {
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
            let container = try MomentsPersistence.makeContainer(
                inMemory: isUITesting,
                url: testStoreURL
            )
            #else
            let container = try MomentsPersistence.makeContainer()
            #endif
            #if DEBUG
            // The on-disk UI-test store holds only what the test imports.
            if Self.uiTestStoreDirectory == nil {
                try? DemoSeeder.seedIfNeeded(context: container.mainContext)
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

    @ViewBuilder
    private var appContent: some View {
        // The B1 paper design is light only; sheets inherit the window's appearance.
        Group {
            if let modelContainer {
                ContentView(libraryState: libraryState)
                    .environment(selection)
                    .environment(importController)
                    .modelContainer(modelContainer)
                    .onAppear {
                        importController.configure(container: modelContainer)
                        photosImportController.configure(container: modelContainer)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .momentsShowPhotosImport)) { _ in
                        showingPhotosImport = true
                    }
                    .sheet(isPresented: $showingPhotosImport) {
                        PhotosImportSheet(controller: photosImportController)
                    }
                    #if DEBUG
                    .frame(width: isUITestSmallWindow ? 900 : nil, height: isUITestSmallWindow ? 600 : nil)
                    .onAppear {
                        // Simulates a Mac in Dark Mode; the window below must stay light.
                        if isUITestDarkMode { NSApp.appearance = NSAppearance(named: .darkAqua) }
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
                    ? "A legacy store contains non-demo data. It was left untouched; back it up before migrating."
                    : "Moments could not open its local store. Your existing data was left untouched."
            )
        )
        .frame(minWidth: 520, minHeight: 280)
        .padding(32)
    }
}
