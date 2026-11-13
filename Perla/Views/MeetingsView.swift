import SwiftUI

/// One row of the Meetings tab: something to open, with a short description.
struct MeetingItem: Hashable {
    let route: ReaderRoute
    let title: String
    let detail: String
    /// The full publication this part comes from, opened instead of the workbook's text-only copy
    /// (the Bible study chapter's pictures are only in the book itself).
    var source: PubRef? = nil
}

/// What one week's meetings need: the workbook week, its Bible study lesson and the Watchtower article.
struct MeetingWeek {
    var midweek: MeetingItem?
    var bibleStudy: MeetingItem?
    var watchtower: MeetingItem?
    var midweekNote: String?
    var watchtowerNote: String?
}

enum MeetingReader {
    /// The workbook week: "November 9-15 · Jeremiah 51-52", and the Bible study it assigns.
    static func midweek(pub: InstalledPub, match: WeekFinder.Match, root: URL) -> (MeetingItem, MeetingItem?) {
        let file = match.href.components(separatedBy: "#")[0]
        let locale = Locale(identifier: PubLanguage.find(pub.lang).locale)
        var detail = match.label
        var study: MeetingItem?
        if let html = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) {
            let blocks = HTMLText.blocks(html).filter { !$0.text.isEmpty }
            let lines = blocks.prefix(2).map { $0.text.capitalized(with: locale) }
            if !lines.isEmpty { detail = lines.joined(separator: " · ") }

            // "8. Congregation Bible Study" is followed by "(30 min.) wcg chap. 16", linked to the
            // full chapter in the research file.
            for (i, block) in blocks.enumerated() {
                let folded = block.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                guard BibleStudyFinder.headings.contains(where: { folded.contains($0) }) else { continue }
                for next in blocks[i..<min(blocks.count, i + 3)] {
                    guard let href = next.hrefs.first(where: { $0.contains("#pcitation") }) else { continue }
                    let target = EPUBParser.path(href, relativeTo: file)
                    let what = next.text.replacingOccurrences(of: "^\\([^)]*\\)\\s*", with: "", options: .regularExpression)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                    var chapterTitle = ""
                    var source: PubRef?
                    let parts = target.components(separatedBy: "#")
                    if parts.count == 2,
                       let data = try? Data(contentsOf: root.appendingPathComponent(parts[0])),
                       let ref = DocParser.parse(data: data, path: parts[0]).extractedReferences()[parts[1]] {
                        let t = ReaderModel.researchTitle(ref.title)
                        source = Linkifier.research(title: t, lang: pub.lang)
                        if let q = t.firstIndex(where: { $0 == "“" || $0 == "\"" || $0 == "«" }) {
                            chapterTitle = String(t[q...])
                        }
                    }
                    study = MeetingItem(route: ReaderRoute(pubID: pub.id, href: target),
                                        title: L("Congregation Bible Study"),
                                        detail: [what, chapterTitle].filter { !$0.isEmpty }.joined(separator: " · "),
                                        source: source)
                    break
                }
                break
            }
        }
        let item = MeetingItem(route: ReaderRoute(pubID: pub.id, href: match.href), title: L("Workbook"),
                               detail: detail)
        return (item, study)
    }

    static func watchtower(pub: InstalledPub, match: WeekFinder.Match, root: URL) -> MeetingItem {
        let file = match.href.components(separatedBy: "#")[0]
        var detail = match.label
        if let html = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8),
           let t = HTMLText.title(html) {
            detail = t
        }
        return MeetingItem(route: ReaderRoute(pubID: pub.id, href: match.href), title: L("Watchtower Study"),
                           detail: detail)
    }
}

@MainActor
final class MeetingsModel: ObservableObject {
    /// Monday of the week being shown.
    @Published var week = Issues.weekStart(Date())
    @Published private(set) var current = MeetingWeek()
    @Published private(set) var loading = false
    private var cache: [String: MeetingWeek] = [:]

    var isThisWeek: Bool { Issues.calendar.isDate(week, inSameDayAs: Issues.weekStart(Date())) }

    func move(by weeks: Int) {
        week = Issues.calendar.date(byAdding: .day, value: 7 * weeks, to: week) ?? week
    }

    func go(to date: Date) {
        week = Issues.weekStart(date)
    }

    func load(force: Bool = false) async {
        let lang = Prefs.langCode
        let shown = week
        let key = "\(lang)|\(shown.timeIntervalSince1970)"
        if !force, let cached = cache[key] {
            current = cached
            return
        }
        current = MeetingWeek()
        loading = true
        let result = await load(week: shown, lang: lang)
        cache[key] = result
        // Only show it if that week is still the one picked.
        if week == shown {
            current = result
            loading = false
        }
    }

    private func load(week: Date, lang: String) async -> MeetingWeek {
        let library = LibraryStore.shared
        var result = MeetingWeek()

        // Midweek: the workbook issue that holds this week's Monday (or Sunday).
        let sunday = Issues.calendar.date(byAdding: .day, value: 6, to: week) ?? week
        var issues = [Issues.workbook(for: week)]
        if Issues.workbook(for: sunday) != issues[0] { issues.append(Issues.workbook(for: sunday)) }
        var lastError: String?
        for issue in issues {
            do {
                let pub = try await library.ensure(symbol: "mwb", issue: issue, lang: lang)
                let root = library.folder(pub)
                let found = await Task.detached { () -> (MeetingItem, MeetingItem?)? in
                    guard let m = WeekFinder.find(in: pub, week: week, root: root) else { return nil }
                    return MeetingReader.midweek(pub: pub, match: m, root: root)
                }.value
                if let found {
                    result.midweek = found.0
                    result.bibleStudy = found.1
                    break
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        if result.midweek == nil {
            result.midweekNote = lastError ?? L("This week isn't in a workbook yet.")
        }

        // Weekend: Watchtower study issues come out about two months ahead.
        lastError = nil
        for offset in [-2, -3, -1, -4] {
            do {
                let pub = try await library.ensure(symbol: "w", issue: Issues.watchtower(for: week, offset: offset),
                                                   lang: lang)
                let root = library.folder(pub)
                let found = await Task.detached { () -> MeetingItem? in
                    guard let m = WeekFinder.find(in: pub, week: week, root: root) else { return nil }
                    return MeetingReader.watchtower(pub: pub, match: m, root: root)
                }.value
                if let found {
                    result.watchtower = found
                    break
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        if result.watchtower == nil {
            result.watchtowerNote = lastError ?? L("The study article wasn't found.")
        }
        return result
    }
}

/// One week's meetings. The arrows and the calendar in the toolbar pick the week.
struct MeetingsView: View {
    @StateObject private var model = MeetingsModel()
    @AppStorage(Prefs.Key.lang) private var lang = "E"
    @State private var picking = false

    var body: some View {
        List {
            Section {
                row(model.current.midweek, icon: "person.2", fallback: L("Workbook"),
                    note: model.current.midweekNote)
                if let study = model.current.bibleStudy {
                    if let source = study.source {
                        NavigationLink(value: source) {
                            MeetingRowLabel(icon: "book", title: study.title, detail: study.detail, loading: false)
                        }
                    } else {
                        NavigationLink(value: study.route) {
                            MeetingRowLabel(icon: "book", title: study.title, detail: study.detail, loading: false)
                        }
                    }
                }
            } header: {
                Text("Midweek meeting")
            }
            Section {
                row(model.current.watchtower, icon: "text.book.closed", fallback: L("Watchtower Study"),
                    note: model.current.watchtowerNote)
            } header: {
                Text("Weekend meeting")
            }
        }
        .navigationTitle(weekTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Previous week", systemImage: "chevron.backward") { model.move(by: -1) }
                Button("Pick a week", systemImage: "list.bullet.rectangle") { picking = true }
                Button("Next week", systemImage: "chevron.forward") { model.move(by: 1) }
                SettingsButton()
            }
        }
        .sheet(isPresented: $picking) { weekPicker }
        .refreshable { await model.load(force: true) }
        .task(id: "\(lang)|\(model.week.timeIntervalSince1970)") { await model.load() }
    }

    private var weekPicker: some View {
        WeekList(selected: model.week) { week in
            model.go(to: week)
            picking = false
        }
    }

    /// "Nov 9 – 15" (or "This week")
    private var weekTitle: String {
        if model.isThisWeek { return L("This week") }
        let end = Issues.calendar.date(byAdding: .day, value: 6, to: model.week) ?? model.week
        let f = DateIntervalFormatter()
        f.locale = AppLanguage.locale
        f.dateTemplate = "MMMd"
        return f.string(from: model.week, to: end)
    }

    @ViewBuilder
    private func row(_ item: MeetingItem?, icon: String, fallback: String, note: String?) -> some View {
        if let item {
            NavigationLink(value: item.route) {
                MeetingRowLabel(icon: icon, title: item.title, detail: item.detail, loading: false)
            }
        } else {
            MeetingRowLabel(icon: icon, title: fallback,
                            detail: model.loading ? L("Getting it from jw.org…") : (note ?? ""),
                            loading: model.loading)
        }
    }
}

private struct MeetingRowLabel: View {
    let icon: String
    let title: String
    let detail: String
    let loading: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if loading { ProgressView() }
        }
        .padding(.vertical, 4)
    }
}

enum BibleStudyFinder {
    /// "Congregation Bible Study" in each supported language, folded (no accents, lowercase).
    static let headings = [
        "congregation bible study", "estudio biblico de la congregacion", "etude biblique de l'assemblee",
        "etude biblique de l’assemblee", "estudo biblico de congregacao", "versammlungsbibelstudium",
        "studio biblico di congregazione",
    ]
}

struct SettingsButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
        .sheet(isPresented: $showing) { SettingsView() }
    }
}

/// Every week from half a year back to a year ahead, grouped by month and opened at the week shown.
/// One tap picks a week.
struct WeekList: View {
    let selected: Date
    let pick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    private var weeks: [Date] {
        let cal = Issues.calendar
        let now = Issues.weekStart(Date())
        return (-26...52).compactMap { cal.date(byAdding: .day, value: 7 * $0, to: now) }
    }

    private var months: [(title: String, weeks: [Date])] {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        var out: [(String, [Date])] = []
        for w in weeks {
            let title = f.string(from: w).capitalized(with: AppLanguage.locale)
            if out.last?.0 == title { out[out.count - 1].1.append(w) } else { out.append((title, [w])) }
        }
        return out.map { (title: $0.0, weeks: $0.1) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(months, id: \.title) { month in
                        Section(month.title) {
                            ForEach(month.weeks, id: \.self) { w in
                                Button {
                                    pick(w)
                                } label: {
                                    HStack {
                                        Text(range(w)).foregroundStyle(.primary)
                                        if Issues.calendar.isDate(w, inSameDayAs: Issues.weekStart(Date())) {
                                            Text("This week").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if Issues.calendar.isDate(w, inSameDayAs: selected) {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                }
                                .id(w)
                            }
                        }
                    }
                }
                .onAppear { proxy.scrollTo(selected, anchor: .center) }
            }
            .navigationTitle("Weeks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("This week") { pick(Date()) } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func range(_ start: Date) -> String {
        let end = Issues.calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let f = DateIntervalFormatter()
        f.locale = AppLanguage.locale
        f.dateTemplate = "MMMd"
        return f.string(from: start, to: end)
    }
}
