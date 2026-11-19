import SwiftUI

@main
@MainActor
struct AirGuitarWatchApp: App {
    @StateObject private var library = WatchSongLibrary()
    @StateObject private var performance = PerformanceModel()
    @StateObject private var game = WatchGameController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(library)
                .environmentObject(performance)
                .environmentObject(performance.round)
                .environmentObject(game)
                .onAppear { game.bind(library: library, performance: performance) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        performance.sceneDidBecomeActive()
                    case .inactive:
                        performance.sceneWillResignActive()
                    case .background:
                        game.enteredBackground()
                        performance.sceneDidEnterBackground()
                    @unknown default:
                        break
                    }
                }
        }
        .backgroundTask(.watchConnectivity) {
            await library.finishBackgroundDelivery()
        }
    }
}
