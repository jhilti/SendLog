import SwiftUI

@main
struct SendLogApp: App {
    @StateObject private var store: AppStore = {
        let localDetector = HoldDetectionService()
        let remoteDetector: (any HoldDetecting)?

        if let endpointURL = AppConfiguration.remoteHoldDetectionURL {
            remoteDetector = RemoteHoldDetectionService(endpointURL: endpointURL)
        } else {
            remoteDetector = nil
        }

        let detector = FallbackHoldDetectionService(
            primary: remoteDetector,
            fallback: localDetector
        )

        return AppStore(detector: detector)
    }()

    var body: some Scene {
        WindowGroup {
            WallLibraryView()
                .environmentObject(store)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
    }
}
