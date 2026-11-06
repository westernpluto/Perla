import SwiftUI

@MainActor
final class MeetingsModel: ObservableObject {
    struct Part {
        let pub: InstalledPub
        let match: WeekFinder.Match
    }

    @Published var workbook: Part?
    @Published var watchtower: Part?
    /// This week's Congregation Bible Study lesson, read from the workbook.
    @Published var bibleStudy: PubRef?
    @Published var workbookNote: String?
    @Published var watchtowerNote: String?
    @Published var loading = false
    private var loadedKey = ""

    func refresh(force: Bool = false) async {
        let library = LibraryStore.shared
        let lang = Prefs.langCode
        let today = Date()
        let week = Issues.weekStart(today)
        let key = "\(lang)|\(week.timeIntervalSince1970)"
        guard force || key != loadedKey, !loading else { return }
        loading = true
        defer { loading = false }

        // Midweek meeting: the workbook issue that holds this week's Monday (or Sunday).
        workbookNote = "Getting this week's workbook…"
        let sunday = Issues.calendar.date(byAdding: .day, value: 6, to: week) ?? week
        var workbookIssues = [Issues.workbook(for: week)]
        if Issues.workbook(for: sunday) != workbookIssues[0] { workbookIssues.append(Issues.workbook(for: sunday)) }
        var found: Part?
        var lastError: String?
        for issue in workbookIssues {
            do {
                let pub = try await library.ensure(symbol: "mwb", issue: issue, lang: lang)
                let folder = library.folder(pub)
                if let m = await Task.detached(operation: { WeekFinder.find(in: pub, week: today, root: folder) }).value {
                    found = Part(pub: pub, match: m)
                    break
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        workbook = found
        workbookNote = found == nil ? (lastError ?? "This week wasn't found in the workbook.") : nil
        if let found {
            let file = library.folder(found.pub).appendingPathComponent(found.match.href.components(separatedBy: "#")[0])
            let lang = found.pub.lang
            bibleStudy = await Task.detached { BibleStudyFinder.find(file: file, lang: lang) }.value
        } else {
            bibleStudy = nil
        }

        // Weekend meeting: Watchtower study issues come out about two months ahead.
        watchtowerNote = "Getting this week's Watchtower…"
        var wtFound: Part?
        lastError = nil
        for offset in [-2, -3, -1, -4] {
            let issue = Issues.watchtower(for: week, offset: offset)
            do {
                let pub = try await library.ensure(symbol: "w", issue: issue, lang: lang)
                let folder = library.folder(pub)
                if let m = await Task.detached(operation: { WeekFinder.find(in: pub, week: today, root: folder) }).value {
                    wtFound = Part(pub: pub, match: m)
                    break
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        watchtower = wtFound
        watchtowerNote = wtFound == nil ? (lastError ?? "This week's study article wasn't found.") : nil
        loadedKey = key
    }
}

struct MeetingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = MeetingsModel()
    @AppStorage(Prefs.Key.lang) private var lang = "E"

    var body: some View {
        List {
            Section {
                MeetingRow(title: "Midweek meeting",
                           icon: "person.2.wave.2",
                           part: model.workbook,
                           note: model.workbookNote,
                           loading: model.loading)
                if let study = model.bibleStudy {
                    NavigationLink(value: study) {
                        HStack(spacing: 14) {
                            Image(systemName: "book.pages")
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Congregation Bible Study").font(.headline)
                                Text(study.label).font(.subheadline)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                MeetingRow(title: "Watchtower Study",
                           icon: "building.columns",
                           part: model.watchtower,
                           note: model.watchtowerNote,
                           loading: model.loading)
            } header: {
                Text("This week · " + weekLabel)
            } footer: {
                Text("Tap an answer box to write your answer, or import an answers file in Settings. Tap the speech bubble for the list of questions.")
            }

            if let wb = model.workbook?.pub {
                Section("Workbook · \(Issues.label(symbol: "mwb", issue: wb.issue))") {
                    ForEach(wb.readingOrder) { entry in
                        NavigationLink(value: ReaderRoute(pubID: wb.id, href: entry.href)) {
                            Text(entry.label)
                        }
                    }
                }
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

    private var weekLabel: String {
        let start = Issues.weekStart(Date())
        let end = Issues.calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

struct MeetingRow: View {
    let title: String
    let icon: String
    let part: MeetingsModel.Part?
    let note: String?
    let loading: Bool

    var body: some View {
        if let part {
            NavigationLink(value: ReaderRoute(pubID: part.pub.id, href: part.match.href)) {
                row(subtitle: part.match.label, detail: part.pub.title)
            }
        } else {
            row(subtitle: note ?? "", detail: nil)
        }
    }

    private func row(subtitle: String, detail: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(part == nil ? Color.secondary : Color.primary)
                        .lineLimit(3)
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if part == nil && loading { ProgressView() }
        }
        .padding(.vertical, 6)
    }
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

/// Finds the Congregation Bible Study part of a workbook week ("lfb lesson 12", "bt chap. 5 ¶1-7").
enum BibleStudyFinder {
    static let headings = [
        "congregation bible study", "estudio biblico de la congregacion", "etude biblique de l'assemblee",
        "etude biblique de l’assemblee", "estudo biblico de congregacao", "versammlungsbibelstudium",
        "studio biblico di congregazione",
    ]

    static func find(file: URL, lang: String) -> PubRef? {
        guard let html = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let blocks = HTMLText.blocks(html).map(\.text).filter { !$0.isEmpty }
        for (i, block) in blocks.enumerated() {
            let folded = block.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard headings.contains(where: { folded.contains($0) }) else { continue }
            for text in blocks[i..<min(blocks.count, i + 4)] {
                if let ref = Linkifier.pubRef(in: text, lang: lang), ref.number != nil { return ref }
            }
        }
        return nil
    }
}
