import SwiftUI
import SwiftData

@main
struct MomentsApp: App {
    private let modelContainer: ModelContainer?
    private let storeError: MomentsStoreError?
    @State private var selection = SelectionModel()
    @State private var libraryState = LibraryViewState()
    @State private var importController = ImportController()

    init() {
        do {
            let container = try MomentsPersistence.makeContainer()
            #if DEBUG
            try? DemoSeeder.seedIfNeeded(context: container.mainContext)
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
