import SwiftUI
import Combine

enum AnswerStatus: String {
    case idle, done
}

struct AnswerState: Equatable {
    var status: AnswerStatus = .idle
    var text = ""
    /// Where the answer came from: "Your answer", "Imported", "From the paragraph".
    var note = ""
}

/// A web page shown inside the app instead of sending you to Safari.
struct WebLink: Identifiable {
    let id = UUID()
    let url: URL
}

struct ScrollRequest: Equatable {
    let node: Int
    let token = UUID()
}

/// A verse, footnote or publication reference shown in a sheet.
struct ReferenceSheet: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let nodes: [DocNode]
    /// Bible text, drawn with verse numbers like the Bible itself.
    let scripture: Bool
    /// The whole lesson, chapter or article this reference comes from, when it can be opened.
    var open: PubRef? = nil
}

/// One open document (a workbook week, an article, a Bible chapter…), its questions and their answers.
@MainActor
final class ReaderModel: ObservableObject {
    let pub: InstalledPub
    let root: URL
    /// Documents in reading order, for previous / next.
    let order: [String]
    /// Books and chapters, when this is the Bible.
    let bible: BibleIndex?
    private let titles: [String: String]

    @Published private(set) var doc: Document = .empty
    @Published private(set) var currentFile = ""
    @Published private(set) var title = ""
    @Published private(set) var loading = false
    /// The document couldn't be read (missing or damaged file).
    @Published private(set) var loadFailed = false
    @Published private(set) var findTerm: String?
    @Published var scrollRequest: ScrollRequest?
    @Published var reference: ReferenceSheet?
    /// Another publication (a Bible study lesson, a cited article, a Bible chapter) to open on top.
    @Published var pushRef: PubRef?
    @Published var pushRoute: ReaderRoute?
    @Published var media: MediaItem?
    @Published var web: WebLink?

    @Published var questions: [PageQuestion] = []
    @Published var answers: [String: AnswerState] = [:]
    @Published var focusedID: String?
    /// Answer box node → question, and question node → question for prompts without a box.
    @Published private(set) var questionAtField: [Int: String] = [:]
    @Published private(set) var questionAfterNode: [Int: String] = [:]

    private var found: [String: FoundQuestion] = [:]
    private var extracted: [String: Reference] = [:]
    private var nodeByID: [Int: DocNode] = [:]
    private var topLevelOf: [Int: Int] = [:]
    private var loadToken = UUID()
    private var started = false
    private var importObserver: AnyCancellable?

    init(pub: InstalledPub) {
        self.pub = pub
        let folder = LibraryStore.shared.folder(pub)
        root = folder
        JWIcons.shared.prepare(root: folder, pubID: pub.id)
        bible = pub.isBible ? BibleIndex.load(pub: pub, root: folder) : nil
        if let bible {
            order = bible.allChapters.map(\.href)
            var t: [String: String] = [:]
            for book in bible.books {
                for ch in book.chapters { t[ch.href] = "\(book.name) \(ch.number)" }
            }
            titles = t
        } else {
            let docs = pub.readingOrder
            order = docs.map(\.file)
            titles = Dictionary(docs.map { ($0.file, $0.label) }, uniquingKeysWith: { a, _ in a })
        }
        importObserver = NotificationCenter.default.publisher(for: ImportedAnswers.changed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyImported() }
    }

    var isBible: Bool { pub.isBible }
    var currentBook: BibleIndex.Book? { bible?.book(containing: currentFile) }
    func titleFor(_ file: String) -> String? { titles[file] }

    // MARK: Navigation

    func start(at href: String?, find: String? = nil) {
        guard !started else { return }
        started = true
        open(href ?? order.first ?? pub.startHref, find: find)
    }

    private var index: Int? { order.firstIndex(of: currentFile) }
    var hasPrevious: Bool { (index ?? 0) > 0 }
    var hasNext: Bool { (index.map { $0 + 1 } ?? order.count) < order.count }
    var previousTitle: String? { index.flatMap { $0 > 0 ? titles[order[$0 - 1]] : nil } }
    var nextTitle: String? { index.flatMap { $0 + 1 < order.count ? titles[order[$0 + 1]] : nil } }
    func previous() { if let i = index, i > 0 { open(order[i - 1]) } }
    func next() { if let i = index, i + 1 < order.count { open(order[i + 1]) } }

    func open(_ href: String, find: String? = nil) {
        let parts = href.components(separatedBy: "#")
        let file = parts[0].isEmpty ? currentFile : parts[0]
        let fragment = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil

        if file == currentFile, !doc.nodes.isEmpty {
            if let fragment, let id = nodeID(forAnchor: fragment) { requestScroll(to: id) }
            if let find { applyFind(find) }
            return
        }

        loading = true
        let token = UUID()
        loadToken = token
        let mainURL = root.appendingPathComponent(file)
        let extractedFile = file.replacingOccurrences(of: ".xhtml", with: "-extracted.xhtml")
        let extractedURL = root.appendingPathComponent(extractedFile)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Document, [String: Reference]) in
                guard let data = try? Data(contentsOf: mainURL) else { return (Document.empty, [:]) }
                let main = DocParser.parse(data: data, path: file)
                var refs: [String: Reference] = [:]
                if let extra = try? Data(contentsOf: extractedURL) {
                    refs = DocParser.parse(data: extra, path: extractedFile).extractedReferences()
                }
                return (main, refs)
            }.value
            guard token == self.loadToken else { return }
            if result.0.nodes.isEmpty {
                self.loading = false
                self.loadFailed = true
                if self.currentFile.isEmpty { self.currentFile = file }
                return
            }
            self.loadFailed = false
            self.show(file: file, doc: result.0, extracted: result.1, fragment: fragment, find: find)
        }
    }

    private func show(file: String, doc newDoc: Document, extracted refs: [String: Reference], fragment: String?, find: String?) {
        answers = [:]
        focusedID = nil
        found = [:]

        currentFile = file
        doc = newDoc
        extracted = refs
        loading = false
        title = titles[file] ?? (newDoc.title.isEmpty ? pub.title : newDoc.title.capitalized)

        var byID: [Int: DocNode] = [:]
        var top: [Int: Int] = [:]
        for t in newDoc.nodes + newDoc.footnoteNodes {
            t.walk { n in
                byID[n.id] = n
                top[n.id] = t.id
            }
        }
        nodeByID = byID
        topLevelOf = top

        // Questions and where their answers go.
        var list: [PageQuestion] = []
        var atField: [Int: String] = [:]
        var afterNode: [Int: String] = [:]
        if !pub.isBible {
            for f in QuestionFinder.find(newDoc) {
                list.append(f.question)
                found[f.question.id] = f
                if let field = f.field { atField[field] = f.question.id } else { afterNode[f.node] = f.question.id }
            }
        }
        questions = list
        questionAtField = atField
        questionAfterNode = afterNode
        findTerm = nil

        if let find {
            applyFind(find)
        } else if let fragment, let id = nodeID(forAnchor: fragment) {
            requestScroll(to: id)
        }

        for q in list {
            if let cached = AnswerStore.shared.get(key(q.id)) {
                answers[q.id] = AnswerState(status: .done, text: cached.text, note: cached.engine)
            } else if let imported = ImportedAnswers.shared.answer(for: q.text) {
                answers[q.id] = AnswerState(status: .done, text: imported, note: "Imported")
            } else {
                answers[q.id] = AnswerState()
            }
        }
    }

    /// After an answers file is imported (or removed), fill the boxes you haven't written yourself.
    private func applyImported() {
        for q in questions where AnswerStore.shared.get(key(q.id)) == nil {
            if let imported = ImportedAnswers.shared.answer(for: q.text) {
                answers[q.id] = AnswerState(status: .done, text: imported, note: "Imported")
            } else if answers[q.id]?.note == "Imported" {
                answers[q.id] = AnswerState()
            }
        }
    }

    private func nodeID(forAnchor anchor: String) -> Int? {
        for t in doc.nodes {
            var hit: Int?
            t.walk { n in if hit == nil, n.anchors.contains(anchor) || n.elementID == anchor { hit = t.id } }
            if let hit { return hit }
        }
        return nil
    }

    private func applyFind(_ term: String) {
        findTerm = term
        for t in doc.nodes {
            var hit = false
            t.walk { n in
                if !hit, n.plain.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil { hit = true }
            }
            if hit {
                requestScroll(to: t.id)
                return
            }
        }
    }

    /// Scrolls after the new page has had a moment to lay out.
    private func requestScroll(to node: Int) {
        let target = topLevelOf[node] ?? node
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.scrollRequest = ScrollRequest(node: target)
        }
    }

    // MARK: Links

    func handleLink(_ url: URL) -> OpenURLAction.Result {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "perla" else { return handleExternal(url, text: "") }
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch url.host ?? "" {
        case "doc":
            handleDocLink(query["p"] ?? "", text: query["t"] ?? "")
        case "ref":
            let sym = query["sym"] ?? ""
            guard !sym.isEmpty else { break }
            let ref = PubRef(symbol: sym, issue: query["issue"] ?? "", number: query["n"].flatMap { Int($0) },
                             lang: pub.lang, label: query["t"] ?? "")
            openRef(ref)
        case "song":
            if let n = query["n"], !n.isEmpty {
                let item = MediaItem(source: .pubMedia(["pub": "sjjm", "track": n]), lang: pub.lang,
                                  title: query["t"].flatMap { $0.isEmpty ? nil : $0 } ?? "Song \(n)")
                afterSheet { $0.media = item }
            }
        case "bible":
            guard let b = query["b"].flatMap({ Int($0) }), let c = query["c"].flatMap({ Int($0) }) else { break }
            showBible(book: b, chapter: c, verse: query["v"].flatMap { Int($0) },
                      verseEnd: query["e"].flatMap { Int($0) }, label: query["t"] ?? "")
        case "web":
            if let s = query["u"], let u = URL(string: s) { return handleExternal(u, text: query["t"] ?? "") }
        default:
            break
        }
        return .handled
    }

    private func handleDocLink(_ target: String, text: String) {
        let parts = target.components(separatedBy: "#")
        let file = parts[0]
        let fragment = parts.count > 1 ? parts[1] : ""
        let named = Linkifier.pubRef(in: text, lang: pub.lang)

        if fragment.hasPrefix("citation"), let ref = doc.citations[fragment] {
            reference = ReferenceSheet(title: ref.title, text: ref.text, nodes: ref.nodes, scripture: true)
        } else if fragment.hasPrefix("footnote"), let ref = doc.footnotes[fragment] {
            reference = ReferenceSheet(title: ref.title.isEmpty ? "Footnote" : ref.title, text: ref.text,
                                       nodes: ref.nodes, scripture: false)
        } else if fragment.hasPrefix("pcitation"), let ref = extracted[fragment] {
            // Research and the Bible study: show the part that's included, with a way into the whole lesson.
            let open = named ?? Linkifier.pubRef(in: ref.title, lang: pub.lang)
            reference = ReferenceSheet(title: ref.title.isEmpty ? text : ref.title, text: ref.text, nodes: ref.nodes,
                                       scripture: false, open: open)
        } else if file.contains("biblechapternav") || file.contains("biblebooknav") || file.contains("bibleversenav") {
            // Bible navigation pages are replaced by the app's own book and chapter grids.
            showBibleContents = true
        } else if let named, file.isEmpty || file.contains("-extracted") || !exists(file) {
            // A lesson or article from another publication: download it and open it.
            reference = nil
            openRef(named)
        } else if !file.isEmpty, exists(file) {
            reference = nil
            open(target)
        } else if let ref = extractedByText(text) {
            reference = ReferenceSheet(title: ref.title.isEmpty ? text : ref.title, text: ref.text, nodes: ref.nodes,
                                       scripture: false, open: named)
        } else {
            reference = ReferenceSheet(title: text.isEmpty ? "Link" : text,
                                       text: "This part isn't included in the downloaded publication.",
                                       nodes: [], scripture: false, open: named)
        }
    }

    @Published var showBibleContents = false

    private func exists(_ file: String) -> Bool {
        !file.isEmpty && FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path)
    }

    /// An included reference whose title matches the link text, when the link's anchor doesn't.
    private func extractedByText(_ text: String) -> Reference? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count >= 3 else { return nil }
        return extracted.values.first { $0.title.lowercased().hasPrefix(t) || t.hasPrefix($0.title.lowercased()) }
    }

    /// A Bible reference: the verses in a sheet (or the side pane when unfolded), like JW Library.
    /// Without a verse, or without a downloaded Bible, the chapter opens instead.
    func showBible(book: Int, chapter: Int, verse: Int?, verseEnd: Int?, label: String) {
        let ref = PubRef(symbol: "nwt", bibleBook: book, bibleChapter: chapter, lang: pub.lang, label: label)
        let library = LibraryStore.shared
        let biblePub = isBible ? pub : library.installed(symbol: "nwt", issue: "", lang: pub.lang)
        guard let verse, let biblePub else {
            openRef(ref)
            return
        }
        let root = library.folder(biblePub)
        guard let index = BibleIndex.load(pub: biblePub, root: root),
              let ch = index.books.first(where: { $0.number == book })?.chapters.first(where: { $0.number == chapter })
        else {
            openRef(ref)
            return
        }
        let file = root.appendingPathComponent(ch.href.components(separatedBy: "#")[0])
        let path = ch.href
        let last = verseEnd ?? verse
        Task { @MainActor [weak self] in
            let node = await Task.detached(priority: .userInitiated) { () -> DocNode? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return BibleText.verses(in: DocParser.parse(data: data, path: path), from: verse, to: last)
            }.value
            guard let self else { return }
            if let node {
                self.reference = ReferenceSheet(title: label, text: node.plain, nodes: [node], scripture: true, open: ref)
            } else {
                self.openRef(ref)
            }
        }
    }

    /// Opens a lesson, chapter, article or Bible chapter from another publication.
    func openRef(_ ref: PubRef) {
        if ref.isBible, isBible, let bible, let book = bible.books.first(where: { $0.number == ref.bibleBook }),
           let ch = book.chapters.first(where: { $0.number == (ref.bibleChapter ?? 1) }) ?? book.chapters.first {
            reference = nil
            open(ch.href)
            return
        }
        if ref.symbol == pub.symbol, ref.issue == pub.issue, let number = ref.number,
           let href = PubResolver.findDocument(pub: pub, root: root, number: number) {
            reference = nil
            open(href)
            return
        }
        afterSheet { $0.pushRef = ref }
    }

    /// Closes a reference sheet first (one sheet can't present another), then runs `action`.
    private func afterSheet(_ action: @escaping (ReaderModel) -> Void) {
        let wasShowing = reference != nil
        reference = nil
        guard wasShowing else {
            action(self)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if let self { action(self) }
        }
    }

    /// Links out of the publication: videos and songs play here, jw.org documents and Bible chapters
    /// open in the app, and other web pages open in an in-app browser.
    func handleExternal(_ url: URL, text: String) -> OpenURLAction.Result {
        let scheme = url.scheme?.lowercased() ?? ""
        if let item = LinkParser.media(url, lang: pub.lang, title: text.isEmpty ? "Video" : text) {
            afterSheet { $0.media = item }
            return .handled
        }
        if let ref = LinkParser.pubRef(url, lang: pub.lang, text: text) {
            if let docID = ref.docID, ref.symbol.isEmpty {
                if let route = PubResolver.installedDocument(docID) {
                    if route.pubID == pub.id, let href = route.href {
                        reference = nil
                        open(href)
                    } else {
                        afterSheet { $0.pushRoute = route }
                    }
                    return .handled
                }
            } else {
                openRef(ref)
                return .handled
            }
        }
        if scheme == "http" || scheme == "https" {
            afterSheet { $0.web = WebLink(url: url) }
            return .handled
        }
        if scheme == "jwpub" || scheme == "jwlibrary" {
            // Not something the app knows; try the same document on wol.jw.org.
            if let docID = LinkParser.pubRef(url, lang: pub.lang, text: text)?.docID,
               let u = URL(string: "https://www.jw.org/finder?wtlocale=\(pub.lang)&docid=\(docID)") {
                afterSheet { $0.web = WebLink(url: u) }
                return .handled
            }
        }
        return .systemAction
    }

    static func linkURL(_ link: String, text: String = "") -> URL? {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.hasPrefix("doc:") {
            var c = URLComponents()
            c.scheme = "perla"
            c.host = "doc"
            c.queryItems = [URLQueryItem(name: "p", value: String(link.dropFirst(4))), URLQueryItem(name: "t", value: label)]
            return c.url
        }
        if link.hasPrefix("perla://"), var c = URLComponents(string: link) {
            c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "t", value: label)]
            return c.url
        }
        let fixed = URL(string: link) ?? link.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let fixed else { return nil }
        // Carry the link text along so videos and references get a title.
        var c = URLComponents()
        c.scheme = "perla"
        c.host = "web"
        c.queryItems = [URLQueryItem(name: "u", value: fixed.absoluteString), URLQueryItem(name: "t", value: label)]
        return c.url ?? fixed
    }

    // MARK: Answers

    var answeredCount: Int { answers.values.filter { $0.status == .done }.count }

    func importedAnswer(_ id: String) -> String? {
        questions.first { $0.id == id }.flatMap { ImportedAnswers.shared.answer(for: $0.text) }
    }

    /// Removes your own answer; the imported one (if any) comes back.
    func clearAnswer(_ id: String) {
        AnswerStore.shared.remove(key(id))
        if let imported = importedAnswer(id) {
            answers[id] = AnswerState(status: .done, text: imported, note: "Imported")
        } else {
            answers[id] = AnswerState()
        }
    }

    func scrollTo(_ id: String) {
        focusedID = id
        if let f = found[id], f.node >= 0 { requestScroll(to: f.node) }
    }

    /// Called as you type in an answer box. Typing over an imported answer makes it yours.
    func setAnswer(_ id: String, text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AnswerStore.shared.remove(key(id))
            answers[id] = AnswerState(status: .idle, text: text)
            return
        }
        if answers[id]?.note == "Imported", text == answers[id]?.text { return }
        answers[id] = AnswerState(status: .done, text: text, note: "Your answer")
        AnswerStore.shared.set(key(id), text: text, engine: "Your answer")
    }

    private func key(_ id: String) -> String {
        pub.id + "/" + currentFile + "#" + id
    }

    // MARK: Export

    var exportItems: [(heading: String, question: String, answer: String)] {
        questions.map { q in
            let a = answers[q.id]
            return (heading: q.heading, question: q.text, answer: a?.status == .done ? (a?.text ?? "") : "")
        }
    }

    var exportText: String {
        var out = title + "\n\n"
        for item in exportItems {
            out += item.question + "\n" + (item.answer.isEmpty ? "—" : item.answer) + "\n\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
