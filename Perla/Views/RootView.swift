import SwiftUI

enum AppTab: Hashable {
    case meetings, library, bible, search
}

struct RootView: View {
    @State private var tab: AppTab = .meetings

    var body: some View {
        TabView(selection: $tab) {
            Tab("Meetings", systemImage: "calendar", value: AppTab.meetings) {
                PubStack { MeetingsView() }
            }
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                PubStack { LibraryView() }
            }
            Tab("Bible", systemImage: "book.closed", value: AppTab.bible) {
                PubStack { BibleView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                PubStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

/// A navigation stack that knows how to open publications.
private struct PubStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationDestination(for: ReaderRoute.self) { route in
                    ReaderDestination(route: route)
                }
                .navigationDestination(for: PubRoute.self) { route in
                    PubDestination(route: route)
                }
                .navigationDestination(for: BibleBookRoute.self) { route in
                    BibleBookDestination(route: route)
                }
                .navigationDestination(for: PubRef.self) { ref in
                    PubRefDestination(ref: ref)
                }
        }
    }
}
