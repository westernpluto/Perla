import SwiftUI

/// jw.org's video catalog (the same categories JW Library shows under Video): categories hold either
/// more categories or a list of videos.
enum VideoCatalog {
    struct Category: Identifiable, Hashable {
        let key: String
        let name: String
        let image: URL?
        var id: String { key }
    }

    struct Video: Identifiable, Hashable {
        let key: String
        let title: String
        let duration: String
        let image: URL?
        /// Every resolution, straight from the catalog.
        let files: [MediaFile]
        var id: String { key }
    }

    struct Page {
        var subcategories: [Category] = []
        var videos: [Video] = []
    }

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { L("The videos couldn't be loaded. Check the connection and try again.") }
    }

    private static func image(_ images: [String: Any]?) -> URL? {
        for kind in ["lsr", "wss", "sqr", "pnr", "lss"] {
            guard let sizes = images?[kind] as? [String: String] else { continue }
            for size in ["md", "lg", "sm", "xl"] {
                if let s = sizes[size], let u = URL(string: s) { return u }
            }
        }
        return nil
    }

    static func load(key: String, lang: String) async throws -> Page {
        guard let url = URL(string: "https://b.jw-cdn.org/apis/mediator/v1/categories/\(lang)/\(key)?detailed=1&clientType=www")
        else { throw Failure.unavailable }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let category = obj["category"] as? [String: Any] else { throw Failure.unavailable }
        var page = Page()
        for sub in category["subcategories"] as? [[String: Any]] ?? [] {
            guard let k = sub["key"] as? String, let name = sub["name"] as? String else { continue }
            page.subcategories.append(Category(key: k, name: name, image: image(sub["images"] as? [String: Any])))
        }
        for m in category["media"] as? [[String: Any]] ?? [] {
            // The media service wants the language-free key ("pub-ljf_11_VIDEO").
            guard let k = (m["languageAgnosticNaturalKey"] as? String) ?? (m["naturalKey"] as? String),
                  let title = m["title"] as? String else { continue }
            page.videos.append(Video(key: k, title: title, duration: m["durationFormattedMinSec"] as? String ?? "",
                                     image: image(m["images"] as? [String: Any]),
                                     files: MediaResolver.files(fromMediator: m["files"] as? [[String: Any]] ?? [])))
        }
        return page
    }
}

/// One level of the video catalog.
struct VideoCategoryView: View {
    let key: String
    let title: String
    @AppStorage(Prefs.Key.lang) private var lang = "E"
    @State private var page: VideoCatalog.Page?
    @State private var error: String?
    @State private var playing: MediaItem?
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        Group {
            if let page {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if !page.subcategories.isEmpty {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(page.subcategories) { c in
                                    NavigationLink(value: LibrarySection.videos(key: c.key, title: c.name)) {
                                        VideoTile(title: c.name, detail: nil, image: c.image, isCategory: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if !page.videos.isEmpty {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(page.videos) { v in
                                    Button {
                                        playing = MediaItem(source: v.files.isEmpty ? .key(v.key) : .files(v.files),
                                                            lang: lang, title: v.title)
                                    } label: {
                                        VideoTile(title: v.title, detail: v.duration, image: v.image, isCategory: false)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .scenePadding(.horizontal)
                    .padding(.vertical, 16)
                }
            } else if let error {
                ContentUnavailableView {
                    Label("No videos", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: lang) { await load() }
        .fullScreenCover(item: $playing) { MediaPlayerScreen(item: $0) }
    }

    private func load() async {
        error = nil
        do {
            page = try await VideoCatalog.load(key: key, lang: lang)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct VideoTile: View {
    let title: String
    let detail: String?
    let image: URL?
    let isCategory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: image) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: isCategory ? "rectangle.stack" : "play.rectangle")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            Text(title)
                .font(.footnote.weight(isCategory ? .semibold : .regular))
                .lineLimit(2)
        }
    }
}
