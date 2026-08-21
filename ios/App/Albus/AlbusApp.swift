import SwiftUI
import SwiftData
import AlbusCore

@main
struct AlbusApp: App {
    /// Built once at launch. A schema mistake surfaces here as a crash rather
    /// than a compile error, which is exactly why the app is launched in CI-
    /// adjacent verification and not just built.
    private let container: ModelContainer

    init() {
        let schema = Schema([
            Course.self, Assignment.self, Subtask.self,
            PlanSessionRecord.self, CompletionRecord.self
        ])
        do {
            container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            )
        } catch {
            // No recovery is possible without a store, and continuing would
            // mean silently losing every write. Fail loudly instead.
            fatalError("Could not open the local store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                // No dark palette exists in the designs yet, and a half-applied
                // one looks worse than none. Locked until dark is designed.
                .preferredColorScheme(.light)
        }
        .modelContainer(container)
    }
}
