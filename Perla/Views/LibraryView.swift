import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showDownloads = false
    @State private var confirmDelete: InstalledPub?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            if library.pubs.isEmpty {
                ContentUnavailableView {
                    Label("Nothing downloaded yet", systemImage: "books.vertical")
                } description: {
                    Text("Download books, workbooks and Watchtower issues to read them offline.")
                } actions: {
                    Button("Get publications") { showDownloads = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(library.pubs) { pub in
                        NavigationLink(value: PubRoute(pubID: pub.id)) {
                            PubTile(pub: pub, image: library.coverImage(pub))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove download", systemImage: "trash", role: .destructive) {
                                confirmDelete = pub
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LanguageMenu() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showDownloads = true
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .accessibilityLabel("Get publications")
                SettingsButton()
            }
        }
        .sheet(isPresented: $showDownloads) { DownloadSheet() }
        .confirmationDialog("Remove this download?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { pub in
            Button("Remove \(pub.title)", role: .destructive) { library.delete(pub) }
        }
    }
}

struct PubTile: View {
    let pub: InstalledPub
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(pub.symbol.uppercased())
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            Text(pub.title)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            Text(pub.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct DownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(Prefs.Key.lang) private var lang = "E"
    @State private var symbol = ""
    @State private var issue = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Language") { LanguageMenu() }
                } footer: {
                    Text("Downloads come from jw.org as EPUB files and are read offline.")
                }

                Section("Meeting workbooks") {
                    ForEach(workbookIssues, id: \.self) { iss in
                        DownloadRow(symbol: "mwb", issue: iss, lang: lang,
                                    title: "Workbook · \(Issues.label(symbol: "mwb", issue: iss))", error: $error)
                    }
                }

                Section("Watchtower (study)") {
                    ForEach(watchtowerIssues, id: \.self) { iss in
                        DownloadRow(symbol: "w", issue: iss, lang: lang,
                                    title: "Watchtower · \(Issues.label(symbol: "w", issue: iss))", error: $error)
                    }
                }

                Section("Books and the Bible") {
                    ForEach(CatalogItem.books) { item in
                        DownloadRow(symbol: item.symbol, issue: "", lang: lang, title: item.title, error: $error)
                    }
                }

                Section {
                    TextField("Symbol (for example lff)", text: $symbol)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Issue (optional, for example 202609)", text: $issue)
                        .keyboardType(.numberPad)
                    let sym = symbol.trimmingCharacters(in: .whitespaces).lowercased()
                    if !sym.isEmpty {
                        DownloadRow(symbol: sym, issue: issue.trimmingCharacters(in: .whitespaces), lang: lang,
                                    title: sym.uppercased(), error: $error)
                    }
                } header: {
                    Text("Other publication")
                } footer: {
                    Text("Use the symbol jw.org gives a publication.")
                }
            }
            .navigationTitle("Get publications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Download failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var workbookIssues: [String] {
        let now = Date()
        let cal = Issues.calendar
        return [-2, 0, 2].compactMap { cal.date(byAdding: .month, value: $0, to: now) }
            .map { Issues.workbook(for: $0) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private var watchtowerIssues: [String] {
        (-4...0).map { Issues.watchtower(for: Date(), offset: $0) }.reversed()
    }
}

struct DownloadRow: View {
    @EnvironmentObject private var library: LibraryStore
    let symbol: String
    let issue: String
    let lang: String
    let title: String
    @Binding var error: String?

    init(symbol: String, issue: String, lang: String, title: String, error: Binding<String?>) {
        self.symbol = symbol
        self.issue = issue
        self.lang = lang
        self.title = title
        _error = error
    }

    var body: some View {
        let installed = library.installed(symbol: symbol, issue: issue, lang: lang)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(installed?.title ?? title)
                if installed != nil {
                    Text("Downloaded").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if installed != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if library.isDownloading(symbol: symbol, issue: issue, lang: lang) {
                ProgressView()
            } else {
                Button {
                    Task {
                        do {
                            try await library.ensure(symbol: symbol, issue: issue, lang: lang)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download")
            }
        }
    }
}
