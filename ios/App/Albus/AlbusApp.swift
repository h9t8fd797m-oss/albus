import SwiftUI
import SwiftData
import AlbusCore

@main
struct AlbusApp: App {
    /// Built once at launch, with two fallbacks.
    ///
    /// The previous version called `fatalError` here on the reasoning that
    /// there is no recovery without a store. That is wrong in the case that
    /// actually happens: an unreadable store — corruption, a disk full at the
    /// wrong moment, an incompatible schema after an update — would crash the
    /// app on every launch, forever, with no message. The only way out for a
    /// student is to delete the app, which destroys the same local data a
    /// rebuild would have, and loses them the app in the meantime.
    ///
    /// So: try the real store; if it will not open, move it aside and start a
    /// fresh one; if even that fails, run in memory. Local data is a cache of
    /// work the server also holds, so the worst case is a re-sync, not a loss.
    private let container: ModelContainer

    init() {
        container = Self.makeContainer(schema: AlbusSchema.schema)
    }

    private static func makeContainer(schema: Schema) -> ModelContainer {
        let onDisk = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: onDisk)
        } catch {
            print("[Albus] Local store would not open: \(error). Rebuilding it.")
        }

        // Second attempt: quarantine whatever is there and start clean. Renamed
        // rather than deleted so a corrupt store can still be recovered by hand
        // if a student reports losing something.
        quarantineStore(at: onDisk.url)
        do {
            return try ModelContainer(for: schema, configurations: onDisk)
        } catch {
            print("[Albus] Rebuilt store still would not open: \(error). Running in memory.")
        }

        // Last resort: an in-memory store. The app works for this launch and
        // re-syncs; a crash here would be strictly worse than a session that
        // does not persist.
        do {
            return try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        } catch {
            // Unreachable short of the schema itself being invalid, which is a
            // programming error a build cannot ship past unnoticed.
            fatalError("The data model itself is invalid: \(error)")
        }
    }

    private static func quarantineStore(at url: URL) {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        // SQLite keeps its write-ahead log and shared-memory file alongside the
        // store; leaving those behind would corrupt the replacement too.
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            let moved = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)" + suffix)
            try? fm.moveItem(at: file, to: moved)
        }
    }

    @State private var session = SessionService()
    @State private var coordinator = PlanCoordinator()
    @State private var preferences = Preferences()
    @State private var entitlements = EntitlementService()
    @State private var focusSession = FocusSession()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                // No dark palette exists in the designs yet, and a half-applied
                // one looks worse than none. Locked until dark is designed.
                .preferredColorScheme(.light)
                .environment(session)
                .environment(coordinator)
                .environment(preferences)
                .environment(entitlements)
                .environment(focusSession)
                .task {
                    // Before anything async, so the plan is already correct by
                    // the time the first screen draws.
                    catchUp()
                    // Restores a stored session. It no longer *creates* one:
                    // account creation moved into onboarding, which is the only
                    // place a CAPTCHA challenge can be presented.
                    await session.start()
                    // Only meaningful once signed in; refresh reads the
                    // caller's own row and no-ops otherwise.
                    await entitlements.refresh()
                    // Anything deleted while offline. No-ops with nothing
                    // pending, and until it lands those rows still count
                    // against the student's active-plan limit.
                    await PendingDeletions.flush()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    catchUp()
                }
        }
        .modelContainer(container)
    }

    /// Re-home anything whose window passed while the app was away.
    ///
    /// This used to live in a `.task` on Home, which runs on *view appearance*
    /// — so it fired on a cold launch and on returning to the Home tab, but not
    /// on the case it exists for: coming back to the app days later with Home
    /// already on screen. Nothing was swept, and the student saw a plan still
    /// pointing at time that had already gone.
    ///
    /// Cheap and idempotent by design: it writes only when something actually
    /// changed, so running it on every foreground costs one fetch.
    @MainActor
    private func catchUp() {
        coordinator.sweepMissedSessions(context: container.mainContext,
                                        availability: preferences.availability)
    }
}
