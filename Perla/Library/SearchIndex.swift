import Foundation

struct IndexedChapter: Codable {
    var href: String
    var label: String
    var text: String
}

/// Plain-text copy of every downloaded chapter, for fast offline search.
final class SearchIndex: @unchecked Sendable {
    static let shared = SearchIndex()
    static let fileName = "perla-text.json"

    struct Hit: Identifiable, Hashable {
        let id = UUID()
        let pubID: String
        let pubTitle: String
        let href: String
        let label: String
        let snippet: String
    }

    private var cache: [String: [IndexedChapter]] = [:]
    private let lock = NSLock()

    static func build(pubID: String, folder: URL, spine: [String], toc: [TOCEntry]) {
        var chapters: [IndexedChapter] = []
        for file in spine {
            guard let html = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { continue }
            let text = HTMLText.plain(html)
            guard !text.isEmpty else { continue }
            let label = toc.first(where: { $0.file == file })?.label ?? HTMLText.title(html) ?? file
            chapters.append(IndexedChapter(href: file, label: label, text: text))
        }
        if let data = try? JSONEncoder().encode(chapters) {
            try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        }
    }

    func chapters(pubID: String, folder: URL) -> [IndexedChapter] {
        lock.lock()
        defer { lock.unlock() }
        if let c = cache[pubID] { return c }
        let url = folder.appendingPathComponent(Self.fileName)
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([IndexedChapter].self, from: $0) } ?? []
        cache[pubID] = loaded
        return loaded
    }

    func forget(_ pubID: String) {
        lock.lock()
        cache[pubID] = nil
        lock.unlock()
    }

    /// Case- and accent-insensitive search across the given publications.
    func search(_ query: String, in pubs: [(pub: InstalledPub, folder: URL)], limit: Int = 150) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var hits: [Hit] = []
        for (pub, folder) in pubs {
            for chapter in chapters(pubID: pub.id, folder: folder) {
                var searchRange = chapter.text.startIndex..<chapter.text.endIndex
                var perChapter = 0
                while let r = chapter.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                    hits.append(Hit(pubID: pub.id, pubTitle: pub.title, href: chapter.href,
                                    label: chapter.label, snippet: Self.snippet(chapter.text, around: r)))
                    perChapter += 1
                    if hits.count >= limit { return hits }
                    if perChapter >= 3 { break }
                    searchRange = r.upperBound..<chapter.text.endIndex
                }
            }
        }
        return hits
    }

    private static func snippet(_ text: String, around r: Range<String.Index>) -> String {
        let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let start = text.index(r.lowerBound, offsetBy: -70, limitedBy: lineStart) ?? lineStart
        let end = text.index(r.upperBound, offsetBy: 110, limitedBy: lineEnd) ?? lineEnd
        var s = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > lineStart { s = "…" + s }
        if end < lineEnd { s += "…" }
        return s
    }
}
