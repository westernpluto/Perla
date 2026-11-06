import SwiftUI

@main
struct PerlaApp: App {
    @StateObject private var library = LibraryStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .task {
                    // Book names of downloaded Bibles make references in their language tappable.
                    for pub in library.pubs where pub.isBible {
                        if let index = await BibleIndex.prepare(pub: pub, root: library.folder(pub)) {
                            BibleNames.register(index)
                        }
                    }
                }
        }
    }
}
