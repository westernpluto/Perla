import Foundation

/// The cover of a publication jw.org has no thumbnail for (the regular Bible), read straight out of its
/// EPUB on the server: the zip's directory and the one cover file are fetched with range requests,
/// a few dozen KB instead of the whole download. Kept in the caches folder afterwards.
enum RemoteCover {
    private static func cacheURL(_ symbol: String, _ issue: String, _ lang: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(lang)_\(symbol)_\(issue).jpg")
    }

    static func cached(symbol: String, issue: String = "", lang: String) -> URL? {
        let url = cacheURL(symbol, issue, lang)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func fetch(symbol: String, issue: String = "", lang: String) async -> URL? {
        if let done = cached(symbol: symbol, issue: issue, lang: lang) { return done }
        guard let link = try? await PubMedia.epubLink(symbol: symbol, issue: issue, lang: lang),
              let jpg = await coverFile(in: link.url) else { return nil }
        let url = cacheURL(symbol, issue, lang)
        guard (try? jpg.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    private static func range(_ url: URL, _ from: Int, _ to: Int) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 206 else { return nil }
        return data
    }

    private static func size(_ url: URL) async -> Int? {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return nil }
        let len = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
        return len > 0 ? Int(len) : nil
    }

    private static func u16(_ d: Data, _ i: Int) -> Int { Int(d[d.startIndex + i]) | Int(d[d.startIndex + i + 1]) << 8 }
    private static func u32(_ d: Data, _ i: Int) -> Int { u16(d, i) | u16(d, i + 2) << 16 }

    /// Finds "…_cvr.jpg" in the zip's central directory and returns its bytes.
    private static func coverFile(in url: URL) async -> Data? {
        guard let total = await size(url) else { return nil }
        let tailStart = max(0, total - 65_557)
        guard let tail = await range(url, tailStart, total - 1) else { return nil }
        // End of central directory record: PK\5\6.
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if u32(tail, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { return nil }
        let dirSize = u32(tail, e + 12), dirOffset = u32(tail, e + 16)
        let dir: Data
        if dirOffset >= tailStart {
            dir = tail.subdata(in: (dirOffset - tailStart)..<(dirOffset - tailStart + dirSize))
        } else {
            guard let d = await range(url, dirOffset, dirOffset + dirSize - 1) else { return nil }
            dir = d
        }
        // Central directory entries: PK\1\2.
        var p = 0
        while p + 46 <= dir.count, u32(dir, p) == 0x0201_4b50 {
            let method = u16(dir, p + 10)
            let compressed = u32(dir, p + 20)
            let nameLen = u16(dir, p + 28), extraLen = u16(dir, p + 30), commentLen = u16(dir, p + 32)
            let local = u32(dir, p + 42)
            let name = String(decoding: dir.subdata(in: (p + 46)..<(p + 46 + nameLen)), as: UTF8.self)
            if name.lowercased().hasSuffix("_cvr.jpg") {
                guard let header = await range(url, local, local + 29), u32(header, 0) == 0x0403_4b50 else { return nil }
                let start = local + 30 + u16(header, 26) + u16(header, 28)
                guard let raw = await range(url, start, start + compressed - 1) else { return nil }
                if method == 0 { return raw }
                #if canImport(Darwin)
                if method == 8 { return try? (raw as NSData).decompressed(using: .zlib) as Data }
                #endif
                return nil
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return nil
    }
}
