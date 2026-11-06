import Foundation

/// Publications offered in the Library tab. Titles here are only used before a
/// download; after that the publication's own title (in its language) is shown.
struct CatalogItem: Identifiable, Hashable {
    let symbol: String
    let title: String
    var id: String { symbol }

    static let books: [CatalogItem] = [
        CatalogItem(symbol: "nwt", title: "New World Translation (Bible)"),
        CatalogItem(symbol: "lff", title: "Enjoy Life Forever!"),
        CatalogItem(symbol: "wcg", title: "Congregation Bible Study book"),
        CatalogItem(symbol: "lmd", title: "Love People—Make Disciples"),
        CatalogItem(symbol: "th", title: "Apply Yourself to Reading and Teaching"),
        CatalogItem(symbol: "ia", title: "Imitate Their Faith"),
        CatalogItem(symbol: "cl", title: "Draw Close to Jehovah"),
        CatalogItem(symbol: "lvs", title: "Keep Yourselves in God's Love"),
        CatalogItem(symbol: "rr", title: "Pure Worship of Jehovah—Restored At Last!"),
        CatalogItem(symbol: "kr", title: "God's Kingdom Rules!"),
        CatalogItem(symbol: "bt", title: "“Bearing Thorough Witness”"),
        CatalogItem(symbol: "lfb", title: "Lessons You Can Learn From the Bible"),
        CatalogItem(symbol: "sjj", title: "Sing Out Joyfully to Jehovah"),
        CatalogItem(symbol: "jr", title: "God’s Word for Us Through Jeremiah"),
        CatalogItem(symbol: "bhs", title: "What Can the Bible Teach Us?"),
        CatalogItem(symbol: "jy", title: "Jesus—The Way, the Truth, the Life"),
    ]
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
        f.locale = Locale(identifier: "en_US")
        let names = f.shortMonthSymbols ?? []
        guard names.count == 12 else { return issue }
        if symbol == "mwb", m < 12 { return "\(names[m - 1])–\(names[m]) \(y)" }
        return "\(names[m - 1]) \(y)"
    }
}
