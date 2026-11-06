import SwiftUI

struct BibleView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(Prefs.Key.lang) private var lang = "E"
    @State private var error: String?

    var body: some View {
        Group {
            if let bible = library.installed(symbol: "nwt", issue: "", lang: lang) {
                BibleContents(bible: bible)
            } else {
                ContentUnavailableView {
                    Label("Bible not downloaded", systemImage: "book.closed")
                } description: {
                    Text("Download the New World Translation in \(PubLanguage.find(lang).name) to read it offline.")
                } actions: {
                    if library.isDownloading(symbol: "nwt", issue: "", lang: lang) {
                        ProgressView()
                    } else {
                        Button("Download Bible") {
                            Task {
                                do {
                                    try await library.ensure(symbol: "nwt", lang: lang)
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Bible")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LanguageMenu() }
            ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
        }
    }
}

/// The Bible's books and chapters, drawn as JW Library-style grids.
struct BibleContents: View {
    let bible: InstalledPub

    var body: some View {
        BibleBooksScreen(pub: bible)
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var results: [SearchIndex.Hit] = []
    @State private var searching = false

    var body: some View {
        List(results) { hit in
            NavigationLink(value: ReaderRoute(pubID: hit.pubID, href: hit.href, find: query)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(hit.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text(hit.pubTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.pubs.isEmpty {
                ContentUnavailableView("Nothing to search yet", systemImage: "magnifyingglass",
                                       description: Text("Search works across the publications you download."))
            } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                ContentUnavailableView("Search your publications", systemImage: "magnifyingglass",
                                       description: Text("Every downloaded book, workbook and Watchtower, offline."))
            } else if results.isEmpty && !searching {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Words or a phrase")
        .navigationTitle("Search")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
        .task(id: query) {
            let q = query
            guard q.trimmingCharacters(in: .whitespaces).count >= 2 else {
                results = []
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            searching = true
            let pubs = library.pubs.map { (pub: $0, folder: library.folder($0)) }
            let found = await Task.detached(priority: .userInitiated) {
                SearchIndex.shared.search(q, in: pubs)
            }.value
            if !Task.isCancelled { results = found }
            searching = false
        }
    }
}
