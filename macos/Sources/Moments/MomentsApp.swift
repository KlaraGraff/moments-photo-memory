import SwiftUI
import SwiftData

@main
struct MomentsApp: App {
    private let modelContainer: ModelContainer
    @State private var selection = SelectionModel()
    @State private var libraryState = LibraryViewState()

    init() {
        do {
            let container = try MomentsPersistence.makeContainer()
            #if DEBUG
            try? DemoSeeder.seedIfNeeded(context: container.mainContext)
            #endif
            modelContainer = container
        } catch {
            fatalError("Unable to create the Moments model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(libraryState: libraryState)
                .environment(selection)
        }
        .modelContainer(modelContainer)
    }
}
