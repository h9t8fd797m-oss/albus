import SwiftUI
import AlbusCore

@main
struct AlbusApp: App {
    var body: some Scene {
        WindowGroup {
            AppShell()
                // No dark palette exists in the designs yet, and a half-applied
                // one looks worse than none. Locked until dark is designed.
                .preferredColorScheme(.light)
        }
    }
}
