import SwiftUI
import SwiftData

@main
struct MomentsApp: App {
    private let modelContainer: ModelContainer?
    private let storeError: MomentsStoreError?
    @State private var selection = SelectionModel()
    @State private var libraryState = LibraryViewState()
    @State private var importController = ImportController()

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
            let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                ContentView(libraryState: libraryState)
                    .environment(selection)
                    .environment(importController)
                    .modelContainer(modelContainer)
                    .onAppear { importController.configure(container: modelContainer) }
                    #if DEBUG
                    .frame(width: isUITestSmallWindow ? 900 : nil, height: isUITestSmallWindow ? 600 : nil)
                    .preferredColorScheme(isUITestDarkMode ? .dark : nil)
                    #endif
            } else {
                StoreUnavailableView(isProtectedLegacyStore: storeError != nil)
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Folder…") { importController.chooseFolder() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
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
