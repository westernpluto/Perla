import Foundation

/// Bible book names and abbreviations, so references written in the text ("Isa. 11:1-10",
/// "ISAÍAS 11, 12", "Juan 3:16") can be tapped. English and Spanish are built in; the book names of
/// any downloaded Bible are added too, so other languages work once their Bible is downloaded.
enum BibleNames {
    /// Full names, index + 1 = book number. Matched without regard to case ("ISAIAH 11").
    private static let englishNames = [
        "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua", "Judges", "Ruth", "1 Samuel",
        "2 Samuel", "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra", "Nehemiah", "Esther", "Job",
        "Psalms", "Proverbs", "Ecclesiastes", "Song of Solomon", "Isaiah", "Jeremiah", "Lamentations", "Ezekiel",
        "Daniel", "Hosea", "Joel", "Amos", "Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk", "Zephaniah", "Haggai",
        "Zechariah", "Malachi", "Matthew", "Mark", "Luke", "John", "Acts", "Romans", "1 Corinthians",
        "2 Corinthians", "Galatians", "Ephesians", "Philippians", "Colossians", "1 Thessalonians",
        "2 Thessalonians", "1 Timothy", "2 Timothy", "Titus", "Philemon", "Hebrews", "James", "1 Peter", "2 Peter",
        "1 John", "2 John", "3 John", "Jude", "Revelation",
    ]
    /// Abbreviations as printed in the publications (always followed by a period).
    private static let englishAbbr = [
        "Gen.", "Ex.", "Lev.", "Num.", "Deut.", "Josh.", "Judg.", "Ruth", "1 Sam.", "2 Sam.", "1 Ki.", "2 Ki.",
        "1 Chron.", "2 Chron.", "Ezra", "Neh.", "Esther", "Job", "Ps.", "Prov.", "Eccl.", "Song of Sol.", "Isa.",
        "Jer.", "Lam.", "Ezek.", "Dan.", "Hos.", "Joel", "Amos", "Obad.", "Jonah", "Mic.", "Nah.", "Hab.", "Zeph.",
        "Hag.", "Zech.", "Mal.", "Matt.", "Mark", "Luke", "John", "Acts", "Rom.", "1 Cor.", "2 Cor.", "Gal.",
        "Eph.", "Phil.", "Col.", "1 Thess.", "2 Thess.", "1 Tim.", "2 Tim.", "Titus", "Philem.", "Heb.", "Jas.",
        "1 Pet.", "2 Pet.", "1 John", "2 John", "3 John", "Jude", "Rev.",
    ]
    private static let spanishNames = [
        "Génesis", "Éxodo", "Levítico", "Números", "Deuteronomio", "Josué", "Jueces", "Rut", "1 Samuel",
        "2 Samuel", "1 Reyes", "2 Reyes", "1 Crónicas", "2 Crónicas", "Esdras", "Nehemías", "Ester", "Job",
        "Salmos", "Proverbios", "Eclesiastés", "El Cantar de los Cantares", "Isaías", "Jeremías", "Lamentaciones",
        "Ezequiel", "Daniel", "Oseas", "Joel", "Amós", "Abdías", "Jonás", "Miqueas", "Nahúm", "Habacuc",
        "Sofonías", "Ageo", "Zacarías", "Malaquías", "Mateo", "Marcos", "Lucas", "Juan", "Hechos", "Romanos",
        "1 Corintios", "2 Corintios", "Gálatas", "Efesios", "Filipenses", "Colosenses", "1 Tesalonicenses",
        "2 Tesalonicenses", "1 Timoteo", "2 Timoteo", "Tito", "Filemón", "Hebreos", "Santiago", "1 Pedro",
        "2 Pedro", "1 Juan", "2 Juan", "3 Juan", "Judas", "Apocalipsis",
    ]
    private static let spanishAbbr = [
        "Gén.", "Éx.", "Lev.", "Núm.", "Deut.", "Jos.", "Juec.", "Rut", "1 Sam.", "2 Sam.", "1 Rey.", "2 Rey.",
        "1 Crón.", "2 Crón.", "Esd.", "Neh.", "Est.", "Job", "Sal.", "Prov.", "Ecl.", "Cant.", "Is.", "Jer.",
        "Lam.", "Ezeq.", "Dan.", "Os.", "Joel", "Amós", "Abd.", "Jon.", "Miq.", "Nah.", "Hab.", "Sof.", "Ag.",
        "Zac.", "Mal.", "Mat.", "Mar.", "Luc.", "Juan", "Hech.", "Rom.", "1 Cor.", "2 Cor.", "Gál.", "Efes.",
        "Filip.", "Col.", "1 Tes.", "2 Tes.", "1 Tim.", "2 Tim.", "Tito", "Filem.", "Heb.", "Sant.", "1 Ped.",
        "2 Ped.", "1 Juan", "2 Juan", "3 Juan", "Jud.", "Apoc.",
    ]

    private static let lock = NSLock()
    private static var extraNames: [(String, Int)] = []
    private static var cached: (names: NSRegularExpression?, abbr: NSRegularExpression?, lookup: [String: Int])?

    /// Adds the book names of a downloaded Bible (any language).
    static func register(_ index: BibleIndex) {
        lock.lock()
        defer { lock.unlock() }
        var added = false
        for book in index.books where !book.name.isEmpty {
            if !extraNames.contains(where: { $0.0 == book.name }) {
                extraNames.append((book.name, book.number))
                added = true
            }
        }
        if added { cached = nil }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "")
    }

    /// "1 Samuel" → "1\s*Samuel", so "1Sam." and "1 Sam." both match.
    private static func pattern(_ name: String) -> String {
        name.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")
    }

    private static func build() -> (names: NSRegularExpression?, abbr: NSRegularExpression?, lookup: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var lookup: [String: Int] = [:]
        var names: [String] = []
        var abbrs: [String] = []
        for list in [englishNames, spanishNames] {
            for (i, n) in list.enumerated() {
                lookup[fold(n)] = i + 1
                names.append(n)
            }
        }
        for (n, num) in extraNames {
            lookup[fold(n)] = num
            names.append(n)
        }
        for list in [englishAbbr, spanishAbbr] {
            for (i, a) in list.enumerated() where a.hasSuffix(".") {
                lookup[fold(a)] = i + 1
                abbrs.append(a)
            }
        }
        let tail = "\\s+(\\d{1,3})(?:\\s*:\\s*(\\d{1,3})(?:\\s*[-–]\\s*(\\d{1,3}))?)?(?![\\d:])"
        func re(_ list: [String], caseless: Bool) -> NSRegularExpression? {
            let alts = Set(list).sorted { $0.count > $1.count }.map(pattern).joined(separator: "|")
            let p = "(?<![\\p{L}\\d])(\(alts))" + tail
            return try? NSRegularExpression(pattern: p, options: caseless ? [.caseInsensitive] : [])
        }
        let built = (names: re(names, caseless: true), abbr: re(abbrs, caseless: false), lookup: lookup)
        cached = built
        return built
    }

    struct Match {
        let range: NSRange
        let book: Int
        let chapter: Int
        let verse: Int?
        let verseEnd: Int?
    }

    /// Every Bible reference in `text`.
    static func matches(in text: String) -> [Match] {
        let (names, abbr, lookup) = build()
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out: [Match] = []
        for re in [names, abbr].compactMap({ $0 }) {
            for m in re.matches(in: text, range: all) {
                let bookText = ns.substring(with: m.range(at: 1))
                guard let book = lookup[fold(bookText)], let ch = Int(ns.substring(with: m.range(at: 2))) else { continue }
                func group(_ i: Int) -> Int? {
                    m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i)))
                }
                out.append(Match(range: m.range, book: book, chapter: ch, verse: group(3), verseEnd: group(4)))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }
}

/// Reads verses out of a Bible chapter document.
enum BibleText {
    /// The verses `from...to` of a parsed chapter, as one paragraph with verse numbers.
    static func verses(in doc: Document, from: Int, to: Int) -> DocNode? {
        var current = 0
        var texts: [Int: String] = [:]
        for top in doc.nodes {
            top.walk { n in
                guard n.kind == .text, n.role == .paragraph || n.role == .listItem else { return }
                for r in n.runs {
                    let t = r.text.trimmingCharacters(in: .whitespaces)
                    if r.chapterNum {
                        current = 1
                    } else if r.sup, !r.isNoteMark, let v = Int(t) {
                        current = v
                    } else if r.isNoteMark || (r.link != nil && t.count <= 2) {
                        continue
                    } else if current > 0 {
                        texts[current, default: ""] += r.text
                    }
                }
                if current > 0 { texts[current, default: ""] += " " }
            }
        }
        var runs: [InlineRun] = []
        for v in from...max(from, to) {
            guard let t = texts[v]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
            var num = InlineRun(text: (runs.isEmpty ? "" : " ") + "\(v) ")
            num.sup = true
            num.bold = true
            runs.append(num)
            runs.append(InlineRun(text: t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)))
        }
        guard !runs.isEmpty else { return nil }
        var node = DocNode(kind: .text, tag: "p")
        node.runs = runs
        node.plain = runs.map(\.text).joined()
        return node
    }
}
