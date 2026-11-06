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

/// The reading screen: the page drawn natively from the publication, with answers typed straight
/// into its answer boxes. Two buttons: Contents, and Aa for text size, side margins and font.
/// Verses, footnotes and research open in a sheet; a whole lesson or chapter opens as a page.
struct ReaderScreen: View {
    let href: String?
    let find: String?
    @StateObject private var reader: ReaderModel
    @AppStorage(Prefs.Key.textScale) private var textScale = 1.0
    @AppStorage(Prefs.Key.serif) private var serif = false
    @AppStorage(Prefs.Key.margin) private var margin = Prefs.defaultMargin
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 17.5
    @State private var showContents = false
    @State private var showText = false
    @State private var zoomImage: ZoomItem?

    init(pub: InstalledPub, href: String?, find: String? = nil) {
        self.href = href
        self.find = find
        _reader = StateObject(wrappedValue: ReaderModel(pub: pub))
    }

    private var base: CGFloat { baseSize * textScale }

    var body: some View {
        GeometryReader { geo in
            page(width: geo.size.width)
        }
        .navigationTitle(reader.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .environment(\.openURL, OpenURLAction { url in reader.handleLink(url) })
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
    }

    // MARK: Page

    @ViewBuilder
    private func page(width: CGFloat) -> some View {
        // The side margin is yours to set (Aa). Text uses the rest of the width.
        let side = max(6, min(CGFloat(margin), width * 0.3))
        let column = max(200, width - side * 2)
        let env = PageEnv(base: base, serif: serif || reader.isBible, bible: reader.isBible, pubID: reader.pub.id,
                          bleed: side, findTerm: reader.findTerm, doc: reader.currentFile)
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
                    if !nodes.isEmpty, reader.hasPrevious || reader.hasNext {
                        footer.padding(.top, 40)
                    }
                }
                .frame(width: column, alignment: .leading)
                .padding(.top, 14)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .id(reader.currentFile)
            .overlay {
                if reader.loading && reader.doc.nodes.isEmpty {
                    ProgressView()
                } else if reader.loadFailed && reader.doc.nodes.isEmpty {
                    ContentUnavailableView("This page couldn't be opened", systemImage: "exclamationmark.triangle",
                                           description: Text("Delete the publication in Library and download it again."))
                }
            }
            .onChange(of: reader.scrollRequest) { _, request in
                guard let request else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(request.node, anchor: .top) }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(swipe)
        }
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
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showContents = true
            } label: {
                Image(systemName: reader.isBible ? "square.grid.3x3" : "list.bullet")
            }
            .accessibilityLabel(reader.isBible ? "Books and chapters" : "Contents")

            Button {
                showText = true
            } label: {
                Image(systemName: "textformat.size")
            }
            .accessibilityLabel("Text and margins")
            .popover(isPresented: $showText) {
                TextSettings(showSerif: !reader.isBible)
                    .presentationCompactAdaptation(.popover)
            }

            if !reader.questions.isEmpty {
                Menu {
                    Button("Copy questions and answers", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = reader.exportText
                    }
                    ShareLink(item: reader.exportText) {
                        Label("Share questions and answers", systemImage: "square.and.arrow.up")
                    }
                    Button("Print questions and answers", systemImage: "printer") {
                        Printer.present(title: reader.title, items: reader.exportItems)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Answers")
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }
}

/// Text size, side margins and font, shared by the reader's Aa button and Settings.
struct TextSettings: View {
    var showSerif = true
    @AppStorage(Prefs.Key.textScale) private var textScale = 1.0
    @AppStorage(Prefs.Key.serif) private var serif = false
    @AppStorage(Prefs.Key.margin) private var margin = Prefs.defaultMargin

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Text size")
                    Spacer()
                    Text("\(Int((textScale * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller")
                    Slider(value: $textScale, in: 0.75...1.8, step: 0.05)
                    Image(systemName: "textformat.size.larger")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Side margins")
                    Spacer()
                    Text("\(Int(margin)) pt").foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 12) {
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                    Slider(value: $margin, in: 6...120, step: 2)
                    Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                }
            }
            if showSerif {
                Toggle("Serif font", isOn: $serif)
            }
        }
        .padding(20)
        .frame(minWidth: 300, idealWidth: 340)
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

/// Sheets for references (verses, footnotes, research), videos and web pages.
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
    }
}
