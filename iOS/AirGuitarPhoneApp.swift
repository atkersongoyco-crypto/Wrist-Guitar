import SwiftUI

@main
struct AirGuitarPhoneApp: App {
    @StateObject private var library = PhoneLibrary()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneLibraryView(library: library)
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
