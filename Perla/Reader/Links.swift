import Foundation

/// Something a link points to outside the open document: another publication (a book lesson or
/// chapter, a magazine issue), a Bible chapter, or a jw.org document by its id.
struct PubRef: Hashable {
    var symbol: String
    var issue = ""
    /// Lesson, chapter or study number in a book.
    var number: Int?
    var bibleBook: Int?
    var bibleChapter: Int?
    var docID: String?
    var lang: String
    /// What the page called it, e.g. "lfb lesson 12".
    var label: String

    var isBible: Bool { bibleBook != nil }

    /// "Lesson 12" style references, shown on buttons.
    var buttonTitle: String {
        if isBible { return label.isEmpty ? "Open in the Bible" : "Open \(label)" }
        return label.isEmpty ? "Open publication" : "Open \(label)"
    }
}

/// A video or song to play inside the app.
struct MediaItem: Identifiable, Hashable {
    enum Source: Hashable {
        /// jw.org media key such as "pub-mwbv_202611_1_VIDEO".
        case key(String)
        /// jw.org download service query (pub, issue, track, docid).
        case pubMedia([String: String])
        case file(URL)
    }

    let id = UUID()
    let source: Source
    let lang: String
    let title: String
}

/// Links recognized in page text that the publication itself doesn't link: "lfb lesson 12",
/// "bt chap. 5 ¶1-7", "w24.04 p. 8", "Song 45".
enum Linkifier {
    /// Publication symbols worth turning into links (books jw.org offers as EPUB).
    static let symbols = [
        "lfb", "bt", "lff", "lmd", "th", "ia", "cl", "jy", "lvs", "rr", "kr", "wcg", "scl", "bhs", "jl",
        "rj", "lr", "ijwbv", "ijwyp", "ijwbq", "yp1", "yp2", "fg", "be", "si", "it-1", "it-2", "sjj",
    ]

    /// "lesson", "chapter", "study"… in the supported languages.
    static let unitWords = "lessons?|chapters?|chaps?\\.?|study|studies|lecci[oó]n(?:es)?|lecc?\\.|cap[ií]tulos?|caps?\\.|"
        + "le[cç]ons?|chapitres?|li[cç][aã]o|li[cç][oõ]es|estudos?|[ée]tudes?|lektion(?:en)?|kapitel|kap\\.|"
        + "lezion[ei]|capitol[oi]|studio|studi"

    static let songWords = "song|canci[oó]n|c[aâá]ntico|cantique|lied|cantico"

    private static let pubRE: NSRegularExpression? = {
        let syms = symbols.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?<![\\w-])(\(syms))\\s+(?:(?i:\(unitWords))\\s*)?(\\d{1,3})(?!\\d)")
    }()
    private static let periodicalRE = try? NSRegularExpression(pattern: "(?<![\\w-])(w|wp|g|mwb)(\\d{2})\\.(\\d{1,2})(?!\\d)")
    private static let songRE = try? NSRegularExpression(pattern: "(?i)(?<![\\w-])(?:\(songWords))\\s+(\\d{1,3})(?!\\d)")
    static let unitRE = try? NSRegularExpression(pattern: "(?i)(?<![\\w])(?:\(unitWords))\\s*(\\d{1,3})(?!\\d)")

    /// The first publication reference in `text`.
    static func pubRef(in text: String, lang: String) -> PubRef? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = pubRE?.firstMatch(in: text, range: range), let n = Int(ns.substring(with: m.range(at: 2))) {
            return PubRef(symbol: ns.substring(with: m.range(at: 1)), number: n, lang: lang,
                          label: ns.substring(with: m.range))
        }
        if let m = periodicalRE?.firstMatch(in: text, range: range),
           let yy = Int(ns.substring(with: m.range(at: 2))), let mm = Int(ns.substring(with: m.range(at: 3))),
           (1...12).contains(mm) {
            let sym = ns.substring(with: m.range(at: 1))
            return PubRef(symbol: sym, issue: String(format: "20%02d%02d", yy, mm), lang: lang,
                          label: ns.substring(with: m.range))
        }
        return nil
    }

    /// Splits runs that have no link of their own so publication references and songs become links.
    /// A reference may span several styled runs ("<em>lfb</em> lesson 12").
    static func apply(_ runs: [InlineRun]) -> [InlineRun] {
        func eligible(_ r: InlineRun) -> Bool { r.link == nil && r.icon == nil && !r.parNum && !r.chapterNum }
        guard runs.contains(where: { eligible($0) && $0.text.count >= 2 }) else { return runs }

        // One string for the block; runs that can't take a link become placeholders the patterns never match.
        let joined = NSMutableString()
        var starts: [Int] = []
        for r in runs {
            starts.append(joined.length)
            let len = (r.text as NSString).length
            if eligible(r) {
                joined.append(r.text)
            } else {
                joined.append(String(repeating: "\u{1}", count: len))
            }
        }
        let text = joined as String
        let ns = joined as NSString
        let all = NSRange(location: 0, length: ns.length)

        func label(_ r: NSRange) -> String {
            let t = ns.substring(with: r).replacingOccurrences(of: "\u{1}", with: "")
            return t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        var hits: [(range: NSRange, link: String)] = []
        for m in pubRE?.matches(in: text, range: all) ?? [] {
            let sym = ns.substring(with: m.range(at: 1))
            let n = ns.substring(with: m.range(at: 2))
            hits.append((m.range, "perla://ref?sym=\(sym)&n=\(n)&t=\(label(m.range))"))
        }
        for m in periodicalRE?.matches(in: text, range: all) ?? [] {
            let sym = ns.substring(with: m.range(at: 1))
            guard let yy = Int(ns.substring(with: m.range(at: 2))), let mm = Int(ns.substring(with: m.range(at: 3))),
                  (1...12).contains(mm) else { continue }
            hits.append((m.range, "perla://ref?sym=\(sym)&issue=\(String(format: "20%02d%02d", yy, mm))&t=\(label(m.range))"))
        }
        for b in BibleNames.matches(in: text) {
            var link = "perla://bible?b=\(b.book)&c=\(b.chapter)"
            if let v = b.verse { link += "&v=\(v)" }
            if let e = b.verseEnd { link += "&e=\(e)" }
            hits.append((b.range, link + "&t=\(label(b.range))"))
        }
        for m in songRE?.matches(in: text, range: all) ?? [] {
            hits.append((m.range, "perla://song?n=\(ns.substring(with: m.range(at: 1)))&t=\(label(m.range))"))
        }
        guard !hits.isEmpty else { return runs }
        hits.sort { $0.range.location < $1.range.location }
        var kept: [(range: NSRange, link: String)] = []
        for h in hits where kept.last.map({ h.range.location >= $0.range.location + $0.range.length }) ?? true {
            kept.append(h)
        }

        var out: [InlineRun] = []
        for (i, run) in runs.enumerated() {
            guard eligible(run) else {
                out.append(run)
                continue
            }
            let runText = run.text as NSString
            let start = starts[i]
            let end = start + runText.length
            var cursor = start
            for h in kept {
                let hs = max(h.range.location, start)
                let he = min(h.range.location + h.range.length, end)
                guard hs < he else { continue }
                if hs > cursor {
                    var plain = run
                    plain.text = runText.substring(with: NSRange(location: cursor - start, length: hs - cursor))
                    out.append(plain)
                }
                var linked = run
                linked.text = runText.substring(with: NSRange(location: hs - start, length: he - hs))
                linked.link = h.link
                out.append(linked)
                cursor = he
            }
            if cursor == start {
                out.append(run)
            } else if cursor < end {
                var rest = run
                rest.text = runText.substring(from: cursor - start)
                out.append(rest)
            }
        }
        return out
    }
}

/// Reads jw.org, wol.jw.org, jwpub:// and media links.
enum LinkParser {
    private static func query(_ url: URL) -> [String: String] {
        var q: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let v = item.value, !v.isEmpty { q[item.name.lowercased()] = v }
        }
        return q
    }

    private static func isJW(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.hasSuffix("jw.org") || host.hasSuffix("jw-cdn.org") || url.scheme?.lowercased() == "jwpub"
            || url.scheme?.lowercased() == "jwlibrary"
    }

    /// The language a jw.org link asks for (its "wtlocale"), or `fallback`.
    static func lang(_ url: URL, fallback: String) -> String {
        let q = query(url)
        if let l = q["wtlocale"] ?? q["langwritten"] ?? q["lang"], PubLanguage.all.contains(where: { $0.code == l }) {
            return l
        }
        return fallback
    }

    /// A video or song link, played inside the app.
    static func media(_ url: URL, lang fallback: String, title: String) -> MediaItem? {
        let lang = lang(url, fallback: fallback)
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "mp3", "m4a"].contains(ext) {
            return MediaItem(source: .file(url), lang: lang, title: title)
        }
        guard isJW(url) else { return nil }
        let q = query(url)

        func mediaKey(_ s: String) -> String? {
            let key = s.removingPercentEncoding ?? s
            let upper = key.uppercased()
            if upper.hasSuffix("_VIDEO") || upper.hasSuffix("_AUDIO") || key.hasPrefix("pub-") || key.hasPrefix("docid-") {
                return key
            }
            return nil
        }
        for name in ["lank", "item", "mediaitem"] {
            if let v = q[name], let key = mediaKey(v) { return MediaItem(source: .key(key), lang: lang, title: title) }
        }
        // jw.org/en/library/videos/#en/mediaitems/Category/pub-…_VIDEO
        let paths = [url.path, url.fragment ?? ""]
        for p in paths where p.contains("mediaitems") {
            if let last = p.split(separator: "/").last, let key = mediaKey(String(last)) {
                return MediaItem(source: .key(key), lang: lang, title: title)
            }
        }
        let format = q["fileformat"]?.uppercased() ?? ""
        if let pub = q["pub"], q["track"] != nil || format.contains("MP4") || format.contains("MP3") || pub.hasSuffix("v")
            || pub.hasPrefix("sjj") {
            var params: [String: String] = ["pub": pub]
            for k in ["issue", "track", "docid"] { if let v = q[k] { params[k] = v } }
            return MediaItem(source: .pubMedia(params), lang: lang, title: title)
        }
        return nil
    }

    /// A Bible chapter, a publication or a document id.
    static func pubRef(_ url: URL, lang fallback: String, text: String) -> PubRef? {
        guard isJW(url) else { return nil }
        let lang = lang(url, fallback: fallback)
        let q = query(url)
        let comps = url.path.split(separator: "/").map(String.init)

        // finder?bible=40024014 (book, chapter, verse) or a range "40024014-40024016".
        if let b = q["bible"], let first = b.split(separator: "-").first, let v = Int(first.filter(\.isNumber)), v >= 1_001_000 {
            return PubRef(symbol: "nwt", bibleBook: v / 1_000_000, bibleChapter: max(1, (v / 1000) % 1000),
                          lang: lang, label: text)
        }
        // wol.jw.org/en/wol/b/r1/lp-e/nwtsty/40/24
        if let i = comps.firstIndex(where: { $0.hasPrefix("nwt") || $0 == "bi12" || $0 == "bi7" }), i + 1 < comps.count,
           comps.contains("b"), let book = Int(comps[i + 1]) {
            let ch = i + 2 < comps.count ? Int(comps[i + 2]) ?? 1 : 1
            return PubRef(symbol: "nwt", bibleBook: book, bibleChapter: ch, lang: lang, label: text)
        }
        // jwpub://b/NWTR/40:24:14-40:24:16
        if url.scheme?.lowercased() == "jwpub", url.host?.lowercased() == "b", let last = comps.last {
            let parts = (last.split(separator: "-").first ?? "").split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2 {
                return PubRef(symbol: "nwt", bibleBook: parts[0], bibleChapter: parts[1], lang: lang, label: text)
            }
        }
        // A document id: finder?docid=…, wol …/wol/d/r1/lp-e/1102016123, jwpub://p/E:1102016123/…
        var docID = q["docid"]
        if docID == nil, comps.contains("d"), let last = comps.last(where: { $0.allSatisfy(\.isNumber) && $0.count >= 6 }) {
            docID = last
        }
        if docID == nil, url.scheme?.lowercased() == "jwpub", let first = comps.first,
           let colon = first.firstIndex(of: ":") {
            let digits = first[first.index(after: colon)...].filter(\.isNumber)
            if digits.count >= 6 { docID = String(digits) }
        }
        if let pub = q["pub"] {
            var ref = PubRef(symbol: pub, issue: q["issue"] ?? "", lang: lang, label: text)
            ref.docID = docID
            ref.number = Linkifier.pubRef(in: text, lang: lang)?.number
            return ref
        }
        if let docID {
            var ref = Linkifier.pubRef(in: text, lang: lang)
                ?? PubRef(symbol: "", lang: lang, label: text)
            ref.docID = docID
            return ref
        }
        return nil
    }
}

/// Looks up where a reference lives, downloading the publication when needed.
@MainActor
enum PubResolver {
    enum Target {
        case reader(ReaderRoute)
        case contents(PubRoute)
    }

    enum Failure: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self { case .notFound(let m): return m }
        }
    }

    static func resolve(_ ref: PubRef) async throws -> Target {
        let library = LibraryStore.shared

        if let docID = ref.docID, let found = installedDocument(docID) { return .reader(found) }

        if let book = ref.bibleBook {
            let pub = try await library.ensure(symbol: "nwt", lang: ref.lang)
            let root = library.folder(pub)
            guard let index = await BibleIndex.prepare(pub: pub, root: root) else { return .contents(PubRoute(pubID: pub.id)) }
            BibleNames.register(index)
            guard let b = index.books.first(where: { $0.number == book }) else { return .contents(PubRoute(pubID: pub.id)) }
            let ch = b.chapters.first { $0.number == (ref.bibleChapter ?? 1) } ?? b.chapters.first
            guard let ch else { return .contents(PubRoute(pubID: pub.id)) }
            return .reader(ReaderRoute(pubID: pub.id, href: ch.href))
        }

        guard !ref.symbol.isEmpty else {
            throw Failure.notFound("This document isn't in any downloaded publication.")
        }
        let pub = try await library.ensure(symbol: ref.symbol, issue: ref.issue, lang: ref.lang)
        let root = library.folder(pub)
        if let docID = ref.docID, let file = pub.spine.first(where: { $0.contains(docID) }) {
            return .reader(ReaderRoute(pubID: pub.id, href: file))
        }
        guard let number = ref.number else { return .contents(PubRoute(pubID: pub.id)) }
        let href = await Task.detached(priority: .userInitiated) { findDocument(pub: pub, root: root, number: number) }.value
        if let href { return .reader(ReaderRoute(pubID: pub.id, href: href)) }
        return .contents(PubRoute(pubID: pub.id))
    }

    /// A downloaded document whose file name carries the jw.org document id.
    static func installedDocument(_ docID: String) -> ReaderRoute? {
        for pub in LibraryStore.shared.pubs {
            if let file = pub.spine.first(where: { ($0 as NSString).lastPathComponent.contains(docID) }) {
                return ReaderRoute(pubID: pub.id, href: file)
            }
        }
        return nil
    }

    /// The lesson or chapter numbered `number`: by the "Lesson 12" / "Chapter 12" heading at the
    /// top of each document, then by the number in its contents label.
    nonisolated static func findDocument(pub: InstalledPub, root: URL, number: Int) -> String? {
        let entries = pub.readingOrder
        for e in entries {
            guard let html = try? String(contentsOf: root.appendingPathComponent(e.file), encoding: .utf8) else { continue }
            let head = String(HTMLText.plain(html).prefix(300))
            let ns = head as NSString
            if let m = Linkifier.unitRE?.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)),
               Int(ns.substring(with: m.range(at: 1))) == number {
                return e.href
            }
        }
        for e in entries {
            let label = e.label
            let ns = label as NSString
            if let m = Linkifier.unitRE?.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)),
               Int(ns.substring(with: m.range(at: 1))) == number {
                return e.href
            }
        }
        for e in entries {
            let digits = e.label.prefix { $0.isNumber || $0.isWhitespace }.filter(\.isNumber)
            if !digits.isEmpty, Int(digits) == number { return e.href }
        }
        return nil
    }
}

/// Finds the playable file behind a video or song link.
enum MediaResolver {
    enum Failure: LocalizedError {
        case notFound
        var errorDescription: String? { "This video isn't available to play." }
    }

    static func resolve(_ item: MediaItem) async throws -> URL {
        switch item.source {
        case .file(let url):
            return url
        case .key(let key):
            return try await mediator(key: key, lang: item.lang)
        case .pubMedia(let params):
            for format in ["MP4", "MP3"] {
                if let url = try? await pubMedia(params: params, format: format, lang: item.lang) { return url }
            }
            throw Failure.notFound
        }
    }

    private static func json(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.notFound }
        return obj
    }

    /// Picks the file closest to 720p.
    private static func best(_ files: [(url: String, height: Int)]) -> URL? {
        let sorted = files.sorted { a, b in
            let da = a.height <= 720 ? 720 - a.height : 10_000 + a.height
            let db = b.height <= 720 ? 720 - b.height : 10_000 + b.height
            return da < db
        }
        return sorted.lazy.compactMap { URL(string: $0.url) }.first
    }

    private static func height(_ label: Any?) -> Int {
        if let n = label as? Int { return n }
        let s = (label as? String) ?? ""
        return Int(s.filter(\.isNumber)) ?? 0
    }

    private static func mediator(key: String, lang: String) async throws -> URL {
        let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let url = URL(string: "https://b.jw-cdn.org/apis/mediator/v1/media-items/\(lang)/\(escaped)?clientType=www")
        else { throw Failure.notFound }
        let obj = try await json(url)
        guard let media = (obj["media"] as? [[String: Any]])?.first,
              let files = media["files"] as? [[String: Any]] else { throw Failure.notFound }
        let list = files.compactMap { f -> (url: String, height: Int)? in
            guard let u = f["progressiveDownloadURL"] as? String else { return nil }
            return (u, (f["frameHeight"] as? Int) ?? height(f["label"]))
        }
        guard let pick = best(list) else { throw Failure.notFound }
        return pick
    }

    private static func pubMedia(params: [String: String], format: String, lang: String) async throws -> URL {
        var c = URLComponents(string: "https://b.jw-cdn.org/apis/pub-media/GETPUBMEDIALINKS")!
        var items = [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "fileformat", value: format),
            URLQueryItem(name: "alllangs", value: "0"),
            URLQueryItem(name: "langwritten", value: lang),
            URLQueryItem(name: "txtCMSLang", value: lang),
        ]
        for (k, v) in params { items.append(URLQueryItem(name: k, value: v)) }
        c.queryItems = items
        guard let url = c.url else { throw Failure.notFound }
        let obj = try await json(url)
        guard let files = obj["files"] as? [String: Any] else { throw Failure.notFound }
        let blocks = [files[lang]].compactMap { $0 } + files.values.map { $0 }
        let track = params["track"].flatMap { Int($0) }
        for block in blocks {
            guard let formats = block as? [String: Any],
                  let key = formats.keys.first(where: { $0.uppercased() == format }),
                  let list = formats[key] as? [[String: Any]] else { continue }
            let matching = list.filter { item in
                guard let track else { return true }
                return (item["track"] as? Int) == track
            }
            let files = (matching.isEmpty ? list : matching).compactMap { item -> (url: String, height: Int)? in
                guard let file = item["file"] as? [String: Any], let u = file["url"] as? String else { return nil }
                return (u, (item["frameHeight"] as? Int) ?? height(item["label"]))
            }
            if let pick = best(files) { return pick }
        }
        throw Failure.notFound
    }
}
