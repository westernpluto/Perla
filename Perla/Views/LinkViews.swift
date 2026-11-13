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
                if let fraction = library.progress(symbol: ref.isBible ? "nwt" : ref.symbol, issue: ref.issue, lang: ref.lang) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
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

/// Plays a jw.org video or song right here. The resolution menu streams another size; the download
/// menu keeps a copy on the iPhone to watch offline.
struct MediaPlayerScreen: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VideoStore.shared
    @State private var player: AVPlayer?
    @State private var files: [MediaFile] = []
    @State private var playing: MediaFile?
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                }
                if !files.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        qualityMenu
                        downloadMenu
                    }
                }
            }
        }
        .task {
            do {
                files = try await MediaResolver.files(item)
                // A downloaded copy plays first; otherwise stream at 720p (or the nearest below).
                let start = files.first { store.localURL(for: $0) != nil } ?? MediaResolver.preferred(files)
                if let start { play(start) }
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { player?.pause() }
    }

    private func play(_ file: MediaFile) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let time = player?.currentTime()
        let p = AVPlayer(url: store.localURL(for: file) ?? file.url)
        if let time, time.seconds > 0 { p.seek(to: time) }
        player?.pause()
        player = p
        playing = file
        p.play()
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(files.filter { !$0.isAudio }) { f in
                Button {
                    play(f)
                } label: {
                    if f == playing { Label(f.label, systemImage: "checkmark") } else { Text(f.label) }
                }
            }
        } label: {
            Image(systemName: "dial.medium")
        }
        .accessibilityLabel("Resolution")
    }

    private var downloadMenu: some View {
        Menu {
            ForEach(files) { f in
                if store.localURL(for: f) != nil {
                    Button("Remove \(f.label) download", systemImage: "trash", role: .destructive) { store.remove(f) }
                } else {
                    Button {
                        Task { await store.download(f, title: item.title) }
                    } label: {
                        Text("Download \(f.label)") + Text(f.size > 0 ? " · " + ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file) : "")
                    }
                }
            }
        } label: {
            if let fraction = files.compactMap({ store.progress[$0.url] }).first {
                ProgressView(value: fraction).progressViewStyle(.circular)
            } else if files.contains(where: { store.localURL(for: $0) != nil }) {
                Image(systemName: "checkmark.circle.fill")
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
        .accessibilityLabel("Download")
    }
}

/// Videos kept on the iPhone to watch offline.
@MainActor
final class VideoStore: ObservableObject {
    static let shared = VideoStore()

    /// Remote file name → saved file name, with titles for listing.
    @Published private(set) var saved: [String: String] = [:]
    @Published private(set) var progress: [URL: Double] = [:]
    private let folder: URL
    private let indexURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        indexURL = folder.appendingPathComponent("videos.json")
        if let data = try? Data(contentsOf: indexURL), let s = try? JSONDecoder().decode([String: String].self, from: data) {
            saved = s
        }
    }

    func localURL(for file: MediaFile) -> URL? {
        let name = file.url.lastPathComponent
        guard saved[name] != nil else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ file: MediaFile, title: String) async {
        progress[file.url] = 0
        defer { progress[file.url] = nil }
        guard let tmp = try? await Downloader.shared.download(file.url, progress: { fraction in
            Task { @MainActor in VideoStore.shared.progress[file.url] = fraction }
        }) else { return }
        let dest = folder.appendingPathComponent(file.url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return }
        saved[file.url.lastPathComponent] = title
        save()
    }

    func remove(_ file: MediaFile) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file.url.lastPathComponent))
        saved[file.url.lastPathComponent] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: indexURL, options: .atomic) }
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
