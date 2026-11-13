import Foundation
import UIKit
import ZIPFoundation

struct InstalledPub: Codable, Hashable, Identifiable {
    var id: String
    var symbol: String
    var issue: String
    var lang: String
    var title: String
    var cover: String?
    var spine: [String]
    var toc: [TOCEntry]
    var added: Date

    var isBible: Bool { symbol.hasPrefix("nwt") }
    var isMeetingPub: Bool { symbol == "mwb" || symbol == "w" }
    var subtitle: String {
        let l = PubLanguage.find(lang).name
        return issue.isEmpty ? l : "\(Issues.label(symbol: symbol, issue: issue)) · \(l)"
    }

    static func makeID(symbol: String, issue: String, lang: String) -> String {
        [lang, symbol, issue].filter { !$0.isEmpty }.joined(separator: "_")
    }

    /// First chapter worth opening (skips cover pages when the contents list says where to start).
    var startHref: String { toc.first?.href ?? spine.first ?? "" }
}

/// Downloaded publications: fetching, unpacking, listing and removing them.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var pubs: [InstalledPub] = []
    /// IDs being downloaded right now.
    @Published private(set) var downloading: Set<String> = []
    @Published var lastError: String?

    let root: URL
    private let indexURL: URL
    private var inflight: [String: Task<InstalledPub, Error>] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Publications", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        indexURL = root.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([InstalledPub].self, from: data) {
            pubs = saved.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.id).path) }
        }
    }

    func folder(_ pub: InstalledPub) -> URL { root.appendingPathComponent(pub.id, isDirectory: true) }

    func installed(symbol: String, issue: String, lang: String) -> InstalledPub? {
        let id = InstalledPub.makeID(symbol: symbol, issue: issue, lang: lang)
        return pubs.first { $0.id == id }
    }

    func isDownloading(symbol: String, issue: String, lang: String) -> Bool {
        downloading.contains(InstalledPub.makeID(symbol: symbol, issue: issue, lang: lang))
    }

    func coverImage(_ pub: InstalledPub) -> UIImage? {
        guard let c = pub.cover else { return nil }
        return UIImage(contentsOfFile: folder(pub).appendingPathComponent(c).path)
    }

    /// Returns the publication, downloading it first if needed.
    @discardableResult
    func ensure(symbol: String, issue: String = "", lang: String) async throws -> InstalledPub {
        if let p = installed(symbol: symbol, issue: issue, lang: lang) { return p }
        let id = InstalledPub.makeID(symbol: symbol, issue: issue, lang: lang)
        if let running = inflight[id] { return try await running.value }

        let task = Task<InstalledPub, Error> {
            let link = try await PubMedia.epubLink(symbol: symbol, issue: issue, lang: lang)
            let (tmp, response) = try await URLSession.shared.download(from: link.url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                throw PubMedia.Failure.network(L("The download didn't finish. Try again."))
            }
            return try await Self.install(file: tmp, id: id, symbol: symbol, issue: issue, lang: lang,
                                          fallbackTitle: link.title, into: self.root)
        }
        inflight[id] = task
        downloading.insert(id)
        defer {
            inflight[id] = nil
            downloading.remove(id)
        }
        do {
            let pub = try await task.value
            pubs.removeAll { $0.id == pub.id }
            pubs.append(pub)
            sortPubs()
            save()
            return pub
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func delete(_ pub: InstalledPub) {
        try? FileManager.default.removeItem(at: folder(pub))
        pubs.removeAll { $0.id == pub.id }
        save()
        SearchIndex.shared.forget(pub.id)
    }

    private func sortPubs() {
        pubs.sort { a, b in
            if a.isMeetingPub != b.isMeetingPub { return !a.isMeetingPub }
            if a.issue != b.issue { return a.issue > b.issue }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pubs) { try? data.write(to: indexURL, options: .atomic) }
    }

    /// Unzips and reads the EPUB off the main thread.
    nonisolated private static func install(file: URL, id: String, symbol: String, issue: String, lang: String,
                                            fallbackTitle: String, into root: URL) async throws -> InstalledPub {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dest = root.appendingPathComponent(id, isDirectory: true)
            let staging = root.appendingPathComponent(id + ".partial", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                try fm.unzipItem(at: file, to: staging)
            } catch {
                try? fm.removeItem(at: staging)
                throw EPUBError.unreadable("unzip failed")
            }
            try? fm.removeItem(at: file)

            let parsed: ParsedEPUB
            do {
                parsed = try EPUBParser.parse(folder: staging)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            SearchIndex.build(pubID: id, folder: staging, spine: parsed.spine, toc: parsed.toc)

            try? fm.removeItem(at: dest)
            try fm.moveItem(at: staging, to: dest)
            return InstalledPub(id: id, symbol: symbol, issue: issue, lang: lang,
                                title: parsed.title.isEmpty ? fallbackTitle : parsed.title,
                                cover: parsed.cover, spine: parsed.spine, toc: parsed.toc, added: Date())
        }.value
    }
}
