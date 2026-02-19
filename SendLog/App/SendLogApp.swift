import SwiftUI

@main
struct SendLogApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            WallLibraryView()
                .environmentObject(store)
        }
    }
}
