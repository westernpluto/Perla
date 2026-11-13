import SwiftUI

struct PubRoute: Hashable {
    let pubID: String
}

struct BibleBookRoute: Hashable {
    let pubID: String
    let book: Int
}

/// Opens a publication's contents (or, for the Bible, its books).
struct PubDestination: View {
    @EnvironmentObject private var library: LibraryStore
    let route: PubRoute

    var body: some View {
        if let pub = library.pubs.first(where: { $0.id == route.pubID }) {
            if pub.isBible {
                BibleBooksScreen(pub: pub)
                    .navigationTitle(pub.title)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                PublicationView(pub: pub)
            }
        } else {
            ContentUnavailableView("Publication not found", systemImage: "book.closed",
                                   description: Text("It may have been removed. Download it again from Library."))
        }
    }
}

struct BibleBookDestination: View {
    @EnvironmentObject private var library: LibraryStore
    let route: BibleBookRoute

    var body: some View {
        if let pub = library.pubs.first(where: { $0.id == route.pubID }),
           let index = BibleIndex.load(pub: pub, root: library.folder(pub)),
           let book = index.books.first(where: { $0.number == route.book }) {
            BibleChaptersView(pub: pub, book: book, select: nil)
        } else {
            ContentUnavailableView("Book not found", systemImage: "book.closed")
        }
    }
}

// MARK: - Publication contents

/// A publication's documents, with their pictures, like JW Library's contents screen.
struct PublicationView: View {
    @EnvironmentObject private var library: LibraryStore
    let pub: InstalledPub
    @State private var items: [ContentsItem]

    init(pub: InstalledPub) {
        self.pub = pub
        _items = State(initialValue: pub.readingOrder.map { ContentsItem(file: $0.file, href: $0.href, label: $0.label) })
    }

    var body: some View {
        let root = library.folder(pub)
        List {
            HStack(alignment: .top, spacing: 16) {
                if let cover = library.coverImage(pub) {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(pub.title)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pub.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)

            ForEach(items) { item in
                NavigationLink(value: ReaderRoute(pubID: pub.id, href: item.href)) {
                    ContentsRow(item: item, root: root, dateFirst: pub.symbol == "mwb")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(pub.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let p = pub
            items = await Task.detached(priority: .userInitiated) { ContentsReader.items(pub: p, root: root) }.value
        }
    }
}

/// The contents list inside the reader, for jumping to another week, article or chapter.
struct ContentsList: View {
    let pub: InstalledPub
    let root: URL
    let current: String
    let onSelect: (String) -> Void
    @State private var items: [ContentsItem]

    init(pub: InstalledPub, root: URL, current: String, onSelect: @escaping (String) -> Void) {
        self.pub = pub
        self.root = root
        self.current = current
        self.onSelect = onSelect
        _items = State(initialValue: pub.readingOrder.map { ContentsItem(file: $0.file, href: $0.href, label: $0.label) })
    }

    var body: some View {
        List(items) { item in
            Button {
                onSelect(item.href)
            } label: {
                ContentsRow(item: item, root: root, dateFirst: pub.symbol == "mwb", current: item.file == current)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .task {
            let p = pub
            let r = root
            items = await Task.detached(priority: .userInitiated) { ContentsReader.items(pub: p, root: r) }.value
        }
    }
}

struct ContentsRow: View {
    let item: ContentsItem
    let root: URL
    /// Workbook weeks read "7-13 September" then the Bible reading; articles put their date first.
    var dateFirst = false
    var current = false

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(url: item.image.map { root.appendingPathComponent($0) }, width: 100, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                if let kicker = item.kicker, !dateFirst {
                    Text(kicker.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(current ? Color.accentColor : Color.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let kicker = item.kicker, dateFirst {
                    Text(kicker)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Bible

/// The Bible's books for the Bible tab and the library.
struct BibleBooksScreen: View {
    @EnvironmentObject private var library: LibraryStore
    let pub: InstalledPub
    @State private var index: BibleIndex?
    @State private var failed = false

    var body: some View {
        Group {
            if let index {
                BibleBooksView(pub: pub, index: index, select: nil)
            } else if failed {
                ContentUnavailableView("Couldn't read this Bible", systemImage: "book.closed",
                                       description: Text("Remove it in Library and download it again."))
            } else {
                ProgressView()
            }
        }
        .task(id: pub.id) {
            index = await BibleIndex.prepare(pub: pub, root: library.folder(pub))
            failed = index == nil
        }
    }
}

/// Book tiles grouped and colored like JW Library (law, history, poetry, prophets, gospels, letters).
struct BibleBooksView: View {
    let pub: InstalledPub
    let index: BibleIndex
    /// When set, picking a chapter calls this instead of navigating.
    let select: ((String) -> Void)?
    private let columns = [GridItem(.adaptive(minimum: 62, maximum: 130), spacing: 2)]

    init(pub: InstalledPub, index: BibleIndex, select: ((String) -> Void)?) {
        self.pub = pub
        self.index = index
        self.select = select
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(sectionNumbers, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(sectionTitle(section).uppercased())
                            .font(.title3.weight(.bold))
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(index.books.filter { $0.section == section }) { book in
                                bookLink(book)
                            }
                        }
                    }
                }
                if !index.extras.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("INTRODUCTION AND APPENDIX")
                            .font(.title3.weight(.bold))
                            .padding(.bottom, 8)
                        ForEach(index.extras) { entry in
                            extraLink(entry)
                            Divider()
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var sectionNumbers: [Int] {
        Array(Set(index.books.map(\.section))).sorted()
    }

    private func sectionTitle(_ n: Int) -> String {
        n < index.sections.count ? index.sections[n] : (n == 0 ? L("Hebrew-Aramaic Scriptures") : L("Christian Greek Scriptures"))
    }

    @ViewBuilder
    private func bookLink(_ book: BibleIndex.Book) -> some View {
        let tile = BookTile(book: book)
        if let select {
            if book.chapters.count == 1, let only = book.chapters.first {
                Button { select(only.href) } label: { tile }.buttonStyle(.plain)
            } else {
                NavigationLink(value: book.number) { tile }.buttonStyle(.plain)
            }
        } else if book.chapters.count == 1, let only = book.chapters.first {
            NavigationLink(value: ReaderRoute(pubID: pub.id, href: only.href)) { tile }.buttonStyle(.plain)
        } else {
            NavigationLink(value: BibleBookRoute(pubID: pub.id, book: book.number)) { tile }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func extraLink(_ entry: TOCEntry) -> some View {
        let label = HStack {
            Text(entry.label)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        if let select {
            Button { select(entry.href) } label: { label }.buttonStyle(.plain)
        } else {
            NavigationLink(value: ReaderRoute(pubID: pub.id, href: entry.href)) { label }.buttonStyle(.plain)
        }
    }
}

struct BookTile: View {
    let book: BibleIndex.Book

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .leading) {
                Text(book.abbreviation)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 10)
            }
            .background(BibleColors.tile(book.number))
            .contentShape(Rectangle())
            .accessibilityLabel(book.name)
    }
}

enum BibleColors {
    static func tile(_ book: Int) -> Color {
        let pair: (light: UInt32, dark: UInt32)
        switch BibleIndex.group(of: book) {
        case .law, .prophets, .letters: pair = (0xD9D3E6, 0x3A3447)
        case .history, .gospels, .revelation: pair = (0xBAB0D2, 0x675C80)
        case .poetry, .acts, .otherLetters: pair = (0xCAC1DD, 0x4A4260)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: pair.dark) : UIColor(hex: pair.light) })
    }

    static var chapter: Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x3D3D41) : UIColor(hex: 0xE4E4E8) })
    }
}

/// A book's chapter numbers.
struct BibleChaptersView: View {
    let pub: InstalledPub
    let book: BibleIndex.Book
    let select: ((String) -> Void)?
    private let columns = [GridItem(.adaptive(minimum: 62, maximum: 130), spacing: 2)]

    init(pub: InstalledPub, book: BibleIndex.Book, select: ((String) -> Void)?) {
        self.pub = pub
        self.book = book
        self.select = select
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(book.chapters, id: \.number) { ch in
                        chapterLink(ch)
                    }
                }
                if let outline = book.outline {
                    outlineLink(outline)
                }
            }
            .padding(16)
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tile(_ n: Int) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Text("\(n)")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .background(BibleColors.chapter)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func chapterLink(_ ch: BibleIndex.Chapter) -> some View {
        if let select {
            Button { select(ch.href) } label: { tile(ch.number) }.buttonStyle(.plain)
        } else {
            NavigationLink(value: ReaderRoute(pubID: pub.id, href: ch.href)) { tile(ch.number) }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func outlineLink(_ href: String) -> some View {
        let label = Label("Book outline", systemImage: "list.bullet.rectangle")
            .font(.body.weight(.medium))
            .padding(.vertical, 6)
        if let select {
            Button { select(href) } label: { label }
        } else {
            NavigationLink(value: ReaderRoute(pubID: pub.id, href: href)) { label }
        }
    }
}

/// Books and chapters inside the reader, opened on the current book.
struct BibleNavigator: View {
    let pub: InstalledPub
    let index: BibleIndex
    let onSelect: (String) -> Void
    @State private var path: [Int]
    @Environment(\.dismiss) private var dismiss

    init(pub: InstalledPub, index: BibleIndex, current: BibleIndex.Book?, onSelect: @escaping (String) -> Void) {
        self.pub = pub
        self.index = index
        self.onSelect = onSelect
        let start = current.flatMap { $0.chapters.count > 1 ? [$0.number] : nil } ?? []
        _path = State(initialValue: start)
    }

    var body: some View {
        NavigationStack(path: $path) {
            BibleBooksView(pub: pub, index: index, select: onSelect)
                .navigationTitle("Books")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { done }
                .navigationDestination(for: Int.self) { number in
                    if let book = index.books.first(where: { $0.number == number }) {
                        BibleChaptersView(pub: pub, book: book, select: onSelect)
                            .toolbar { done }
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var done: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }
}
