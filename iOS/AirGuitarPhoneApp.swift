import AudioToolbox
import SwiftUI

@main
struct AirGuitarPhoneApp: App {
    @StateObject private var library = PhoneLibrary()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneHome(library: library)
                .onOpenURL { url in
                    // Keep this synchronous: retain an owned copy before the
                    // system's Open In callback and its temporary access end.
                    library.importFiles(.success([url]))
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        library.stopPreview()
                        library.cancelBackingCreation()
                    }
                }
        }
    }
}

private struct PhoneHome: View {
    private static let tourShownKey = "WristGuitar.didShowFirstTour"
    @ObservedObject var library: PhoneLibrary
    @State private var showsPracticeGuide = !UserDefaults.standard.bool(forKey: Self.tourShownKey)
    @State private var strokeSound: SystemSoundID?

    var body: some View {
        PhoneLibraryView(library: library, showsPracticeGuide: showsPracticeGuide,
                         onReplayGuide: { showsPracticeGuide = true },
                         onDismissGuide: { showsPracticeGuide = false },
                         onPracticeStroke: playPracticeStroke)
            .onAppear {
                if showsPracticeGuide { UserDefaults.standard.set(true, forKey: Self.tourShownKey) }
            }
            .onDisappear {
                if let strokeSound { AudioServicesDisposeSystemSoundID(strokeSound) }
                strokeSound = nil
            }
    }

    private func playPracticeStroke() {
        guard library.previewID == nil else { return }
        if let strokeSound {
            AudioServicesPlaySystemSoundWithCompletion(strokeSound, nil)
        } else if let url = Bundle.main.url(forResource: "TourStroke", withExtension: "wav") {
            var sound: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return }
            strokeSound = sound
            AudioServicesPlaySystemSoundWithCompletion(sound, nil)
        }
    }
}
