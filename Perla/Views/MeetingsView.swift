import SwiftUI

// MARK: - Week contents

/// One part of the midweek meeting ("3. Spiritual Gems (10 min.)").
struct MeetingPart: Identifiable, Hashable {
    let id: Int
    let title: String
    let detail: String?
    let href: String
}

/// A section of the midweek meeting (Treasures, Apply Yourself, Living as Christians) with its color and icon.
struct MeetingSection: Identifiable, Hashable {
    let id: Int
    let title: String
    let color: String?
    let icon: String?
    var parts: [MeetingPart]
}

struct MidweekWeek {
    let pub: InstalledPub
    let match: WeekFinder.Match
    var dates = ""
    var bibleReading: String?
    var sections: [MeetingSection] = []
    var bibleStudy: PubRef?
}

struct WeekendWeek {
    let pub: InstalledPub
    let match: WeekFinder.Match
    var title = ""
    var theme: String?
    var image: String?
}

/// Reads a workbook week or a study article into the parts the Meetings tab lists.
enum MeetingReader {
    static func midweek(pub: InstalledPub, match: WeekFinder.Match, root: URL) -> MidweekWeek {
        var week = MidweekWeek(pub: pub, match: match)
        let file = match.href.components(separatedBy: "#")[0]
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { return week }
        let doc = DocParser.parse(data: data, path: file)
        week.bibleStudy = BibleStudyFinder.find(file: root.appendingPathComponent(file), lang: pub.lang)

        var texts: [(node: DocNode, icon: String?, color: String?, anchor: String?)] = []
        func walk(_ n: DocNode, icon: String?, color: String?, anchor: String?) {
            let icon = n.style.icon ?? icon
            let color = n.style.iconBackground ?? n.style.color ?? color
            let anchor = n.elementID ?? n.anchors.first ?? anchor
            if n.kind == .text {
                texts.append((n, icon, n.style.color ?? color, anchor))
            }
            for c in n.children { walk(c, icon: icon, color: color, anchor: anchor) }
        }
        for n in doc.nodes { walk(n, icon: nil, color: nil, anchor: nil) }

        var sections: [MeetingSection] = []
        var lastPart: Int?
        for (i, t) in texts.enumerated() {
            let text = t.node.plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch t.node.role {
            case .h1:
                if week.dates.isEmpty { week.dates = text }
            case .h2:
                if week.bibleReading == nil, sections.isEmpty, t.icon == nil {
                    week.bibleReading = text
                } else {
                    sections.append(MeetingSection(id: i, title: text, color: t.color, icon: t.icon, parts: []))
                }
            case .h3:
                let href = t.anchor.map { file + "#" + $0 } ?? file
                if sections.isEmpty {
                    sections.append(MeetingSection(id: -1, title: "", color: nil, icon: nil, parts: []))
                }
                sections[sections.count - 1].parts.append(MeetingPart(id: i, title: text, detail: nil, href: href))
                lastPart = i
            default:
                // The first line under a part ("(10 min.) Talk.") becomes its detail.
                if let lp = lastPart, var section = sections.last, let idx = section.parts.lastIndex(where: { $0.id == lp }),
                   section.parts[idx].detail == nil {
                    let p = section.parts[idx]
                    let short = text.count > 140 ? String(text.prefix(140)) + "…" : text
                    section.parts[idx] = MeetingPart(id: p.id, title: p.title, detail: short, href: p.href)
                    sections[sections.count - 1] = section
                    lastPart = nil
                }
            }
        }
        week.sections = sections.filter { !$0.parts.isEmpty || !$0.title.isEmpty }
        if week.dates.isEmpty { week.dates = match.label }
        return week
    }

    static func weekend(pub: InstalledPub, match: WeekFinder.Match, root: URL) -> WeekendWeek {
        var week = WeekendWeek(pub: pub, match: match, title: match.label)
        let file = match.href.components(separatedBy: "#")[0]
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { return week }
        let doc = DocParser.parse(data: data, path: file)
        if !doc.title.isEmpty { week.title = doc.title }
        for top in doc.nodes {
            top.walk { n in
                if week.image == nil, n.kind == .image, let img = n.image { week.image = img }
                if week.theme == nil, n.kind == .text, n.has("themeScrp") || n.hasPrefix("themeScrp") {
                    week.theme = n.plain
                }
            }
        }
        if week.theme == nil {
            for top in doc.nodes {
                var t: String?
                top.walk { n in
                    if t == nil, n.kind == .text, n.role == .paragraph, n.plain.contains(":"), n.plain.count < 200,
                       n.plain.hasPrefix("“") || n.plain.hasPrefix("\"") || n.plain.hasPrefix("«") {
                        t = n.plain
                    }
                }
                if let t {
                    week.theme = t
                    break
                }
            }
        }
        return week
    }
}

// MARK: - Model

@MainActor
final class MeetingsModel: ObservableObject {
    @Published var weekOffset = 0
    @Published var midweek: MidweekWeek?
    @Published var weekend: WeekendWeek?
    @Published var midweekNote: String?
    @Published var weekendNote: String?
    @Published var loading = false
    private var loadedKey = ""

    var weekStart: Date {
        let today = Issues.weekStart(Date())
        return Issues.calendar.date(byAdding: .day, value: 7 * weekOffset, to: today) ?? today
    }

    func refresh(force: Bool = false) async {
        let library = LibraryStore.shared
        let lang = Prefs.langCode
        let week = weekStart
        let key = "\(lang)|\(week.timeIntervalSince1970)"
        guard force || key != loadedKey else { return }
        loadedKey = key
        loading = true
        defer { if loadedKey == key { loading = false } }
        midweek = nil
        weekend = nil

        // Midweek meeting: the workbook issue that holds this week's Monday (or Sunday).
        midweekNote = "Getting the workbook…"
        let sunday = Issues.calendar.date(byAdding: .day, value: 6, to: week) ?? week
        var issues = [Issues.workbook(for: week)]
        if Issues.workbook(for: sunday) != issues[0] { issues.append(Issues.workbook(for: sunday)) }
        var lastError: String?
        for issue in issues {
            do {
                let pub = try await library.ensure(symbol: "mwb", issue: issue, lang: lang)
                let folder = library.folder(pub)
                let found = await Task.detached { () -> MidweekWeek? in
                    guard let m = WeekFinder.find(in: pub, week: week, root: folder) else { return nil }
                    return MeetingReader.midweek(pub: pub, match: m, root: folder)
                }.value
                guard loadedKey == key else { return }
                if let found {
                    JWIcons.shared.prepare(root: folder, pubID: pub.id)
                    midweek = found
                    break
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard loadedKey == key else { return }
        midweekNote = midweek == nil ? (lastError ?? "This week isn't in the workbook.") : nil

        // Weekend meeting: Watchtower study issues come out about two months ahead.
        weekendNote = "Getting the Watchtower…"
        lastError = nil
        for offset in [-2, -3, -1, -4] {
            let issue = Issues.watchtower(for: week, offset: offset)
            do {
                let pub = try await library.ensure(symbol: "w", issue: issue, lang: lang)
                let folder = library.folder(pub)
                let found = await Task.detached { () -> WeekendWeek? in
                    guard let m = WeekFinder.find(in: pub, week: week, root: folder) else { return nil }
                    return MeetingReader.weekend(pub: pub, match: m, root: folder)
                }.value
                guard loadedKey == key else { return }
                if let found {
                    weekend = found
                    break
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard loadedKey == key else { return }
        weekendNote = weekend == nil ? (lastError ?? "This week's study article wasn't found.") : nil
    }
}

// MARK: - Views

enum MeetingKind: String, CaseIterable, Identifiable {
    case midweek, weekend
    var id: String { rawValue }
    var label: String { self == .midweek ? "Midweek" : "Weekend" }
}

/// Like JW Library's Meetings tab: pick a week, then see that week's parts and open any of them.
/// Folded: a Midweek / Weekend switch. Unfolded: both meetings side by side, split at the hinge.
struct MeetingsView: View {
    @StateObject private var model = MeetingsModel()
    @AppStorage(Prefs.Key.lang) private var lang = "E"
    @AppStorage("meetingKind") private var kind: MeetingKind = .midweek
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 0) {
                        List { MidweekContent(model: model) }
                            .frame(width: geo.size.width / 2)
                        Divider()
                        List { WeekendContent(model: model) }
                            .frame(width: geo.size.width / 2 - 1)
                    }
                    .listStyle(.insetGrouped)
                }
                .safeAreaInset(edge: .top) { weekBar.padding(.bottom, 4) }
            } else {
                List {
                    switch kind {
                    case .midweek: MidweekContent(model: model)
                    case .weekend: WeekendContent(model: model)
                    }
                }
                .listStyle(.insetGrouped)
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 10) {
                        weekBar
                        Picker("Meeting", selection: $kind) {
                            ForEach(MeetingKind.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 8)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Meetings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LanguageMenu() }
            ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
        }
        .refreshable { await model.refresh(force: true) }
        .task(id: "\(lang)|\(model.weekOffset)") { await model.refresh() }
    }

    /// ‹ This week · Nov 2–8 ›
    private var weekBar: some View {
        HStack(spacing: 8) {
            Button {
                model.weekOffset -= 1
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous week")
            Spacer(minLength: 0)
            Button {
                model.weekOffset = 0
            } label: {
                VStack(spacing: 1) {
                    Text(weekTitle).font(.headline)
                    Text(weekRange).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Go to this week")
            Spacer(minLength: 0)
            Button {
                model.weekOffset += 1
            } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next week")
        }
        .padding(.horizontal, 8)
    }

    private var weekTitle: String {
        switch model.weekOffset {
        case 0: return "This week"
        case 1: return "Next week"
        case -1: return "Last week"
        default: return model.weekOffset > 0 ? "In \(model.weekOffset) weeks" : "\(-model.weekOffset) weeks ago"
        }
    }

    private var weekRange: String {
        let start = model.weekStart
        let end = Issues.calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

private struct StatusRow: View {
    let note: String?
    let loading: Bool

    var body: some View {
        HStack(spacing: 12) {
            if loading { ProgressView() }
            Text(note ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

struct MidweekContent: View {
    @ObservedObject var model: MeetingsModel

    var body: some View {
        if let week = model.midweek {
            Section {
                NavigationLink(value: ReaderRoute(pubID: week.pub.id, href: week.match.href)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Life and Ministry Meeting")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Text(week.dates).font(.title3.weight(.bold))
                        if let reading = week.bibleReading {
                            Label(reading, systemImage: "book")
                                .font(.subheadline)
                                .foregroundStyle(JWColor.link)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            ForEach(week.sections) { section in
                Section {
                    ForEach(section.parts) { part in
                        NavigationLink(value: ReaderRoute(pubID: week.pub.id, href: part.href)) {
                            PartRow(part: part, color: section.color)
                        }
                    }
                    if isLiving(section), let study = week.bibleStudy {
                        NavigationLink(value: study) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open the Bible study lesson").font(.subheadline.weight(.semibold))
                                    Text(study.label).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "book.pages")
                            }
                        }
                    }
                } header: {
                    if !section.title.isEmpty {
                        SectionHeader(title: section.title, color: section.color, icon: section.icon,
                                      pubID: week.pub.id)
                    }
                }
            }

            if !week.sections.contains(where: isLiving), let study = week.bibleStudy {
                Section("Congregation Bible Study") {
                    NavigationLink(value: study) {
                        Label(study.label, systemImage: "book.pages")
                    }
                }
            }

            Section {
                NavigationLink(value: PubRoute(pubID: week.pub.id)) {
                    Label("All weeks in this workbook", systemImage: "calendar")
                }
            }
        } else {
            Section("Midweek meeting") {
                StatusRow(note: model.midweekNote, loading: model.loading)
            }
        }
    }

    /// The last section (Living as Christians) holds the Bible study.
    private func isLiving(_ section: MeetingSection) -> Bool {
        section.id == model.midweek?.sections.last?.id && section.icon != nil
    }
}

struct WeekendContent: View {
    @ObservedObject var model: MeetingsModel
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        if let week = model.weekend {
            Section {
                NavigationLink(value: ReaderRoute(pubID: week.pub.id, href: week.match.href)) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let image = week.image {
                            PageImage(path: image, root: library.folder(week.pub), alt: "")
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        Text("Watchtower Study")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Text(week.title)
                            .font(.title3.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let theme = week.theme {
                            Text(theme)
                                .font(.subheadline)
                                .italic()
                                .foregroundStyle(.secondary)
                        }
                        Text(week.pub.title)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
            }
            Section {
                NavigationLink(value: PubRoute(pubID: week.pub.id)) {
                    Label("All articles in this issue", systemImage: "list.bullet.rectangle")
                }
            }
        } else {
            Section("Weekend meeting") {
                StatusRow(note: model.weekendNote, loading: model.loading)
            }
        }
    }
}

private struct PartRow: View {
    let part: MeetingPart
    let color: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(part.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(color.flatMap(JWColor.color) ?? JWColor.text)
            if let detail = part.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The colored band with the section's icon (gem, wheat, sheep), like the workbook.
private struct SectionHeader: View {
    let title: String
    let color: String?
    let icon: String?
    let pubID: String

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                IconTile(icon: icon, pubID: pubID, size: 26, background: color, color: nil)
            }
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color.flatMap(JWColor.color) ?? .secondary)
                .textCase(nil)
        }
        .padding(.vertical, 4)
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
            Image(systemName: "globe")
        }
        .accessibilityLabel("Publication language: \(PubLanguage.find(lang).native)")
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
