import Foundation

/// The Bible's books and chapters, read once from the navigation pages inside the EPUB
/// (biblebooknav / biblechapternavN), so the app can show its own book and chapter grids
/// instead of the EPUB's link tables.
struct BibleIndex: Codable {
    struct Chapter: Codable, Hashable {
        let number: Int
        let href: String
    }

    struct Book: Codable, Hashable, Identifiable {
        let number: Int
        let name: String
        let abbreviation: String
        /// 0 = Hebrew-Aramaic Scriptures, 1 = Christian Greek Scriptures.
        let section: Int
        let chapters: [Chapter]
        /// The book's outline ("Contents of Genesis"), when the EPUB has one.
        var outline: String?
        var id: Int { number }
    }

    static let currentVersion = 3
    static let fileName = "perla-bible.json"

    var version = BibleIndex.currentVersion
    var sections: [String]
    var books: [Book]
    /// Introduction, appendices, glossary and other documents.
    var extras: [TOCEntry]

    var allChapters: [Chapter] { books.flatMap(\.chapters) }

    func book(containing file: String) -> Book? {
        books.first { b in b.chapters.contains { $0.href == file } }
    }

    // MARK: Loading

    @MainActor private static var memory: [String: BibleIndex] = [:]

    /// The index from memory or from its saved copy; builds it (once) when `build` is true.
    @MainActor
    static func load(pub: InstalledPub, root: URL, buildIfNeeded: Bool = true) -> BibleIndex? {
        if let cached = memory[pub.id] { return cached }
        let cacheURL = root.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(BibleIndex.self, from: data),
           saved.version == currentVersion, !saved.books.isEmpty {
            memory[pub.id] = saved
            return saved
        }
        guard buildIfNeeded, let built = build(pub: pub, root: root) else { return nil }
        store(built, pub: pub, root: root)
        return built
    }

    /// Same as `load`, but reads the navigation pages off the main thread the first time.
    @MainActor
    static func prepare(pub: InstalledPub, root: URL) async -> BibleIndex? {
        if let ready = load(pub: pub, root: root, buildIfNeeded: false) { return ready }
        let built = await Task.detached(priority: .userInitiated) { BibleIndex.build(pub: pub, root: root) }.value
        guard let built else { return nil }
        store(built, pub: pub, root: root)
        return built
    }

    @MainActor
    private static func store(_ index: BibleIndex, pub: InstalledPub, root: URL) {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: root.appendingPathComponent(fileName), options: .atomic)
        }
        memory[pub.id] = index
    }

    static func build(pub: InstalledPub, root: URL) -> BibleIndex? {
        let navFile = pub.toc.map(\.file).first { $0.hasSuffix("biblebooknav.xhtml") }
            ?? pub.spine.first { $0.hasSuffix("biblebooknav.xhtml") }
            ?? "OEBPS/biblebooknav.xhtml"
        guard let navData = try? Data(contentsOf: root.appendingPathComponent(navFile)) else { return nil }

        var sections: [String] = []
        var books: [Book] = []
        var entryFiles: [Int: String] = [:]
        for el in XMLScan.run(navData) {
            if el.localName == "strong", !el.ancestors.contains("a") {
                let t = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sections.append(t) }
                continue
            }
            guard el.localName == "a", let href = el.attrs["href"], !href.isEmpty else { continue }
            let target = EPUBParser.path(href, relativeTo: navFile)
            let file = target.components(separatedBy: "#").first ?? target
            var abbreviation = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if abbreviation.hasSuffix(".") { abbreviation.removeLast() }
            let number = books.count + 1
            let section = max(0, sections.count - 1)

            if file.contains("biblechapternav") {
                guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { continue }
                let els = XMLScan.run(data)
                var name = els.first { $0.localName == "h2" }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if name.isEmpty { name = els.first { $0.localName == "title" }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? abbreviation }
                var chapters: [Chapter] = []
                for a in els where a.localName == "a" && a.ancestors.contains("table") {
                    guard let h = a.attrs["href"],
                          let n = Int(a.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                    let path = EPUBParser.path(h, relativeTo: file)
                    chapters.append(Chapter(number: n, href: path.components(separatedBy: "#").first ?? path))
                }
                guard !chapters.isEmpty else { continue }
                books.append(Book(number: number, name: name, abbreviation: abbreviation, section: section,
                                  chapters: chapters, outline: nil))
            } else {
                // Books with a single chapter link straight to it.
                let html = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
                var name = abbreviation
                if let r = html.range(of: "<title>([^<]*)</title>", options: .regularExpression) {
                    let t = HTMLText.clean(String(html[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    if !t.isEmpty { name = t }
                }
                books.append(Book(number: number, name: name, abbreviation: abbreviation, section: section,
                                  chapters: [Chapter(number: 1, href: file)], outline: nil))
            }
            entryFiles[number] = file
        }
        guard !books.isEmpty else { return nil }

        // The contents list puts each book's outline right before the book.
        let bookFiles = Set(entryFiles.values)
        let toc = pub.toc
        var outlines: Set<String> = []
        for i in toc.indices where i > 0 {
            guard let number = entryFiles.first(where: { $0.value == toc[i].file })?.key else { continue }
            let prev = toc[i - 1].file
            if prev != navFile, !bookFiles.contains(prev), !prev.contains("biblechapternav"),
               let idx = books.firstIndex(where: { $0.number == number }) {
                books[idx].outline = prev
                outlines.insert(prev)
            }
        }

        var seen: Set<String> = []
        var extras: [TOCEntry] = []
        for e in toc {
            let f = e.file
            let name = (f as NSString).lastPathComponent
            if f == navFile || bookFiles.contains(f) || outlines.contains(f) || name.hasPrefix("bible")
                || name.hasPrefix("pagenav") || seen.contains(f) { continue }
            seen.insert(f)
            extras.append(e)
        }
        return BibleIndex(sections: sections, books: books, extras: extras)
    }

    // MARK: Book groups (for the colors of the book grid)

    enum BookGroup {
        case law, history, poetry, prophets, gospels, acts, letters, otherLetters, revelation
    }

    static func group(of book: Int) -> BookGroup {
        switch book {
        case 1...5: return .law
        case 6...17: return .history
        case 18...22: return .poetry
        case 23...39: return .prophets
        case 40...43: return .gospels
        case 44: return .acts
        case 45...58: return .letters
        case 59...65: return .otherLetters
        default: return .revelation
        }
    }
}

extension InstalledPub {
    /// A document in the publication, in reading order.
    struct DocEntry: Hashable, Identifiable {
        let file: String
        let href: String
        let label: String
        var id: String { file }
    }

    /// The publication's documents in order, without cover, page-number and navigation pages.
    var readingOrder: [DocEntry] {
        func skip(_ file: String) -> Bool {
            let name = (file as NSString).lastPathComponent.lowercased()
            return name.hasPrefix("pagenav") || name.contains("-extracted") || name.hasPrefix("bible")
                || name == "cover.xhtml" || name == "toc.xhtml" || name.hasSuffix(".ncx")
        }
        var seen: Set<String> = []
        var out: [DocEntry] = []
        for e in toc where !skip(e.file) && !seen.contains(e.file) {
            seen.insert(e.file)
            out.append(DocEntry(file: e.file, href: e.file, label: e.label))
        }
        if out.isEmpty {
            for f in spine where !skip(f) && !seen.contains(f) {
                seen.insert(f)
                out.append(DocEntry(file: f, href: f, label: ((f as NSString).lastPathComponent as NSString).deletingPathExtension))
            }
        }
        return out
    }
}

/// One row of a publication's contents: its title, the small heading above it and a picture.
struct ContentsItem: Identifiable, Hashable {
    let file: String
    let href: String
    let label: String
    var kicker: String?
    var image: String?
    var id: String { file }
}

enum ContentsReader {
    /// Reads each document's first picture and its date or Bible-reading line. Runs off the main thread.
    static func items(pub: InstalledPub, root: URL) -> [ContentsItem] {
        let imgRE = try? NSRegularExpression(pattern: "<img[^>]*\\ssrc=\"([^\"]+)\"")
        let ctxRE = try? NSRegularExpression(pattern: "<p[^>]*class=\"[^\"]*contextTtl[^\"]*\"[^>]*>([\\s\\S]*?)</p>")
        let h2RE = try? NSRegularExpression(pattern: "<h2[^>]*>([\\s\\S]*?)</h2>")

        func first(_ re: NSRegularExpression?, in s: String) -> String? {
            guard let re else { return nil }
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
        func text(_ html: String) -> String {
            HTMLText.clean(html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
        }

        return pub.readingOrder.map { entry in
            var item = ContentsItem(file: entry.file, href: entry.href, label: entry.label)
            guard let html = try? String(contentsOf: root.appendingPathComponent(entry.file), encoding: .utf8) else {
                return item
            }
            let body = html.range(of: "<body").map { String(html[$0.lowerBound...]) } ?? html
            if let src = first(imgRE, in: body) {
                item.image = EPUBParser.path(src, relativeTo: entry.file)
            }
            if let ctx = first(ctxRE, in: body) {
                let t = text(ctx)
                if !t.isEmpty { item.kicker = t }
            } else if pub.symbol == "mwb", let h2 = first(h2RE, in: body) {
                let t = text(h2)
                if !t.isEmpty && t.count < 80 { item.kicker = t }
            }
            return item
        }
    }
}
