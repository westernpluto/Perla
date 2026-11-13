import SwiftUI

@main
struct PerlaApp: App {
    @StateObject private var library = LibraryStore.shared
    @AppStorage(Prefs.Key.appLang) private var appLang = ""

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                // The app's language applies at once: interface text is looked up in this locale.
                .environment(\.locale, AppLanguage.locale)
                .id(appLang)
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
