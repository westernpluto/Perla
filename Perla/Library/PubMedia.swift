import Foundation

/// jw.org's public download service — the same one behind the "Download" buttons on jw.org.
enum PubMedia {
    struct Link {
        let url: URL
        let title: String
    }

    enum Failure: LocalizedError {
        case notAvailable(String)
        case network(String)
        var errorDescription: String? {
            switch self {
            case .notAvailable(let what): return L("%@ isn't available to download in this language yet.", what)
            case .network(let m): return m
            }
        }
    }

    static func epubLink(symbol: String, issue: String, lang: String) async throws -> Link {
        var c = URLComponents(string: "https://b.jw-cdn.org/apis/pub-media/GETPUBMEDIALINKS")!
        var items = [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "pub", value: symbol),
            URLQueryItem(name: "fileformat", value: "EPUB"),
            URLQueryItem(name: "alllangs", value: "0"),
            URLQueryItem(name: "langwritten", value: lang),
            URLQueryItem(name: "txtCMSLang", value: lang),
        ]
        if !issue.isEmpty { items.append(URLQueryItem(name: "issue", value: issue)) }
        c.queryItems = items
        guard let url = c.url else { throw Failure.network("Bad address.") }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let what = issue.isEmpty ? symbol.uppercased() : "\(symbol.uppercased()) \(Issues.label(symbol: symbol, issue: issue))"
        if status == 404 { throw Failure.notAvailable(what) }
        guard status == 200 else { throw Failure.network("jw.org answered with an error (\(status)).") }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.network("jw.org sent something unexpected.")
        }

        let pubName = json["pubName"] as? String
        guard let files = json["files"] as? [String: Any] else { throw Failure.notAvailable(what) }
        // Prefer the requested language, then anything that came back.
        let langBlocks = [files[lang]].compactMap { $0 } + files.values.map { $0 }
        for block in langBlocks {
            guard let formats = block as? [String: Any] else { continue }
            let epubKey = formats.keys.first { $0.uppercased() == "EPUB" }
            guard let key = epubKey, let list = formats[key] as? [[String: Any]] else { continue }
            for item in list {
                if let file = item["file"] as? [String: Any],
                   let s = file["url"] as? String, let u = URL(string: s) {
                    let title = pubName ?? (item["title"] as? String) ?? what
                    return Link(url: u, title: title)
                }
            }
        }
        throw Failure.notAvailable(what)
    }
}
