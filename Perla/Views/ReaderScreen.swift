import SwiftUI

struct ReaderRoute: Hashable {
    let pubID: String
    var href: String?
    var find: String?
}

/// Looks up the publication for a route and opens it.
struct ReaderDestination: View {
    @EnvironmentObject private var library: LibraryStore
    let route: ReaderRoute

    var body: some View {
        if let pub = library.pubs.first(where: { $0.id == route.pubID }) {
            ReaderScreen(pub: pub, href: route.href, find: route.find)
        } else {
            ContentUnavailableView("Publication not found", systemImage: "book.closed",
                                   description: Text("It may have been removed. Download it again from Library."))
        }
    }
}

/// The reading screen: the document drawn natively from the publication's own structure,
/// with answers written into the answer boxes. Unfolded, an answers column sits beside the page.
struct ReaderScreen: View {
    let href: String?
    let find: String?
    @StateObject private var reader: ReaderModel
    @AppStorage(Prefs.Key.panel) private var panelVisible = true
    @AppStorage(Prefs.Key.textScale) private var textScale = 1.0
    @AppStorage(Prefs.Key.serif) private var serif = false
    @AppStorage(Prefs.Key.highlight) private var highlight = true
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 17.5
    @State private var wide = false
    @State private var showAnswers = false
    @State private var showContents = false
    @State private var zoomImage: ZoomItem?

    init(pub: InstalledPub, href: String?, find: String? = nil) {
        self.href = href
        self.find = find
        _reader = StateObject(wrappedValue: ReaderModel(pub: pub))
    }

    private var base: CGFloat { baseSize * textScale }

    var body: some View {
        GeometryReader { geo in
            let isWide = geo.size.width >= 700
            let panel = isWide && panelVisible
            let panelWidth = max(320, min(420, geo.size.width * 0.36))
            HStack(spacing: 0) {
                page(width: panel ? geo.size.width - panelWidth - 1 : geo.size.width)
                if panel {
                    Divider().ignoresSafeArea(edges: .bottom)
                    AnswersPanel(reader: reader, inSheet: false)
                        .frame(width: panelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy, value: panel)
            .onAppear { wide = isWide }
            .onChange(of: isWide) { _, value in
                wide = value
                if value { showAnswers = false }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !(wide && panelVisible) { answersButton }
        }
        .navigationTitle(reader.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .environment(\.openURL, OpenURLAction { url in reader.handleLink(url) })
        .sheet(isPresented: $showAnswers) {
            AnswersPanel(reader: reader, inSheet: true)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                // While the answers sheet is up, verses and editors open on top of it.
                .modifier(ReaderSheets(reader: reader, base: base))
        }
        .sheet(isPresented: $showContents) { contentsSheet }
        .modifier(ReaderSheets(reader: reader, base: base))
        .fullScreenCover(item: $zoomImage) { item in
            ImageViewer(url: item.url)
        }
        .navigationDestination(item: $reader.pushRef) { ref in
            PubRefDestination(ref: ref)
        }
        .navigationDestination(item: $reader.pushRoute) { route in
            ReaderDestination(route: route)
        }
        .onChange(of: reader.showBibleContents) { _, show in
            guard show else { return }
            reader.showBibleContents = false
            showContents = true
        }
        .onAppear { reader.start(at: href, find: find) }
        .onChange(of: highlight) { _, _ in reader.refreshHighlights() }
        .onChange(of: reader.focusedID) { _, id in
            // "Show in answers list" from an answer box.
            guard id != nil else { return }
            if wide { panelVisible = true } else { showAnswers = true }
        }
    }

    // MARK: Page

    @ViewBuilder
    private func page(width: CGFloat) -> some View {
        let margin: CGFloat = width > 520 ? 28 : 20
        let column = max(240, min(width - margin * 2, 680))
        let side = max(margin, (width - column) / 2)
        let env = PageEnv(base: base, serif: serif || reader.isBible, bible: reader.isBible, pubID: reader.pub.id,
                          bleed: side, highlights: reader.highlights, findTerm: reader.findTerm,
                          doc: reader.currentFile)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let nodes = reader.doc.nodes
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { i, node in
                        NodeView(node: node, env: env, inherited: Inherited(), reader: reader, onImage: openImage)
                            .equatable()
                            .padding(.top, PageLayout.gap(prev: i > 0 ? nodes[i - 1] : nil, node: node, env: env))
                            .id(node.id)
                    }
                    if !reader.doc.footnoteNodes.isEmpty {
                        footnotes(env)
                    }
                    if !nodes.isEmpty {
                        footer.padding(.top, 40)
                    }
                }
                .frame(width: column, alignment: .leading)
                .padding(.top, 14)
                .padding(.bottom, 110)
                .frame(maxWidth: .infinity)
            }
            .id(reader.currentFile)
            .overlay {
                if reader.loading && reader.doc.nodes.isEmpty {
                    ProgressView()
                } else if reader.loadFailed && reader.doc.nodes.isEmpty {
                    ContentUnavailableView("This page couldn't be opened", systemImage: "exclamationmark.triangle",
                                           description: Text("The file may be missing. Delete the publication in Library and download it again."))
                }
            }
            .onChange(of: reader.scrollRequest) { _, request in
                guard let request else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(request.node, anchor: .top) }
            }
            .simultaneousGesture(swipe)
        }
    }

    private func openImage(_ path: String) {
        zoomImage = ZoomItem(url: reader.root.appendingPathComponent(path))
    }

    private func footnotes(_ env: PageEnv) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(JWColor.border)
                .frame(width: 64, height: 1)
                .padding(.bottom, 4)
            ForEach(reader.doc.footnoteNodes) { note in
                NodeView(node: note, env: env, inherited: Inherited(), reader: reader, onImage: openImage)
            }
        }
        .padding(.top, 36)
    }

    /// Previous and next chapter (or week, or article), like turning the page.
    private var footer: some View {
        HStack(spacing: 12) {
            if reader.hasPrevious {
                Button {
                    reader.previous()
                } label: {
                    Label(reader.previousTitle ?? "Previous", systemImage: "chevron.backward")
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if reader.hasNext {
                Button {
                    reader.next()
                } label: {
                    Label(reader.nextTitle ?? "Next", systemImage: "chevron.forward")
                        .labelStyle(TrailingIconLabelStyle())
                        .lineLimit(1)
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    /// Swipe sideways to turn to the previous or next chapter.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30, coordinateSpace: .local)
            .onEnded { v in
                let dx = v.translation.width
                let dy = v.translation.height
                guard abs(dx) > 110, abs(dx) > abs(dy) * 2.2, v.startLocation.x > 32 else { return }
                if dx < 0 {
                    if reader.hasNext { reader.next() }
                } else if reader.hasPrevious {
                    reader.previous()
                }
            }
    }

    private var answersButton: some View {
        Button {
            if wide { panelVisible = true } else { showAnswers = true }
        } label: {
            Image(systemName: "text.bubble")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .accessibilityLabel("Answers")
        .padding(.trailing, 18)
        .padding(.bottom, 16)
    }

    // MARK: Contents

    @ViewBuilder
    private var contentsSheet: some View {
        if let bible = reader.bible {
            BibleNavigator(pub: reader.pub, index: bible, current: reader.currentBook) { href in
                reader.open(href)
                showContents = false
            }
        } else {
            NavigationStack {
                ContentsList(pub: reader.pub, root: reader.root, current: reader.currentFile) { href in
                    reader.open(href)
                    showContents = false
                }
                .navigationTitle(reader.pub.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showContents = false } }
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(reader.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(reader.pub.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 420)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showContents = true
            } label: {
                Image(systemName: reader.isBible ? "square.grid.3x3" : "list.bullet")
            }
            .accessibilityLabel(reader.isBible ? "Books and chapters" : "Contents")

            if wide {
                Button {
                    panelVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .accessibilityLabel("Answers column")
            }

            Menu {
                Section("Text size") {
                    Button("Larger", systemImage: "textformat.size.larger") { textScale = min(1.8, textScale + 0.1) }
                    Button("Smaller", systemImage: "textformat.size.smaller") { textScale = max(0.75, textScale - 0.1) }
                    if textScale != 1 {
                        Button("Default size", systemImage: "arrow.uturn.backward") { textScale = 1 }
                    }
                    if !reader.isBible { Toggle("Serif font", isOn: $serif) }
                }
                if !reader.questions.isEmpty {
                    Section("Answers") {
                        Toggle("Highlight answers", isOn: $highlight)
                        Button("Copy questions and answers", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = reader.exportText
                        }
                        Button("Print questions and answers", systemImage: "printer") {
                            Printer.present(title: reader.title, items: reader.exportItems)
                        }
                    }
                }
                Section {
                    Button(reader.previousTitle ?? "Previous", systemImage: "chevron.backward") { reader.previous() }
                        .disabled(!reader.hasPrevious)
                    Button(reader.nextTitle ?? "Next", systemImage: "chevron.forward") { reader.next() }
                        .disabled(!reader.hasNext)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// Sheets for references (verses, footnotes, cited articles) and for writing an answer by hand.
/// Attached both to the page and to the answers sheet, so they can open from either.
struct ReaderSheets: ViewModifier {
    @ObservedObject var reader: ReaderModel
    let base: CGFloat

    init(reader: ReaderModel, base: CGFloat) {
        _reader = ObservedObject(wrappedValue: reader)
        self.base = base
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $reader.reference) { sheet in
                ReferenceView(sheet: sheet, reader: reader, base: base)
            }
            .fullScreenCover(item: $reader.media) { item in
                MediaPlayerScreen(item: item)
            }
            .sheet(item: $reader.web) { link in
                InAppBrowser(url: link.url).ignoresSafeArea()
            }
            .sheet(item: $reader.editing) { request in
                AnswerEditor(question: reader.questions.first { $0.id == request.id }?.text ?? "",
                             text: request.text) { text in
                    reader.saveEdit(request.id, text: text)
                }
            }
    }
}
