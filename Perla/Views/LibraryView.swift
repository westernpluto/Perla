import SwiftUI

/// The Library, organized like JW Library: Bible, Books, Brochures, Meeting Workbooks, Watchtower and
/// Videos, with everything jw.org offers, not only what's downloaded.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        List {
            Section {
                ForEach(CatalogItem.Category.allCases) { category in
                    NavigationLink(value: LibrarySection.catalog(category)) {
                        Label(category.title, systemImage: category.icon)
                    }
                }
                NavigationLink(value: LibrarySection.workbooks) {
                    Label("Meeting Workbooks", systemImage: "calendar")
                }
                NavigationLink(value: LibrarySection.watchtower) {
                    Label("The Watchtower (Study)", systemImage: "text.book.closed")
                }
                NavigationLink(value: LibrarySection.videos(key: "VideoOnDemand", title: "Videos")) {
                    Label("Videos", systemImage: "play.rectangle")
                }
            }

            Section {
                NavigationLink(value: LibrarySection.downloaded) {
                    LabeledContent {
                        Text("\(library.pubs.count)")
                    } label: {
                        Label("Downloaded", systemImage: "arrow.down.circle")
                    }
                }
                NavigationLink(value: LibrarySection.bySymbol) {
                    Label("Download by symbol", systemImage: "character.textbox")
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LanguageMenu() }
            ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
        }
    }
}

enum LibrarySection: Hashable {
    case catalog(CatalogItem.Category)
    case workbooks
    case watchtower
    case downloaded
    case bySymbol
    case videos(key: String, title: String)
}

struct LibrarySectionDestination: View {
    let section: LibrarySection

    var body: some View {
        switch section {
        case .catalog(let category):
            CatalogGrid(title: category.title,
                        entries: CatalogItem.items(in: category).map { .init(symbol: $0.symbol, issue: "", title: $0.title) })
        case .workbooks:
            CatalogGrid(title: "Meeting Workbooks",
                        entries: Issues.workbookIssues().map {
                            .init(symbol: "mwb", issue: $0, title: Issues.label(symbol: "mwb", issue: $0))
                        })
        case .watchtower:
            CatalogGrid(title: "The Watchtower",
                        entries: Issues.watchtowerIssues().map {
                            .init(symbol: "w", issue: $0, title: Issues.label(symbol: "w", issue: $0))
                        })
        case .downloaded:
            DownloadedView()
        case .bySymbol:
            SymbolDownloadView()
        case .videos(let key, let title):
            VideoCategoryView(key: key, title: title)
        }
    }
}

/// A grid of publications. Downloaded ones show their cover and open; the rest show a title tile
/// with a download mark, and tapping one asks before downloading.
struct CatalogGrid: View {
    struct Entry: Identifiable, Hashable {
        let symbol: String
        let issue: String
        let title: String
        var id: String { symbol + "_" + issue }
    }

    let title: String
    let entries: [Entry]
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(Prefs.Key.lang) private var lang = "E"
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(entries) { entry in
                    tile(entry)
                }
            }
            .scenePadding(.horizontal)
            .padding(.vertical, 16)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func tile(_ entry: Entry) -> some View {
        let caption = entry.issue.isEmpty ? nil : entry.title
        if let pub = library.installed(symbol: entry.symbol, issue: entry.issue, lang: lang) {
            NavigationLink(value: PubRoute(pubID: pub.id)) {
                CatalogTile(title: pub.title, caption: caption, image: library.coverImage(pub),
                            downloaded: true, downloading: false)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: PubRef(symbol: entry.symbol, issue: entry.issue, lang: lang, label: entry.title)) {
                CatalogTile(title: entry.title, caption: caption, image: nil, downloaded: false,
                            downloading: library.isDownloading(symbol: entry.symbol, issue: entry.issue, lang: lang))
            }
            .buttonStyle(.plain)
        }
    }
}

struct CatalogTile: View {
    let title: String
    /// Shown under the tile instead of the title (issue dates).
    let caption: String?
    let image: UIImage?
    let downloaded: Bool
    let downloading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(10)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if downloading {
                    ProgressView().padding(8)
                } else if !downloaded {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(8)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .shadow(color: .black.opacity(0.1), radius: 3, y: 2)
            Text(caption ?? title)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(downloaded ? "" : "Not downloaded")
    }
}

/// Everything on this iPhone, grouped like the Library, with a way to remove downloads.
struct DownloadedView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var confirmDelete: InstalledPub?
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            if library.pubs.isEmpty {
                ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                       description: Text("Publications you open are downloaded and kept here to read offline."))
                    .padding(.top, 60)
            }
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(group.title).font(.title3.weight(.bold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(group.pubs) { pub in
                                NavigationLink(value: PubRoute(pubID: pub.id)) {
                                    CatalogTile(title: pub.title, caption: nil, image: library.coverImage(pub),
                                                downloaded: true, downloading: false)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Remove download", systemImage: "trash", role: .destructive) {
                                        confirmDelete = pub
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scenePadding(.horizontal)
            .padding(.vertical, 16)
        }
        .navigationTitle("Downloaded")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove this download?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { pub in
            Button("Remove \(pub.title)", role: .destructive) { library.delete(pub) }
        }
    }

    private var groups: [(title: String, pubs: [InstalledPub])] {
        func group(_ pub: InstalledPub) -> String {
            if pub.isBible { return "Bible" }
            switch pub.symbol {
            case "mwb": return "Meeting Workbooks"
            case "w": return "The Watchtower"
            default:
                return CatalogItem.all.first { $0.symbol == pub.symbol }?.category == .brochures
                    ? "Brochures and Booklets" : "Books"
            }
        }
        let order = ["Bible", "Meeting Workbooks", "The Watchtower", "Books", "Brochures and Booklets"]
        let grouped = Dictionary(grouping: library.pubs, by: group)
        return order.compactMap { name in grouped[name].map { (title: name, pubs: $0) } }
    }
}

/// Any publication jw.org offers as EPUB, by its symbol (for example "lff", or "w" with "202609").
struct SymbolDownloadView: View {
    @AppStorage(Prefs.Key.lang) private var lang = "E"
    @State private var symbol = ""
    @State private var issue = ""

    var body: some View {
        Form {
            Section {
                TextField("Symbol (for example lff)", text: $symbol)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Issue (optional, for example 202609)", text: $issue)
                    .keyboardType(.numberPad)
            } footer: {
                Text("Use the symbol jw.org gives a publication.")
            }
            let sym = symbol.trimmingCharacters(in: .whitespaces).lowercased()
            if !sym.isEmpty {
                Section {
                    NavigationLink(value: PubRef(symbol: sym, issue: issue.trimmingCharacters(in: .whitespaces),
                                                 lang: lang, label: sym.uppercased())) {
                        Label("Open \(sym.uppercased())", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        .navigationTitle("Download by symbol")
        .navigationBarTitleDisplayMode(.inline)
    }
}
