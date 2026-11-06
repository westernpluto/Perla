import Foundation

/// A piece of text with its inline style.
struct InlineRun: Hashable {
    var text: String
    var bold = false
    var italic = false
    var sup = false
    var parNum = false
    var chapterNum = false
    var normalWeight = false
    var color: String?
    /// "doc:<path#fragment>" for links inside the publication, or a web address.
    var link: String?
    /// A JW icon (music note, gem…) drawn inline before the text that follows.
    var icon: String?

    func sameStyle(_ o: InlineRun) -> Bool {
        icon == nil && o.icon == nil && bold == o.bold && italic == o.italic && sup == o.sup && parNum == o.parNum
            && chapterNum == o.chapterNum && normalWeight == o.normalWeight && color == o.color && link == o.link
    }

    /// A "*" or letter that points to a footnote.
    var isNoteMark: Bool {
        guard let link else { return false }
        return link.contains("#footnote") || text.trimmingCharacters(in: .whitespaces) == "*"
    }
}

enum NodeKind: Equatable {
    case container, text, image, rule, field
}

enum TextRole: Equatable {
    case h1, h2, h3, h4, paragraph, caption, listItem, note
}

/// One element of a page: a block of text, a group with its own style, a picture, or an answer box.
struct DocNode: Identifiable {
    var id = 0
    var kind: NodeKind
    var tag: String
    var classes: [String] = []
    var style = NodeStyle()
    var role: TextRole = .paragraph
    var runs: [InlineRun] = []
    var plain = ""
    var children: [DocNode] = []
    var image: String?
    var alt = ""
    var elementID: String?
    var anchors: [String] = []
    var pid: Int?
    var relPid: Int?
    var listMarker: String?

    func has(_ cls: String) -> Bool { classes.contains(cls) }
    func hasPrefix(_ p: String) -> Bool { classes.contains { $0.hasPrefix(p) } }

    /// Depth-first walk over this node and everything inside it.
    func walk(_ visit: (DocNode) -> Void) {
        visit(self)
        for c in children { c.walk(visit) }
    }
}

/// A verse, footnote or publication reference that a page links to.
struct Reference {
    var title: String
    var text: String
    var nodes: [DocNode]
}

/// A parsed chapter or article.
struct Document {
    var nodes: [DocNode]
    var footnoteNodes: [DocNode]
    var citations: [String: Reference]
    var footnotes: [String: Reference]
    var title: String

    static let empty = Document(nodes: [], footnoteNodes: [], citations: [:], footnotes: [:], title: "")

    /// Every node in reading order.
    var allNodes: [DocNode] {
        var out: [DocNode] = []
        for n in nodes { n.walk { out.append($0) } }
        return out
    }
}

/// Builds the native page tree from a publication's XHTML.
final class DocParser: NSObject, XMLParserDelegate {
    private final class Frame {
        let tag: String
        let classes: [String]
        let attrs: [String: String]
        var children: [DocNode] = []
        var runs: [InlineRun] = []
        var anchors: [String] = []
        init(tag: String, classes: [String], attrs: [String: String]) {
            self.tag = tag
            self.classes = classes
            self.attrs = attrs
        }
    }

    private struct Inline {
        let tag: String
        let classes: [String]
        let attrs: [String: String]
    }

    private enum Entry {
        case block(Frame)
        case inline(Inline)
        case skip
    }

    private static let blockTags: Set<String> = [
        "html", "body", "header", "footer", "main", "section", "article", "aside", "div", "figure", "figcaption",
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "thead", "tbody", "tr", "td", "th",
        "blockquote", "dl", "dt", "dd", "pre", "caption",
    ]
    private static let lineBreak: Character = "\u{2028}"

    private let path: String
    private var stack: [Entry] = []
    private var root: DocNode?
    private var skipDepth = 0

    private init(path: String) {
        self.path = path
    }

    /// `firstID` numbers the nodes from that value, so nodes from a second file (the "-extracted"
    /// research file) never share ids with the page they're shown on.
    static func parse(data: Data, path: String, firstID: Int = 0) -> Document {
        let p = DocParser(path: path)
        let parser = XMLParser(data: prepared(data))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = p
        parser.parse()
        // Close anything left open by a parse error.
        while !p.stack.isEmpty { p.closeTop() }
        guard let root = p.root else { return .empty }
        return finish(root, firstID: firstID)
    }

    /// XMLParser only knows XML's five entities; swap common HTML ones for numeric references.
    private static func prepared(_ data: Data) -> Data {
        guard var s = String(data: data, encoding: .utf8), s.contains("&") else { return data }
        let map = ["&nbsp;": "&#160;", "&ndash;": "&#8211;", "&mdash;": "&#8212;", "&rsquo;": "&#8217;",
                   "&lsquo;": "&#8216;", "&ldquo;": "&#8220;", "&rdquo;": "&#8221;", "&hellip;": "&#8230;",
                   "&middot;": "&#183;", "&copy;": "&#169;", "&shy;": "&#173;", "&thinsp;": "&#8201;",
                   "&laquo;": "&#171;", "&raquo;": "&#187;", "&iexcl;": "&#161;", "&iquest;": "&#191;",
                   "&bull;": "&#8226;", "&deg;": "&#176;", "&times;": "&#215;", "&zwj;": "&#8205;"]
        for (k, v) in map where s.contains(k) { s = s.replacingOccurrences(of: k, with: v) }
        return Data(s.utf8)
    }

    // MARK: XML events

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
        let tag = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        let classes = (attrs["class"] ?? "").split(separator: " ").map { String($0) }

        if skipDepth > 0 || shouldSkip(tag: tag, classes: classes, attrs: attrs) {
            skipDepth += 1
            stack.append(.skip)
            return
        }

        switch tag {
        case "br":
            appendText(String(Self.lineBreak))
            stack.append(.skip)
            return
        case "hr":
            add(DocNode(kind: .rule, tag: tag, classes: classes, style: NodeStyle.parse(classes)))
            stack.append(.skip)
            return
        case "img", "image":
            let src = attrs["src"] ?? attrs["xlink:href"] ?? attrs["href"] ?? ""
            if !src.isEmpty {
                var n = DocNode(kind: .image, tag: tag, classes: classes, style: NodeStyle.parse(classes))
                n.image = EPUBParser.path(src, relativeTo: path)
                n.alt = attrs["alt"] ?? ""
                add(n)
            }
            stack.append(.skip)
            return
        default:
            break
        }

        if tag == "div", classes.contains("gen-field") {
            var n = DocNode(kind: .field, tag: tag, classes: classes)
            n.pid = attrs["data-pid"].flatMap { Int($0) }
            n.elementID = attrs["id"]
            add(n)
            skipDepth += 1
            stack.append(.skip)
            return
        }

        if Self.blockTags.contains(tag) {
            if let f = currentFrame, f.runs.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) {
                flushRuns(of: f)
            }
            let f = Frame(tag: tag, classes: classes, attrs: attrs)
            if let id = attrs["id"] { f.anchors.append(id) }
            stack.append(.block(f))
        } else {
            if let id = attrs["id"], let f = currentFrame { f.anchors.append(id) }
            if let icon = classes.first(where: { $0.hasPrefix("dc-icon--") }), let f = currentFrame {
                var r = InlineRun(text: " ")
                r.icon = String(icon.dropFirst("dc-icon--".count))
                f.runs.append(r)
            }
            stack.append(.inline(Inline(tag: tag, classes: classes, attrs: attrs)))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        closeTop()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        appendText(string)
    }

    private func shouldSkip(tag: String, classes: [String], attrs: [String: String]) -> Bool {
        if ["head", "script", "style", "noscript", "title", "template", "textarea", "nav"].contains(tag) { return true }
        if attrs["aria-hidden"] == "true" { return true }
        if (attrs["epub:type"] ?? "").contains("pagebreak") { return true }
        if classes.contains("dc-screenReaderText") || classes.contains("pageNum") || classes.contains("w_navigation") {
            return true
        }
        return false
    }

    // MARK: Building

    private var currentFrame: Frame? {
        for e in stack.reversed() { if case .block(let f) = e { return f } }
        return nil
    }

    private func closeTop() {
        guard let top = stack.popLast() else { return }
        switch top {
        case .skip:
            if skipDepth > 0 { skipDepth -= 1 }
        case .inline:
            break
        case .block(let f):
            let node = build(f)
            if let node {
                if currentFrame == nil {
                    if f.tag == "body" || root == nil { root = node }
                } else {
                    add(node)
                }
            }
        }
    }

    private func add(_ node: DocNode) {
        guard let f = currentFrame else {
            if root == nil { root = node }
            return
        }
        if f.runs.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) { flushRuns(of: f) } else { f.runs = [] }
        f.children.append(node)
    }

    private func appendText(_ s: String) {
        guard let f = currentFrame else { return }
        var run = InlineRun(text: s)
        var inlines: [Inline] = []
        for e in stack.reversed() {
            if case .inline(let i) = e { inlines.append(i) } else if case .block = e { break }
        }
        for i in inlines.reversed() {
            switch i.tag {
            case "b", "strong": run.bold = true
            case "i", "em", "cite": run.italic = true
            case "sup": run.sup = true
            case "a":
                if let h = i.attrs["href"], !h.isEmpty { run.link = resolve(h) }
            default: break
            }
            if i.classes.contains("parNum") { run.parNum = true }
            if i.classes.contains("w_ch") || i.classes.contains("chapterNo") { run.chapterNum = true }
            if i.classes.contains("du-fontWeight--normal") { run.normalWeight = true }
            if let c = i.classes.first(where: { $0.hasPrefix("du-color--") }) { run.color = String(c.dropFirst(10)) }
        }
        if let last = f.runs.last, last.sameStyle(run) {
            f.runs[f.runs.count - 1].text += s
        } else {
            f.runs.append(run)
        }
    }

    private func flushRuns(of f: Frame) {
        let runs = Linkifier.apply(Self.normalize(f.runs))
        f.runs = []
        guard !runs.isEmpty else { return }
        var n = DocNode(kind: .text, tag: "span", role: role(for: f.tag))
        n.runs = runs
        n.plain = runs.map(\.text).joined()
        n.anchors = f.anchors
        f.children.append(n)
    }

    private func build(_ f: Frame) -> DocNode? {
        let style = NodeStyle.parse(f.classes)
        var node = DocNode(kind: .container, tag: f.tag, classes: f.classes, style: style)
        node.elementID = f.attrs["id"]
        node.anchors = f.anchors
        node.pid = f.attrs["data-pid"].flatMap { Int($0) }
        node.relPid = f.attrs["data-rel-pid"].flatMap { v in Int(v.filter(\.isNumber)) }
        if inCaption || f.tag == "figcaption" { node.role = .caption } else { node.role = role(for: f.tag) }

        if f.children.isEmpty {
            let runs = Linkifier.apply(Self.normalize(f.runs))
            guard !runs.isEmpty else {
                return f.tag == "figure" || f.tag == "li" ? nil : (style.borderTop != nil || style.borderBottom != nil ? node : nil)
            }
            node.kind = .text
            node.runs = runs
            node.plain = runs.map(\.text).joined()
        } else {
            if f.runs.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) { flushRuns(of: f) }
            node.children = f.children
        }
        if f.tag == "li" { node.listMarker = listMarker() }
        return node
    }

    private var inCaption: Bool {
        stack.contains { e in
            if case .block(let f) = e { return f.tag == "figcaption" }
            return false
        }
    }

    private func role(for tag: String) -> TextRole {
        switch tag {
        case "h1": return .h1
        case "h2": return .h2
        case "h3": return .h3
        case "h4", "h5", "h6", "dt": return .h4
        case "figcaption", "caption": return .caption
        case "li": return .listItem
        default: return inCaption ? .caption : .paragraph
        }
    }

    /// Bullet or number for a list item, from the list it belongs to.
    private func listMarker() -> String? {
        for e in stack.reversed() {
            guard case .block(let f) = e else { continue }
            if f.tag == "ul" {
                return NodeStyle.parse(f.classes).listNone ? nil : "•"
            }
            if f.tag == "ol" {
                if f.classes.contains("source") { return nil }
                let n = f.children.filter { $0.tag == "li" }.count + 1
                return "\(n)."
            }
        }
        return nil
    }

    private func resolve(_ href: String) -> String {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        // Anything with a scheme (https:, jwpub:, mailto:…) is a link out of the publication.
        if let colon = h.firstIndex(of: ":"), h[..<colon].allSatisfy({ $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }),
           !h[..<colon].isEmpty {
            return h
        }
        if h.hasPrefix("//") { return "https:" + h }
        if h.hasPrefix("#") { return "doc:" + path + h }
        return "doc:" + EPUBParser.path(h, relativeTo: path)
    }

    /// Collapses whitespace the way a browser would, keeping explicit line breaks.
    static func normalize(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        var lastWasSpace = true
        for var r in runs {
            if r.icon != nil {
                out.append(r)
                lastWasSpace = false
                continue
            }
            var t = ""
            for ch in r.text {
                if ch == lineBreak {
                    while t.hasSuffix(" ") { t.removeLast() }
                    t.append("\n")
                    lastWasSpace = true
                } else if ch.isWhitespace {
                    if !lastWasSpace {
                        t.append(" ")
                        lastWasSpace = true
                    }
                } else {
                    t.append(ch)
                    lastWasSpace = false
                }
            }
            r.text = t
            if !t.isEmpty { out.append(r) }
        }
        while var last = out.last, let ch = last.text.last, ch == " " || ch == "\n" {
            last.text.removeLast()
            if last.text.isEmpty { out.removeLast() } else { out[out.count - 1] = last }
        }
        return out
    }

    // MARK: Finishing

    private static func finish(_ root: DocNode, firstID: Int) -> Document {
        var citations: [String: Reference] = [:]
        var footnotes: [String: Reference] = [:]
        var footnoteNodes: [DocNode] = []

        // Pull verse texts (groupExt) and footnotes (groupFootnote) out of the page.
        func containsPubRefs(_ node: DocNode) -> Bool {
            var found = false
            node.walk { if !found, $0.has("extPubRef") { found = true } }
            return found
        }
        func strip(_ node: DocNode) -> DocNode? {
            // In "-extracted" files the whole body is a groupExt holding the research (extPubRef);
            // only the verse boxes inside it are pulled out.
            if node.has("groupExt"), !containsPubRefs(node) {
                node.walk { n in
                    guard let id = n.elementID, n.has("extScrpCite") else { return }
                    citations[id] = reference(from: n)
                }
                return nil
            }
            if node.has("groupFootnote") {
                node.walk { n in
                    guard let id = n.elementID, id.hasPrefix("footnote") else { return }
                    footnotes[id] = reference(from: n)
                }
                var notes = node
                markNotes(&notes)
                footnoteNodes.append(notes)
                return nil
            }
            var copy = node
            copy.children = node.children.compactMap(strip)
            return copy
        }
        guard let cleaned = strip(root) else { return .empty }

        var counter = firstID
        var top = flatten(cleaned)
        number(&top, &counter)
        var notes = footnoteNodes.flatMap(flatten)
        number(&notes, &counter)

        var title = ""
        for n in top {
            n.walk { if title.isEmpty, $0.role == .h1, $0.kind == .text { title = $0.plain } }
        }
        return Document(nodes: top, footnoteNodes: notes, citations: citations, footnotes: footnotes, title: title)
    }

    private static func markNotes(_ node: inout DocNode) {
        if node.kind == .text { node.role = .note }
        for i in node.children.indices { markNotes(&node.children[i]) }
    }

    /// The text of a verse or footnote, without its "^ (Jer. 47:1)" back-link.
    private static func reference(from node: DocNode) -> Reference {
        var texts: [DocNode] = []
        node.walk { if $0.kind == .text { texts.append($0) } }
        var title = ""
        var parts: [String] = []
        var kept: [DocNode] = []
        for (i, t) in texts.enumerated() {
            var line = t.plain
            var copy = t
            if i == 0 {
                // Keep the text without its "^ (Jer. 32:19)" back-link, for drawing it in a sheet.
                var runs = t.runs
                while let first = runs.first, let l = first.link, l.contains("source") { runs.removeFirst() }
                if var f = runs.first {
                    while f.text.first?.isWhitespace == true { f.text.removeFirst() }
                    if f.text.isEmpty { runs.removeFirst() } else { runs[0] = f }
                }
                copy.runs = runs
                copy.plain = runs.map(\.text).joined()
                if let r = line.range(of: "^\\^?\\s*", options: .regularExpression) { line.removeSubrange(r) }
                if let m = line.range(of: "^\\([^)]{1,60}\\)", options: .regularExpression) {
                    title = String(line[m]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    line.removeSubrange(m)
                } else if let ref = t.runs.first(where: { $0.link != nil })?.text {
                    let r = ref.replacingOccurrences(of: "^", with: "").trimmingCharacters(in: .whitespaces)
                    if !r.isEmpty, line.hasPrefix(r) {
                        title = r
                        line.removeFirst(r.count)
                    }
                }
            }
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                parts.append(clean)
                if !copy.runs.isEmpty { kept.append(copy) }
            }
        }
        return Reference(title: title, text: parts.joined(separator: "\n"), nodes: kept)
    }

    /// Containers that carry no styling of their own are dissolved into their parent.
    private static func flatten(_ node: DocNode) -> [DocNode] {
        var n = node
        n.children = node.children.flatMap(flatten)
        if n.kind == .container {
            if n.children.isEmpty { return [] }
            let semantic = ["ul", "ol", "li", "figure", "aside", "table", "blockquote"].contains(n.tag)
                || n.has("boxContent") || n.has("boxTtl") || n.has("blockTeach") || n.has("extPubRef")
                || n.hasPrefix("dc-icon--") || n.role == .caption
            if !semantic && !n.style.hasVisual && n.style.marginTop == nil && n.style.marginBottom == nil {
                return n.children
            }
        }
        return [n]
    }

    private static func number(_ nodes: inout [DocNode], _ counter: inout Int) {
        for i in nodes.indices {
            nodes[i].id = counter
            counter += 1
            number(&nodes[i].children, &counter)
        }
    }
}

extension Document {
    /// Publication references in an "-extracted" file, keyed by their anchor (pcitationN).
    func extractedReferences() -> [String: Reference] {
        var out: [String: Reference] = [:]
        for n in nodes { collectRefs(n, into: &out) }
        return out
    }

    private func collectRefs(_ node: DocNode, into out: inout [String: Reference]) {
        if node.has("extPubRef") {
            var children = node.children
            guard !children.isEmpty else { return }
            let head = children.removeFirst()
            guard let anchor = head.anchors.first(where: { $0.hasPrefix("pcitation") }) else { return }
            let title = head.plain
                .replacingOccurrences(of: "^", with: "")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var text: [String] = []
            for c in children { c.walk { if $0.kind == .text { text.append($0.plain) } } }
            out[anchor] = Reference(title: title, text: text.joined(separator: "\n"), nodes: children)
            return
        }
        for c in node.children { collectRefs(c, into: &out) }
    }
}
