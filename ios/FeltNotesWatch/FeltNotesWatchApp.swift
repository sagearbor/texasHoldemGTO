import SwiftUI

/// Felt Notes Pulse: streams the player's heart rate to their iPhone during a
/// Pulse game night (docs/PULSE.md).
@main
struct FeltNotesWatchApp: App {
    @StateObject private var pulse = PulseSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(pulse)
        }
    }
}
