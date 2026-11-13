import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Study notes from the New World Translation Study Edition (nwtsty). jw.org publishes that edition
/// only as JWPUB and PDF, not EPUB, so the notes come from its pages on wol.jw.org (Watchtower Online
/// Library) and are drawn natively. They need a connection the first time; each chapter is kept on the
/// phone after that.
enum StudyNotes {
    /// One verse's notes: each is a term in bold ("by no means will a stone be left:") and its explanation.
    typealias Chapter = [Int: [DocNode]]

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? {
            L("The study notes couldn't be loaded. They need an internet connection the first time.")
        }
    }

    /// wol.jw.org's address for each language: site language, library and language code.
    private static let sites: [String: String] = [
        "E": "en/wol/b/r1/lp-e", "S": "es/wol/b/r4/lp-s", "F": "fr/wol/b/r30/lp-f",
        "T": "pt/wol/b/r5/lp-t", "X": "de/wol/b/r10/lp-x", "I": "it/wol/b/r6/lp-i",
    ]

    static func url(lang: String, book: Int, chapter: Int) -> URL? {
        URL(string: "https://wol.jw.org/\(sites[lang] ?? sites["E"]!)/nwtsty/\(book)/\(chapter)")
    }

    private static func cacheURL(lang: String, book: Int, chapter: Int) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(lang)-\(book)-\(chapter).html")
    }

    static func load(lang: String, book: Int, chapter: Int) async throws -> Chapter {
        let cache = cacheURL(lang: lang, book: book, chapter: chapter)
        if let html = try? String(contentsOf: cache, encoding: .utf8) {
            return parse(html, book: book, chapter: chapter)
        }
        guard let url = url(lang: lang, book: book, chapter: chapter) else { throw Failure.unavailable }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw Failure.unavailable
        }
        let notes = parse(html, book: book, chapter: chapter)
        if !notes.isEmpty { try? html.write(to: cache, atomically: true, encoding: .utf8) }
        return notes
    }

    /// Reads the study note sections (`<div class="section" data-key="40-24-2">`) of a chapter page.
    static func parse(_ html: String, book: Int, chapter: Int) -> Chapter {
        var out: Chapter = [:]
        let marker = "<div class=\"section\" data-key=\""
        var parts = html.components(separatedBy: marker)
        guard parts.count > 1 else { return out }
        parts.removeFirst()
        for part in parts {
            guard let q = part.firstIndex(of: "\"") else { continue }
            let key = part[..<q].split(separator: "-").compactMap { Int($0) }
            guard key.count >= 3, key[0] == book, key[1] == chapter else { continue }
            var nodes: [DocNode] = []
            for item in part.components(separatedBy: "class=\"item studyNote\"").dropFirst() {
                let body = item.components(separatedBy: "</li>").first ?? item
                for p in body.components(separatedBy: "<p").dropFirst() {
                    guard let start = p.firstIndex(of: ">") else { continue }
                    let inner = String(p[p.index(after: start)...]).components(separatedBy: "</p>").first ?? ""
                    let runs = runs(inner)
                    guard !runs.isEmpty else { continue }
                    var n = DocNode(kind: .text, tag: "p")
                    n.runs = runs
                    n.plain = runs.map(\.text).joined()
                    nodes.append(n)
                }
            }
            if !nodes.isEmpty { out[key[2], default: []] += nodes }
        }
        return out
    }

    /// Text with its bold parts; links and other markup are dropped.
    private static func runs(_ html: String) -> [InlineRun] {
        var out: [InlineRun] = []
        var bold = false
        var rest = Substring(html)
        func add(_ text: Substring) {
            let t = HTMLText.decode(String(text))
            guard !t.isEmpty else { return }
            if let last = out.last, last.bold == bold {
                out[out.count - 1].text += t
            } else {
                var r = InlineRun(text: t)
                r.bold = bold
                out.append(r)
            }
        }
        while let lt = rest.firstIndex(of: "<") {
            add(rest[..<lt])
            guard let gt = rest[lt...].firstIndex(of: ">") else { break }
            let tag = rest[rest.index(after: lt)..<gt].lowercased()
            if tag.hasPrefix("strong") || tag == "b" { bold = true }
            if tag.hasPrefix("/strong") || tag == "/b" { bold = false }
            rest = rest[rest.index(after: gt)...]
        }
        add(rest)
        return DocParser.normalize(out)
    }
}
