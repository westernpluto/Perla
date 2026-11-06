import SwiftUI

/// One row of the Meetings tab: something to open, with a short description.
struct MeetingItem: Hashable {
    let route: ReaderRoute
    let title: String
    let detail: String
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
                    let parts = target.components(separatedBy: "#")
                    if parts.count == 2,
                       let data = try? Data(contentsOf: root.appendingPathComponent(parts[0])),
                       let ref = DocParser.parse(data: data, path: parts[0]).extractedReferences()[parts[1]] {
                        let t = ReaderModel.researchTitle(ref.title)
                        if let q = t.firstIndex(where: { $0 == "“" || $0 == "\"" || $0 == "«" }) {
                            chapterTitle = String(t[q...])
                        }
                    }
                    study = MeetingItem(route: ReaderRoute(pubID: pub.id, href: target),
                                        title: "Congregation Bible Study",
                                        detail: [what, chapterTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                    break
                }
                break
            }
        }
        let item = MeetingItem(route: ReaderRoute(pubID: pub.id, href: match.href), title: "Midweek meeting",
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
        return MeetingItem(route: ReaderRoute(pubID: pub.id, href: match.href), title: "Watchtower Study",
                           detail: detail)
    }
}

@MainActor
final class MeetingsModel: ObservableObject {
    /// Week 0 is this week; more are added with "Show more weeks".
    @Published var weeks: [MeetingWeek] = [MeetingWeek(), MeetingWeek()]
    @Published var loading = false
    private var loadedKey = ""
    private var loadedCount = 0

    static func weekStart(_ offset: Int) -> Date {
        let today = Issues.weekStart(Date())
        return Issues.calendar.date(byAdding: .day, value: 7 * offset, to: today) ?? today
    }

    func refresh(force: Bool = false) async {
        let lang = Prefs.langCode
        let key = "\(lang)|\(Self.weekStart(0).timeIntervalSince1970)"
        guard force || key != loadedKey, !loading else { return }
        if key != loadedKey || force { loadedCount = 0 }
        loading = true
        defer { loading = false }
        for offset in loadedCount..<weeks.count {
            weeks[offset] = await load(week: Self.weekStart(offset), lang: lang)
        }
        loadedCount = weeks.count
        loadedKey = key
    }

    /// Adds the next four weeks (as far as published workbooks and Watchtowers go).
    func showMore() async {
        weeks += Array(repeating: MeetingWeek(), count: 4)
        await refresh(force: false, extending: true)
    }

    private func refresh(force: Bool, extending: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let lang = Prefs.langCode
        for offset in loadedCount..<weeks.count {
            weeks[offset] = await load(week: Self.weekStart(offset), lang: lang)
        }
        loadedCount = weeks.count
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
        if result.midweek == nil { result.midweekNote = lastError ?? "Not in the workbook yet." }

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
        if result.watchtower == nil { result.watchtowerNote = lastError ?? "The study article wasn't found." }
        return result
    }
}

/// The coming weeks' meetings, three rows each. Tap one to open it.
struct MeetingsView: View {
    @StateObject private var model = MeetingsModel()
    @AppStorage(Prefs.Key.lang) private var lang = "E"

    var body: some View {
        List {
            ForEach(model.weeks.indices, id: \.self) { i in
                Section(header(i)) {
                    let week = model.weeks[i]
                    row(week.midweek, icon: "person.2", fallback: "Midweek meeting", note: week.midweekNote)
                    if let study = week.bibleStudy {
                        row(study, icon: "book", fallback: "", note: nil)
                    }
                    row(week.watchtower, icon: "text.book.closed", fallback: "Watchtower Study",
                        note: week.watchtowerNote)
                }
            }
            Section {
                Button {
                    Task { await model.showMore() }
                } label: {
                    Label("Show more weeks", systemImage: "calendar.badge.plus")
                }
                .disabled(model.loading)
            }
        }
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LanguageMenu() }
            ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
        }
        .refreshable { await model.refresh(force: true) }
        .task(id: lang) { await model.refresh() }
    }

    @ViewBuilder
    private func row(_ item: MeetingItem?, icon: String, fallback: String, note: String?) -> some View {
        if let item {
            NavigationLink(value: item.route) {
                MeetingRowLabel(icon: icon, title: item.title, detail: item.detail, loading: false)
            }
        } else {
            MeetingRowLabel(icon: icon, title: fallback, detail: note ?? "Getting it from jw.org…",
                            loading: note == nil)
        }
    }

    private func header(_ offset: Int) -> String {
        let start = MeetingsModel.weekStart(offset)
        let end = Issues.calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        let name = offset == 0 ? "This week" : offset == 1 ? "Next week" : "In \(offset) weeks"
        return name + " · \(f.string(from: start)) – \(f.string(from: end))"
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

/// Picks the language publications are downloaded in (the app itself stays in English).
struct LanguageMenu: View {
    @AppStorage(Prefs.Key.lang) private var lang = "E"

    var body: some View {
        Menu {
            Picker("Publication language", selection: $lang) {
                ForEach(PubLanguage.all) { l in
                    Text(l.name == l.native ? l.name : "\(l.name) · \(l.native)").tag(l.code)
                }
            }
        } label: {
            Label(PubLanguage.find(lang).native, systemImage: "globe")
                .labelStyle(.titleAndIcon)
        }
    }
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
