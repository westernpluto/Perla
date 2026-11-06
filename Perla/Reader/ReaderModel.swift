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

struct EditRequest: Identifiable {
    let id: String
    var text: String
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
    @Published private(set) var highlights: [Int: [String]] = [:]
    @Published var scrollRequest: ScrollRequest?
    @Published var reference: ReferenceSheet?
    @Published var editing: EditRequest?
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
    private var keyText: [String: String] = [:]
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
        keyText = [:]
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

        // Questions, where their answers go, and the sentences that answer them.
        var list: [PageQuestion] = []
        var atField: [Int: String] = [:]
        var afterNode: [Int: String] = [:]
        var marks: [Int: [String]] = [:]
        if !pub.isBible {
            for f in QuestionFinder.find(newDoc) {
                list.append(f.question)
                found[f.question.id] = f
                if let field = f.field { atField[field] = f.question.id } else { afterNode[f.node] = f.question.id }
                let paragraphs = f.related.compactMap { byID[$0]?.plain }
                if !paragraphs.isEmpty {
                    let picked = KeySentences.pick(question: f.question.text, paragraphs: paragraphs)
                    keyText[f.question.id] = picked.joined(separator: " ")
                    for sentence in picked {
                        if let b = f.related.first(where: { byID[$0]?.plain.contains(sentence) ?? false }) {
                            marks[b, default: []].append(sentence)
                        }
                    }
                } else {
                    let research = references(for: f).map(\.text).joined(separator: " ")
                    let picked = KeySentences.pick(question: f.question.text, paragraphs: [research])
                    keyText[f.question.id] = picked.joined(separator: " ")
                }
            }
        }
        questions = list
        questionAtField = atField
        questionAfterNode = afterNode
        highlights = Prefs.highlight ? marks : [:]
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

    func refreshHighlights() {
        guard Prefs.highlight else {
            highlights = [:]
            return
        }
        var marks: [Int: [String]] = [:]
        for f in found.values where !f.related.isEmpty {
            let paragraphs = f.related.compactMap { nodeByID[$0]?.plain }
            for sentence in KeySentences.pick(question: f.question.text, paragraphs: paragraphs) {
                if let b = f.related.first(where: { nodeByID[$0]?.plain.contains(sentence) ?? false }) {
                    marks[b, default: []].append(sentence)
                }
            }
        }
        highlights = marks
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

    /// Verses, footnotes and research a question points to.
    private func references(for f: FoundQuestion) -> [Reference] {
        var links = f.links
        if links.isEmpty, !f.isStudyQuestion {
            // e.g. "What spiritual gems have you found?": use the verses cited earlier in the week.
            for t in doc.nodes {
                guard t.id < f.node else { break }
                t.walk { n in
                    guard n.role != .h1, n.role != .h2 else { return }
                    for r in n.runs { if let l = r.link, l.contains("#citation"), !links.contains(l) { links.append(l) } }
                }
            }
        }
        var out: [Reference] = []
        for l in links {
            guard let hash = l.firstIndex(of: "#") else { continue }
            let frag = String(l[l.index(after: hash)...])
            if frag.hasPrefix("pcitation"), let r = extracted[frag] { out.append(r) }
            else if frag.hasPrefix("citation"), let r = doc.citations[frag] { out.append(r) }
            else if frag.hasPrefix("footnote"), let r = doc.footnotes[frag] { out.append(r) }
        }
        return out
    }

    // MARK: Answers

    var answeredCount: Int { answers.values.filter { $0.status == .done }.count }

    /// The sentence from the paragraph that answers the question (highlighted on the page).
    func paragraphText(_ id: String) -> String {
        (keyText[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func useParagraph(_ id: String) {
        let t = paragraphText(id)
        guard !t.isEmpty else { return }
        answers[id] = AnswerState(status: .done, text: t, note: "From the paragraph")
        AnswerStore.shared.set(key(id), text: t, engine: "From the paragraph")
    }

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

    func beginEdit(_ id: String) {
        editing = EditRequest(id: id, text: answers[id]?.text ?? "")
    }

    func saveEdit(_ id: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            clearAnswer(id)
            return
        }
        answers[id] = AnswerState(status: .done, text: t, note: "Your answer")
        AnswerStore.shared.set(key(id), text: t, engine: "Your answer")
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
