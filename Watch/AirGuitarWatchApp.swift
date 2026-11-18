import SwiftUI

@main
@MainActor
struct AirGuitarWatchApp: App {
    @StateObject private var library = WatchSongLibrary()
    @StateObject private var performance = PerformanceModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(library)
                .environmentObject(performance)
                .environmentObject(performance.round)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        performance.pause(reason: "回到前台后，点击继续")
                    } else if phase == .active {
                        performance.resumeBeatHapticsIfNeeded()
                    }
                }
        }
        .backgroundTask(.watchConnectivity) {
            await library.finishBackgroundDelivery()
        }
    }
}
