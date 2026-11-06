import Foundation

/// Finds the part of a workbook or Watchtower issue that is scheduled for a given week,
/// by reading the dates printed in the publication (in any supported language).
enum WeekFinder {
    struct Match {
        let href: String
        let label: String
        let start: Date
    }

    static func find(in pub: InstalledPub, week date: Date, root: URL) -> Match? {
        let locale = Locale(identifier: PubLanguage.find(pub.lang).locale)
        let weekStart = Issues.weekStart(date)
        let cal = Issues.calendar

        func inWeek(_ d: Date) -> Bool {
            let s = Issues.weekStart(d)
            return cal.isDate(s, inSameDayAs: weekStart)
        }
        func label(for file: String, fallback: String) -> String {
            pub.toc.first { $0.file == file }?.label ?? fallback
        }

        // 1. Table of contents labels (workbook weeks are titled with their dates).
        for entry in pub.toc {
            if let d = startDate(in: entry.label, locale: locale, near: date), inWeek(d) {
                return Match(href: entry.href, label: entry.label, start: d)
            }
        }

        // 2. A date printed at the top of a document ("NOVEMBER 9-15, 2026") is that document's week.
        //    A date next to a link to another document is a contents page entry; it's only used if no
        //    document carries the date itself.
        var linkMatch: Match?
        var best: (match: Match, position: Int)?
        for file in pub.spine {
            guard let html = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { continue }
            let blocks = HTMLText.blocks(html)
            var seenText = 0
            for (i, block) in blocks.enumerated() {
                if !block.text.isEmpty { seenText += 1 }
                guard seenText <= 12 || linkMatch == nil else { break }
                let head = String(block.text.prefix(180))
                guard let d = startDate(in: head, locale: locale, near: date), inWeek(d) else { continue }
                let nearby = blocks[i..<min(blocks.count, i + 3)].flatMap(\.hrefs)
                    .filter { !$0.hasPrefix("http") && !$0.hasPrefix("#") && !$0.contains("-extracted") }
                if let h = nearby.first {
                    if linkMatch == nil {
                        let target = EPUBParser.path(h, relativeTo: file)
                        let targetFile = target.components(separatedBy: "#").first ?? target
                        let nextText = blocks[i..<min(blocks.count, i + 3)].map(\.text).first { !$0.isEmpty && $0 != block.text }
                        linkMatch = Match(href: target, label: label(for: targetFile, fallback: nextText ?? block.text), start: d)
                    }
                } else if seenText <= 4, best == nil || seenText < best!.position {
                    best = (Match(href: file, label: label(for: file, fallback: block.text), start: d), seenText)
                    if seenText == 1 { return best!.match }
                }
            }
        }
        return best?.match ?? linkMatch
    }

    /// Reads the first date in `text` ("October 26–November 1", "26 de octubre a 1 de noviembre",
    /// "1-7 de diciembre", "1.–7. Dezember") and returns the start day, in the year closest to `near`.
    static func startDate(in text: String, locale: Locale, near: Date) -> Date? {
        let folded = fold(text, locale)
        guard folded.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }

        // Every month name in the text, in reading order.
        var hits: [(range: Range<String.Index>, month: Int)] = []
        for (i, name) in monthNames(locale).enumerated() where !name.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            var searchStart = folded.startIndex
            while searchStart < folded.endIndex,
                  let r = folded.range(of: pattern, options: .regularExpression, range: searchStart..<folded.endIndex) {
                hits.append((r, i % 12 + 1))
                searchStart = r.upperBound
            }
        }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }

        let beforePattern = "(\\d{1,2})\\.?(?:\\s*(?:[-–—]|a|al|to|au|bis|e|y|and)\\s*\\d{1,2}\\.?)?\\s*(?:de|del|di)?\\s*$"
        var found: [Date] = []
        for hit in hits {
            let before = String(folded[folded.startIndex..<hit.range.lowerBound].suffix(24))
            let after = String(folded[hit.range.upperBound...].prefix(10))
            var day: Int?
            if let r = before.range(of: beforePattern, options: .regularExpression),
               let num = before[r].range(of: "\\d{1,2}", options: .regularExpression) {
                day = Int(before[r][num])
            } else if let r = after.range(of: "^\\.?\\s*\\d{1,2}", options: .regularExpression),
                      let num = after[r].range(of: "\\d{1,2}", options: .regularExpression) {
                day = Int(after[r][num])
            }
            guard let d = day, (1...31).contains(d), let date = closest(month: hit.month, day: d, near: near) else { continue }
            found.append(date)
        }
        guard let start = found.first else { return nil }
        // "Study articles for: November 2–December 6" names a whole issue, not a week.
        if let last = found.last, last.timeIntervalSince(start) > 8 * 86_400 { return nil }
        return start
    }

    private static func closest(month: Int, day: Int, near: Date) -> Date? {
        let cal = Issues.calendar
        let year = cal.component(.year, from: near)
        var choice: Date?
        for y in [year - 1, year, year + 1] {
            guard let candidate = cal.date(from: DateComponents(year: y, month: month, day: day)) else { continue }
            if let c = choice, abs(candidate.timeIntervalSince(near)) >= abs(c.timeIntervalSince(near)) { continue }
            choice = candidate
        }
        return choice
    }

    /// "October" / "octubre" → 10, in the publication's language or English.
    static func month(named name: String, lang: String) -> Int? {
        let word = name.trimmingCharacters(in: .punctuationCharacters)
        for loc in [Locale(identifier: PubLanguage.find(lang).locale), Locale(identifier: "en_US")] {
            let names = monthNames(loc)
            if let i = names.firstIndex(of: fold(word, loc)) { return i % 12 + 1 }
        }
        return nil
    }

    private static func monthNames(_ locale: Locale) -> [String] {
        let f = DateFormatter()
        f.locale = locale
        let full = (f.monthSymbols ?? []) + (f.standaloneMonthSymbols ?? [])
        return full.map { fold($0, locale) }
    }

    private static func fold(_ s: String, _ locale: Locale) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
}
