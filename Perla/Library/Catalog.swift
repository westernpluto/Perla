import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Publications offered in the Library, grouped like JW Library. Every symbol here was checked to
/// have an EPUB on jw.org. Titles are only used before a download; after that the publication's own
/// title (in its language) is shown.
struct CatalogItem: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case bible, books, brochures
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bible: return L("Bible")
            case .books: return L("Books")
            case .brochures: return L("Brochures and Booklets")
            }
        }
        var icon: String {
            switch self {
            case .bible: return "book.closed"
            case .books: return "books.vertical"
            case .brochures: return "doc.text"
            }
        }
    }

    let symbol: String
    let title: String
    var category: Category = .books
    var id: String { symbol }

    static let all: [CatalogItem] = [
        CatalogItem(symbol: "nwt", title: "New World Translation of the Holy Scriptures (2013 Revision)", category: .bible),
        // The Study Edition is only published as JWPUB and PDF; Perla reads the 2013 Bible (EPUB) and
        // shows the Study Edition's notes beside it.
        CatalogItem(symbol: "nwtsty", title: "New World Translation (Study Edition)", category: .bible),
        CatalogItem(symbol: "bi12", title: "New World Translation (1984 Edition)", category: .bible),

        CatalogItem(symbol: "lff", title: "Enjoy Life Forever!"),
        CatalogItem(symbol: "lmd", title: "Love People—Make Disciples"),
        CatalogItem(symbol: "th", title: "Apply Yourself to Reading and Teaching"),
        CatalogItem(symbol: "wcg", title: "Walk Courageously With God"),
        CatalogItem(symbol: "lfb", title: "Lessons You Can Learn From the Bible"),
        CatalogItem(symbol: "jr", title: "God’s Word for Us Through Jeremiah"),
        CatalogItem(symbol: "ia", title: "Imitate Their Faith"),
        CatalogItem(symbol: "cl", title: "Draw Close to Jehovah"),
        CatalogItem(symbol: "jy", title: "Jesus—The Way, the Truth, the Life"),
        CatalogItem(symbol: "cf", title: "“Come Be My Follower”"),
        CatalogItem(symbol: "lvs", title: "How to Remain in God’s Love"),
        CatalogItem(symbol: "lv", title: "“Keep Yourselves in God’s Love”"),
        CatalogItem(symbol: "rr", title: "Pure Worship of Jehovah—Restored At Last!"),
        CatalogItem(symbol: "bt", title: "“Bearing Thorough Witness” About God’s Kingdom"),
        CatalogItem(symbol: "od", title: "Organized to Do Jehovah’s Will"),
        CatalogItem(symbol: "sjj", title: "“Sing Out Joyfully” to Jehovah"),
        CatalogItem(symbol: "sjjls", title: "“Sing Out Joyfully” to Jehovah (Large Print)"),
        CatalogItem(symbol: "bhs", title: "What Can the Bible Teach Us?"),
        CatalogItem(symbol: "lr", title: "Learn From the Great Teacher"),
        CatalogItem(symbol: "my", title: "My Book of Bible Stories"),
        CatalogItem(symbol: "gt", title: "The Greatest Man Who Ever Lived"),
        CatalogItem(symbol: "jd", title: "Live With Jehovah’s Day in Mind"),
        CatalogItem(symbol: "be", title: "Benefit From Theocratic Ministry School Education"),
        CatalogItem(symbol: "fy", title: "The Secret of Family Happiness"),
        CatalogItem(symbol: "yb17", title: "2017 Yearbook of Jehovah’s Witnesses"),

        CatalogItem(symbol: "jl", title: "Who Are Doing Jehovah’s Will Today?", category: .brochures),
        CatalogItem(symbol: "rj", title: "Return to Jehovah", category: .brochures),
        CatalogItem(symbol: "ll", title: "Listen to God and Live Forever", category: .brochures),
        CatalogItem(symbol: "fg", title: "Good News From God!", category: .brochures),
        CatalogItem(symbol: "hl", title: "How Can You Have a Happy Life?", category: .brochures),
        CatalogItem(symbol: "lc", title: "Was Life Created?", category: .brochures),
        CatalogItem(symbol: "hf", title: "Your Family Can Be Happy", category: .brochures),
        CatalogItem(symbol: "ypq", title: "Answers to 10 Questions Young People Ask", category: .brochures),
        CatalogItem(symbol: "mb", title: "My Bible Lessons", category: .brochures),
        CatalogItem(symbol: "bm", title: "The Bible—What Is Its Message?", category: .brochures),
        CatalogItem(symbol: "ed", title: "Jehovah’s Witnesses and Education", category: .brochures),
        CatalogItem(symbol: "wi", title: "Will There Ever Be a World Without War?", category: .brochures),
        CatalogItem(symbol: "la", title: "A Satisfying Life—How to Attain It", category: .brochures),
        CatalogItem(symbol: "sp", title: "Spirits of the Dead", category: .brochures),
        CatalogItem(symbol: "ol", title: "The Road to Everlasting Life", category: .brochures),
        CatalogItem(symbol: "gf", title: "You Can Be God’s Friend!", category: .brochures),
    ]

    /// Kept for older call sites: everything except the Bible.
    static var books: [CatalogItem] { all }

    static func items(in category: Category) -> [CatalogItem] { all.filter { $0.category == category } }

    /// The EPUB that is downloaded for this entry (the Study Edition reads the 2013 Bible).
    var downloadSymbol: String { symbol == "nwtsty" ? "nwt" : symbol }

    /// The title in the publication language, once jw.org has given it; English until then.
    func localizedTitle(lang: String) -> String {
        CatalogNames.name(symbol: symbol, lang: lang) ?? title
    }
}

/// Publication names in each language, as jw.org gives them ("La Biblia. Traducción del Nuevo Mundo
/// (edición de estudio)"), fetched once and kept.
enum CatalogNames {
    private static let key = "catalogNames"

    static func name(symbol: String, lang: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?["\(lang)_\(symbol)"]
    }

    /// Fetches the names that aren't known yet for `lang`. Returns true if anything new came in.
    static func load(symbols: [String], lang: String) async -> Bool {
        let missing = symbols.filter { name(symbol: $0, lang: lang) == nil }
        guard !missing.isEmpty else { return false }
        let found = await withTaskGroup(of: (String, String?).self) { group in
            for sym in missing {
                group.addTask {
                    var c = URLComponents(string: "https://b.jw-cdn.org/apis/pub-media/GETPUBMEDIALINKS")!
                    c.queryItems = [URLQueryItem(name: "output", value: "json"), URLQueryItem(name: "pub", value: sym),
                                    URLQueryItem(name: "alllangs", value: "0"), URLQueryItem(name: "langwritten", value: lang)]
                    guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let raw = obj["pubName"] as? String else { return (sym, nil) }
                    return (sym, HTMLText.decode(raw))
                }
            }
            var out: [String: String] = [:]
            for await (sym, name) in group { if let name, !name.isEmpty { out[sym] = name } }
            return out
        }
        guard !found.isEmpty else { return false }
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        for (sym, n) in found { all["\(lang)_\(sym)"] = n }
        UserDefaults.standard.set(all, forKey: key)
        return true
    }
}

enum Issues {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        return c
    }

    /// Meeting workbooks cover two months and use the odd month: 202609 = Sept–Oct 2026.
    static func workbook(for date: Date) -> String {
        let c = calendar
        let y = c.component(.year, from: date)
        var m = c.component(.month, from: date)
        if m % 2 == 0 { m -= 1 }
        return String(format: "%04d%02d", y, m)
    }

    /// Watchtower study edition issue `offset` months from `date`.
    static func watchtower(for date: Date, offset: Int) -> String {
        let shifted = calendar.date(byAdding: .month, value: offset, to: date) ?? date
        let c = calendar
        return String(format: "%04d%02d", c.component(.year, from: shifted), c.component(.month, from: shifted))
    }

    static func weekStart(_ date: Date) -> Date {
        let c = calendar
        let comps = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return c.date(from: comps).map { c.startOfDay(for: $0) } ?? c.startOfDay(for: date)
    }

    /// "202609" → "Sept–Oct 2026" for workbooks, "Sept 2026" otherwise.
    static func label(symbol: String, issue: String) -> String {
        guard issue.count >= 6, let y = Int(issue.prefix(4)), let m = Int(issue.dropFirst(4).prefix(2)),
              (1...12).contains(m) else { return issue }
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        let names = f.shortMonthSymbols ?? []
        guard names.count == 12 else { return issue }
        if symbol == "mwb", m < 12 { return "\(names[m - 1])–\(names[m]) \(y)" }
        return "\(names[m - 1]) \(y)"
    }

    /// Meeting workbook issues from two years back to the newest that may be out (odd months).
    static func workbookIssues(now: Date = Date()) -> [String] {
        let c = calendar
        var out: [String] = []
        for offset in stride(from: 4, through: -24, by: -1) {
            guard let d = c.date(byAdding: .month, value: offset, to: now) else { continue }
            let issue = workbook(for: d)
            if !out.contains(issue) { out.append(issue) }
        }
        return out
    }

    /// Watchtower study issues from 2016 (when they became monthly) to two months ahead.
    static func watchtowerIssues(now: Date = Date()) -> [String] {
        let c = calendar
        let start = c.date(from: DateComponents(year: 2016, month: 1, day: 1)) ?? now
        var out: [String] = []
        var d = c.date(byAdding: .month, value: 2, to: now) ?? now
        while d >= start {
            out.append(String(format: "%04d%02d", c.component(.year, from: d), c.component(.month, from: d)))
            guard let prev = c.date(byAdding: .month, value: -1, to: d) else { break }
            d = prev
        }
        return out
    }
}
