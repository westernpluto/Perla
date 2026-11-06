import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct TOCEntry: Codable, Hashable, Identifiable {
    var label: String
    /// Path inside the publication folder, may include a #fragment.
    var href: String
    var level: Int
    var id: String { href + "|" + label }

    var file: String { href.components(separatedBy: "#").first ?? href }
}

struct ParsedEPUB {
    var title: String
    var spine: [String]
    var toc: [TOCEntry]
    var cover: String?
}

enum EPUBError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let m): return "Couldn't open this publication (\(m))." }
    }
}

/// Reads an unzipped EPUB folder: container → package (OPF) → spine, table of contents and cover.
enum EPUBParser {
    static func parse(folder: URL) throws -> ParsedEPUB {
        let containerURL = folder.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL) else { throw EPUBError.unreadable("no container") }
        let container = XMLScan.run(containerData)
        guard let opfPath = container.first(where: { $0.name.hasSuffix("rootfile") })?.attrs["full-path"] else {
            throw EPUBError.unreadable("no package")
        }
        guard let opfData = try? Data(contentsOf: folder.appendingPathComponent(opfPath)) else {
            throw EPUBError.unreadable("package missing")
        }
        let opf = XMLScan.run(opfData)

        var title = ""
        var manifest: [String: (href: String, type: String, props: String)] = [:]
        var spineIDs: [String] = []
        var coverID: String?
        var ncxID: String?
        for el in opf {
            switch el.localName {
            case "title":
                if title.isEmpty { title = el.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "item":
                if let id = el.attrs["id"], let href = el.attrs["href"] {
                    manifest[id] = (href: path(href, relativeTo: opfPath),
                                    type: el.attrs["media-type"] ?? "",
                                    props: el.attrs["properties"] ?? "")
                }
            case "itemref":
                if let idref = el.attrs["idref"], el.attrs["linear"] != "no" { spineIDs.append(idref) }
            case "spine":
                ncxID = el.attrs["toc"]
            case "meta":
                if el.attrs["name"] == "cover" { coverID = el.attrs["content"] }
            default:
                break
            }
        }

        let spine = spineIDs.compactMap { manifest[$0]?.href }
        guard !spine.isEmpty else { throw EPUBError.unreadable("empty") }

        var cover: String?
        if let id = coverID, let item = manifest[id], item.type.hasPrefix("image") { cover = item.href }
        if cover == nil { cover = manifest.values.first { $0.props.contains("cover-image") }?.href }
        if cover == nil {
            cover = manifest.values.first { $0.type.hasPrefix("image") && $0.href.lowercased().contains("cover") }?.href
        }

        var toc: [TOCEntry] = []
        if let nav = manifest.values.first(where: { $0.props.split(separator: " ").contains("nav") }),
           let data = try? Data(contentsOf: folder.appendingPathComponent(nav.href)) {
            toc = navTOC(data, base: nav.href)
        }
        if toc.isEmpty, let id = ncxID, let ncx = manifest[id],
           let data = try? Data(contentsOf: folder.appendingPathComponent(ncx.href)) {
            toc = ncxTOC(data, base: ncx.href)
        }
        if toc.isEmpty {
            toc = spine.map { file in
                let html = (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)) ?? ""
                return TOCEntry(label: HTMLText.title(html) ?? file, href: file, level: 0)
            }
        }
        return ParsedEPUB(title: title, spine: spine, toc: toc, cover: cover)
    }

    // EPUB 3 navigation document: <nav epub:type="toc"><ol><li><a href>…
    private static func navTOC(_ data: Data, base: String) -> [TOCEntry] {
        let els = XMLScan.run(data)
        func navType(_ el: XMLElementInfo) -> String { el.attrs["epub:type"] ?? el.attrs["type"] ?? "" }
        let hasTyped = els.contains { $0.localName == "nav" && navType($0).contains("toc") }
        var out: [TOCEntry] = []
        var navCount = 0
        var inTOC = false
        for el in els {
            if el.localName == "nav" {
                navCount += 1
                inTOC = hasTyped ? navType(el).contains("toc") : navCount == 1
                continue
            }
            guard inTOC, el.localName == "a", el.ancestors.contains("nav"), let href = el.attrs["href"] else { continue }
            let label = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            out.append(TOCEntry(label: label, href: path(href, relativeTo: base), level: max(0, el.listDepth - 1)))
        }
        return out
    }

    // EPUB 2 NCX: <navPoint><navLabel><text>…</text></navLabel><content src=…/>
    private static func ncxTOC(_ data: Data, base: String) -> [TOCEntry] {
        let els = XMLScan.run(data)
        var out: [TOCEntry] = []
        var pendingLabel: String?
        for el in els {
            if el.localName == "text", el.ancestors.contains("navLabel") {
                pendingLabel = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if el.localName == "content", let src = el.attrs["src"] {
                let depth = el.ancestors.filter { $0 == "navPoint" }.count
                out.append(TOCEntry(label: pendingLabel ?? src, href: path(src, relativeTo: base), level: max(0, depth - 1)))
                pendingLabel = nil
            }
        }
        return out
    }

    /// Resolves `href` (relative to the file at `base`) to a path inside the publication folder.
    static func path(_ href: String, relativeTo base: String) -> String {
        let baseURL = URL(string: "epub:///" + (base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base))
        // Hrefs with spaces or other unescaped characters aren't valid URLs; escape them first.
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: "#%")
        let safe = URL(string: href) != nil ? href : (href.addingPercentEncoding(withAllowedCharacters: allowed) ?? href)
        guard let u = URL(string: safe, relativeTo: baseURL)?.absoluteURL else { return href }
        var p = u.path
        if p.hasPrefix("/") { p.removeFirst() }
        if let f = u.fragment, !f.isEmpty { p += "#" + f }
        return p
    }
}

/// A flat list of XML elements with their attributes, text and nesting — enough for EPUB metadata.
struct XMLElementInfo {
    var name: String
    var attrs: [String: String]
    var text: String
    var ancestors: [String]
    var listDepth: Int
    var localName: String { name.components(separatedBy: ":").last ?? name }
}

final class XMLScan: NSObject, XMLParserDelegate {
    private var out: [XMLElementInfo] = []
    private var stack: [(index: Int, local: String)] = []

    static func run(_ data: Data) -> [XMLElementInfo] {
        let scan = XMLScan()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = scan
        parser.parse()
        return scan.out
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        let ancestors = stack.map(\.local)
        let depth = ancestors.filter { $0 == "ol" || $0 == "ul" }.count
        out.append(XMLElementInfo(name: elementName, attrs: attributeDict, text: "", ancestors: ancestors, listDepth: depth))
        stack.append((index: out.count - 1, local: local))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Text belongs to every open element (so <a><span>x</span></a> gives the link its text).
        for entry in stack { out[entry.index].text += string }
    }
}

/// Small helpers for pulling plain text out of XHTML without a full HTML engine.
enum HTMLText {
    static func title(_ html: String) -> String? {
        for pattern in ["<h1[^>]*>([\\s\\S]*?)</h1>", "<title[^>]*>([\\s\\S]*?)</title>"] {
            if let r = html.range(of: pattern, options: .regularExpression) {
                let inner = String(html[r]).replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                let t = clean(inner)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// The document body as plain text, one line per block.
    static func plain(_ html: String) -> String {
        var s = html
        if let start = s.range(of: "<body", options: .caseInsensitive) { s = String(s[start.lowerBound...]) }
        s = s.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</(script|style)>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</?(p|h[1-6]|li|div|tr|section|header|figcaption|blockquote|br)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decode(s)
        return s.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Splits XHTML into text blocks, keeping the links found in each block.
    static func blocks(_ html: String) -> [(text: String, hrefs: [String])] {
        var s = html
        if let start = s.range(of: "<body", options: .caseInsensitive) { s = String(s[start.lowerBound...]) }
        let marker = "\u{1E}"
        s = s.replacingOccurrences(of: "</?(p|h[1-6]|li|div|tr|td|section|header|figcaption|blockquote)[^>]*>", with: marker, options: [.regularExpression, .caseInsensitive])
        var out: [(text: String, hrefs: [String])] = []
        for part in s.components(separatedBy: marker) {
            var hrefs: [String] = []
            if let re = try? NSRegularExpression(pattern: "href=\"([^\"]+)\"") {
                let ns = part as NSString
                for m in re.matches(in: part, range: NSRange(location: 0, length: ns.length)) {
                    hrefs.append(ns.substring(with: m.range(at: 1)))
                }
            }
            let text = clean(part.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
            if !text.isEmpty || !hrefs.isEmpty { out.append((text: text, hrefs: hrefs)) }
        }
        return out
    }

    static func clean(_ s: String) -> String {
        decode(s).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                     "&#39;": "'", "&ndash;": "–", "&mdash;": "—", "&rsquo;": "’", "&lsquo;": "‘",
                     "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        guard out.contains("&#"), let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let v = UInt32(num, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(v) {
                result += String(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
