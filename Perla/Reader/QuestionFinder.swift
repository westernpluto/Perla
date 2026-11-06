import Foundation

struct PageQuestion: Identifiable, Hashable {
    let id: String
    let text: String
    let heading: String
    var custom = false
}

/// A question on the page and everything needed to answer it.
struct FoundQuestion {
    let question: PageQuestion
    /// The question's own text node.
    let node: Int
    /// The answer box that follows it in the publication, if there is one.
    let field: Int?
    /// Paragraphs that answer it (study articles link them explicitly).
    var related: [Int]
    /// Links in the question or its paragraphs (verses, footnotes, research).
    var links: [String]
    let isStudyQuestion: Bool
    let inReviewBox: Bool
}

/// Finds questions using the publication's own structure: a question is the paragraph
/// right before an answer box (or a "qu" study question, or a "PARA MEDITAR:"-style prompt),
/// and study questions are tied to their paragraphs by the publication's paragraph links.
enum QuestionFinder {
    static func find(_ doc: Document) -> [FoundQuestion] {
        var found: [FoundQuestion] = []
        var seen: [String: Int] = [:]
        var heading = ""
        let all = doc.allNodes

        func visit(_ siblings: [DocNode], inBox: Bool) {
            for (i, n) in siblings.enumerated() {
                if n.kind == .text, n.role == .h1 || n.role == .h2 || n.role == .h3 {
                    if !isQuestionText(n) { heading = n.plain }
                }
                if n.kind == .container {
                    let box = inBox || n.has("boxContent") || n.has("blockTeach")
                    visit(n.children, inBox: box)
                    continue
                }
                guard n.kind == .text, !n.plain.isEmpty else { continue }
                let next = i + 1 < siblings.count ? siblings[i + 1] : nil
                let field = next?.kind == .field ? next : nil
                let study = n.has("qu")
                guard field != nil || study || isPrompt(n) else { continue }

                let t = n.plain.trimmingCharacters(in: .whitespacesAndNewlines)
                let count = (seen[t] ?? 0) + 1
                seen[t] = count
                let id = "q" + hash(t) + (count > 1 ? "-\(count)" : "")
                let q = PageQuestion(id: id, text: t, heading: heading)

                var related: [Int] = []
                if study, let f = field, let pid = f.pid {
                    related = all.filter { $0.kind == .text && $0.relPid == pid - 1 }.map(\.id)
                }
                if study && related.isEmpty {
                    // Fall back to the paragraphs that follow, up to the next question.
                    var j = i + 1
                    while j < siblings.count {
                        let s = siblings[j]
                        if s.has("qu") || s.role == .h2 { break }
                        if s.kind == .text && s.runs.contains(where: \.parNum) { related.append(s.id) }
                        j += 1
                    }
                }
                found.append(FoundQuestion(question: q, node: n.id, field: field?.id, related: related,
                                           links: [], isStudyQuestion: study, inReviewBox: inBox))
            }
        }
        visit(doc.nodes, inBox: false)

        // Review-box questions draw on the paragraphs of the whole article.
        let paragraphs = all.filter { $0.kind == .text && $0.relPid != nil }
        for i in found.indices where found[i].inReviewBox && found[i].related.isEmpty {
            let stems = Set(KeySentences.stems(of: found[i].question.text))
            found[i].related = paragraphs
                .map { ($0.id, stems.intersection(KeySentences.stems(of: $0.plain)).count) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
                .map(\.0)
                .sorted()
        }

        // Links each question can draw on: its own, then its paragraphs'.
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in found.indices {
            var links: [String] = []
            for nid in [found[i].node] + found[i].related {
                for r in byID[nid]?.runs ?? [] {
                    if let l = r.link, !links.contains(l) { links.append(l) }
                }
            }
            found[i].links = links
        }
        return found
    }

    /// "PARA MEDITAR: ¿…?" / "PREGÚNTESE: “…?”" — a colored label followed by a question.
    static func isPrompt(_ n: DocNode) -> Bool {
        guard n.plain.contains("?"), let first = n.runs.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return false
        }
        return first.color != nil && first.bold && first.text.trimmingCharacters(in: .whitespaces).hasSuffix(":")
    }

    private static func isQuestionText(_ n: DocNode) -> Bool {
        n.plain.contains("?") && n.plain.count < 200 && n.has("qu")
    }

    private static func hash(_ s: String) -> String {
        var h: UInt32 = 5381
        for u in s.unicodeScalars { h = (h &<< 5) &+ h &+ u.value }
        return String(h, radix: 36)
    }
}

/// Picks the sentences in a paragraph that best answer a question, by shared words.
enum KeySentences {
    static func pick(question: String, paragraphs: [String]) -> [String] {
        let qStems = Set(stems(of: question))
        var sentences: [String] = []
        for p in paragraphs { sentences += split(p) }
        guard !sentences.isEmpty else { return [] }
        let scores = sentences.map { s -> Int in qStems.intersection(Set(stems(of: s))).count }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] || (scores[$0] == scores[$1] && $0 > $1) }) else {
            return []
        }
        if scores[best] == 0 { return [clean(sentences[0])] }
        var picked = [clean(sentences[best])]
        let next = best + 1
        if next < sentences.count, scores[next] >= 1, sentences[best].count + sentences[next].count < 420 {
            picked.append(clean(sentences[next]))
        }
        return picked.filter { !$0.isEmpty }
    }

    /// Splits into sentences without breaking citations like "Jos. 1:8" or "párr. 3".
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if ".!?…".contains(c), i + 1 < chars.count, chars[i + 1].isWhitespace {
                let next = chars[(i + 2)...].first { !$0.isWhitespace }
                let word = current.split(separator: " ").last.map(String.init) ?? ""
                let letters = word.filter(\.isLetter)
                let abbreviation = c == "." && letters.count <= 4 && (next?.isNumber ?? false)
                let lowerNext = next.map { $0.isLowercase } ?? false
                if !abbreviation && !lowerNext {
                    out.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            i += 1
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// Removes a leading paragraph number.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "^\\d{1,3}\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stems(of text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }
            .filter { $0.count > 2 && !stopwords.contains($0) }
            .map { String($0.prefix(5)) }
    }

    static let stopwords: Set<String> = [
        "que", "como", "por", "para", "con", "los", "las", "del", "una", "uno", "unos", "unas", "sus", "nos",
        "nuestro", "nuestra", "nuestros", "nuestras", "este", "esta", "estos", "estas", "ese", "esa", "eso",
        "cual", "cuales", "quien", "quienes", "cuando", "donde", "porque", "debemos", "podemos", "puede",
        "pueden", "hay", "fue", "son", "era", "ser", "mas", "muy", "sin", "sobre", "entre", "hasta",
        "tambien", "ellos", "ellas", "usted", "ustedes", "nosotros", "les", "lo", "parr", "pag", "lea", "vea",
        "mira", "the", "and", "for", "with", "that", "this", "these", "those", "what", "why", "how", "who",
        "when", "where", "which", "can", "could", "should", "would", "will", "does", "did", "are", "was",
        "were", "you", "your", "our", "his", "her", "their", "they", "them", "from", "about", "into", "have",
        "has", "had", "not", "but", "all", "may", "read", "par", "des", "est", "pour", "dans", "qui", "quoi",
        "comment", "pourquoi", "nous", "vous", "une", "nao", "sao", "uma", "seu", "sua", "nosso", "nossa",
        "der", "die", "das", "und", "ist", "wie", "warum", "wir", "sie", "ein", "eine", "che", "per", "come",
        "perche", "noi", "della", "delle", "segun", "jehova",
    ]
}

/// Answers the person imported from a Perla answers file.
@MainActor
final class ImportedAnswers {
    static let shared = ImportedAnswers()

    private var items: [String: String] = [:]
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("imported-answers.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            items = saved
        }
    }

    /// Posted after answers are imported or removed, so open pages can refresh.
    static let changed = Notification.Name("PerlaImportedAnswersChanged")

    var count: Int { items.count }

    func clear() {
        items = [:]
        save()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Accepts {"answers":[{"question":…,"answer":…}]} or a plain list of those objects. Text around the
    /// JSON (for example a ```json block copied from a chat) is ignored.
    func importFile(_ data: Data) throws -> Int {
        let json: Any
        if let parsed = try? JSONSerialization.jsonObject(with: data) {
            json = parsed
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            json = try JSONSerialization.jsonObject(with: Data(Self.jsonPart(of: text).utf8))
        }
        let list: [[String: Any]]
        if let dict = json as? [String: Any] {
            list = (dict["answers"] as? [[String: Any]]) ?? (dict["items"] as? [[String: Any]])
                ?? (dict["respuestas"] as? [[String: Any]]) ?? []
        } else {
            list = json as? [[String: Any]] ?? []
        }
        var added = 0
        for item in list {
            let q = (item["question"] ?? item["q"] ?? item["pregunta"]) as? String ?? ""
            let a = (item["answer"] ?? item["a"] ?? item["respuesta"]) as? String ?? ""
            let key = Self.normalize(q)
            guard key.count >= 4, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            items[key] = a.trimmingCharacters(in: .whitespacesAndNewlines)
            added += 1
        }
        save()
        if added > 0 { NotificationCenter.default.post(name: Self.changed, object: nil) }
        return added
    }

    func importText(_ text: String) throws -> Int {
        try importFile(Data(text.utf8))
    }

    /// The JSON object or list inside a longer text.
    private static func jsonPart(of text: String) -> String {
        let opens = [text.firstIndex(of: "{"), text.firstIndex(of: "[")].compactMap { $0 }
        guard let start = opens.min() else { return text }
        let close: Character = text[start] == "{" ? "}" : "]"
        guard let end = text.lastIndex(of: close), end > start else { return text }
        return String(text[start...end])
    }

    func answer(for question: String) -> String? {
        let key = Self.normalize(question)
        guard !key.isEmpty else { return nil }
        if let exact = items[key] { return exact }
        guard key.count >= 15 else { return nil }
        let match = items.keys.filter { $0.count >= 15 && ($0.contains(key) || key.contains($0)) }
            .max { $0.count < $1.count }
        return match.flatMap { items[$0] }
    }

    static func normalize(_ q: String) -> String {
        var s = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        s = s.replacingOccurrences(of: "^\\s*[\\d\\s,y–-]+[.)]\\s*", with: "", options: .regularExpression)
        s = String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return s.split(separator: " ").joined(separator: " ")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
    }
}
