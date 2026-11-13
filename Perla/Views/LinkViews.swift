import SwiftUI
import AVKit
import SafariServices

/// Opens a lesson, chapter, article or Bible chapter from another publication. If the publication
/// isn't on the phone yet, it asks first, like JW Library's download card.
struct PubRefDestination: View {
    let ref: PubRef
    @EnvironmentObject private var library: LibraryStore
    @State private var target: PubResolver.Target?
    @State private var error: String?
    @State private var confirmed = false
    @State private var working = false

    var body: some View {
        Group {
            switch target {
            case .some(.reader(let route)):
                ReaderDestination(route: route)
            case .some(.contents(let route)):
                PubDestination(route: route)
            case .none:
                placeholder
                    .navigationTitle(ref.displayTitle)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear {
            if !needsDownload { start() }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error {
            ContentUnavailableView {
                Label("Couldn't open \(ref.displayTitle)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { start() }
                    .buttonStyle(.borderedProminent)
            }
        } else if needsDownload && !confirmed {
            downloadCard
        } else {
            VStack(spacing: 14) {
                ProgressView()
                Text(needsDownload ? L("Downloading %@…", ref.displayTitle) : L("Opening %@…", ref.displayTitle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var needsDownload: Bool {
        if ref.isBible { return library.installed(symbol: "nwt", issue: "", lang: ref.lang) == nil }
        if ref.symbol.isEmpty { return false }
        return library.installed(symbol: ref.symbol, issue: ref.issue, lang: ref.lang) == nil
    }

    private var downloadCard: some View {
        VStack(spacing: 18) {
            Image(systemName: ref.isBible ? "book.closed" : "books.vertical")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text(ref.displayTitle)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if !ref.label.isEmpty, ref.label != ref.displayTitle {
                    Text(ref.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text("This publication isn't downloaded yet. Download it from jw.org to read it here, even offline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                confirmed = true
                start()
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(PubLanguage.find(ref.lang).native)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func start() {
        guard !working else { return }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                target = try await PubResolver.resolve(ref)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension PubRef {
    /// The button that opens the full publication: "Open in Bible", "Open in The Watchtower · Oct 2017".
    var openTitle: String {
        if isBible { return L("Open in Bible") }
        if CatalogItem.books.contains(where: { $0.symbol == symbol }) || ["w", "wp", "g", "mwb"].contains(symbol) {
            return L("Open in %@", displayTitle)
        }
        return L("Open in publication")
    }

    /// The publication's name, for titles and the download card.
    var displayTitle: String {
        if isBible { return label.isEmpty ? L("Bible") : label }
        if let item = CatalogItem.books.first(where: { $0.symbol == symbol }) { return item.localizedTitle(lang: lang) }
        switch symbol {
        case "w": return issue.isEmpty ? L("The Watchtower") : L("The Watchtower") + " · " + Issues.label(symbol: "w", issue: issue)
        case "wp": return issue.isEmpty ? L("The Watchtower") : L("The Watchtower") + " · " + Issues.label(symbol: "wp", issue: issue)
        case "g": return issue.isEmpty ? L("Awake!") : L("Awake!") + " · " + Issues.label(symbol: "g", issue: issue)
        case "mwb": return issue.isEmpty ? L("Meeting Workbooks") : L("Workbook") + " · " + Issues.label(symbol: "mwb", issue: issue)
        default: return label.isEmpty ? symbol.uppercased() : label
        }
    }
}

/// Plays a jw.org video or song right here, instead of sending you to the website or another app.
struct MediaPlayerScreen: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if let error {
                    ContentUnavailableView("Can't play this", systemImage: "play.slash", description: Text(error))
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .task {
            do {
                let url = try await MediaResolver.resolve(item)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                let p = AVPlayer(url: url)
                player = p
                p.play()
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// A web page inside the app.
struct InAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
