import SwiftUI

@main
struct PerlaApp: App {
    @StateObject private var library = LibraryStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}
