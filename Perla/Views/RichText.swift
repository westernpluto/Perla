import SwiftUI
import UIKit

// MARK: - Highlights

/// Text you've highlighted, kept per paragraph: publication, document and paragraph.
@MainActor
final class HighlightStore: ObservableObject {
    static let shared = HighlightStore()

    enum Tint: String, Codable, CaseIterable {
        case yellow, green, blue, pink, orange

        var name: String {
            switch self {
            case .yellow: return L("Yellow")
            case .green: return L("Green")
            case .blue: return L("Blue")
            case .pink: return L("Pink")
            case .orange: return L("Orange")
            }
        }

        /// Soft enough to read through in light and dark mode.
        var color: UIColor {
            let (light, dark): (UInt32, UInt32)
            switch self {
            case .yellow: (light, dark) = (0xFFE680, 0x7A6A1F)
            case .green: (light, dark) = (0xC5EBA8, 0x3D6230)
            case .blue: (light, dark) = (0xB9DCF7, 0x2C4F6E)
            case .pink: (light, dark) = (0xF6C3DA, 0x6E3350)
            case .orange: (light, dark) = (0xFFD2A6, 0x7A4A1F)
            }
            return UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
        }
    }

    struct Mark: Codable, Hashable {
        var location: Int
        var length: Int
        var tint: Tint
        var range: NSRange { NSRange(location: location, length: length) }
    }

    @Published private(set) var marks: [String: [Mark]] = [:]
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("highlights.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: [Mark]].self, from: data) {
            marks = saved
        }
    }

    static func key(pubID: String, doc: String, node: Int) -> String { "\(pubID)|\(doc)|\(node)" }

    func add(_ range: NSRange, tint: Tint, key: String) {
        var list = (marks[key] ?? []).flatMap { cut($0, by: range) }
        list.append(Mark(location: range.location, length: range.length, tint: tint))
        marks[key] = list.sorted { $0.location < $1.location }
        save()
    }

    func remove(_ range: NSRange, key: String) {
        let list = (marks[key] ?? []).flatMap { cut($0, by: range) }
        marks[key] = list.isEmpty ? nil : list
        save()
    }

    func overlaps(_ range: NSRange, key: String) -> Bool {
        (marks[key] ?? []).contains { NSIntersectionRange($0.range, range).length > 0 || NSLocationInRange(range.location, $0.range) }
    }

    /// What's left of `mark` outside `range` (0, 1 or 2 pieces).
    private func cut(_ mark: Mark, by range: NSRange) -> [Mark] {
        let a = mark.location, b = mark.location + mark.length
        let c = range.location, d = range.location + range.length
        guard c < b, d > a else { return [mark] }
        var out: [Mark] = []
        if c > a { out.append(Mark(location: a, length: c - a, tint: mark.tint)) }
        if d < b { out.append(Mark(location: d, length: b - d, tint: mark.tint)) }
        return out
    }

    private func save() {
        if let data = try? JSONEncoder().encode(marks) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - Text view

/// A paragraph drawn by iOS's own text view, so you can select words and highlight them.
/// Links open through the page's link handler.
struct RichText: UIViewRepresentable {
    let text: NSAttributedString
    /// Where highlights for this paragraph are kept; nil when it can't be highlighted (sheets).
    let highlightKey: String?
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.linkTextAttributes = [:]
        v.delegate = context.coordinator
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        if v.attributedText != text { v.attributedText = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichText?

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.parent?.onLink(url) }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            // Long-pressing a link just opens it, like tapping.
            if case .link(let url) = textItem.content {
                parent?.onLink(url)
                return nil
            }
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let key = parent?.highlightKey, range.length > 0 else { return UIMenu(children: suggestedActions) }
            let store = HighlightStore.shared
            var items: [UIMenuElement] = HighlightStore.Tint.allCases.map { tint in
                UIAction(title: tint.name, image: UIImage(systemName: "circle.fill")?
                    .withTintColor(tint.color, renderingMode: .alwaysOriginal)) { _ in
                    store.add(range, tint: tint, key: key)
                    textView.selectedRange = NSRange(location: range.location, length: 0)
                }
            }
            if store.overlaps(range, key: key) {
                items.append(UIAction(title: L("Remove highlight"), image: UIImage(systemName: "eraser"),
                                      attributes: .destructive) { _ in
                    store.remove(range, key: key)
                    textView.selectedRange = NSRange(location: range.location, length: 0)
                })
            }
            let highlight = UIMenu(title: L("Highlight"), image: UIImage(systemName: "highlighter"), children: items)
            return UIMenu(children: [highlight] + suggestedActions)
        }
    }
}

// MARK: - Building the text

/// Builds a paragraph's styled text for the native text view: bold and italic runs, paragraph and
/// verse numbers, footnote marks, links, icons, labels, search matches and your highlights.
@MainActor
enum PageText {
    static func font(size: CGFloat, weight: UIFont.Weight, serif: Bool, italic: Bool) -> UIFont {
        var f = UIFont.systemFont(ofSize: size, weight: weight)
        var d = f.fontDescriptor
        if serif, let s = d.withDesign(.serif) { d = s }
        if italic, let i = d.withSymbolicTraits(d.symbolicTraits.union(.traitItalic)) { d = i }
        f = UIFont(descriptor: d, size: size)
        return f
    }

    static func build(_ node: DocNode, size: CGFloat, env: PageEnv, heading: Bool, showIcon: Bool,
                      baseColor: UIColor, centered: Bool, highlights: [HighlightStore.Mark]) -> NSAttributedString {
        let serif = env.serif && !heading
        let blockBold = heading && !node.style.normalWeight
        let out = NSMutableAttributedString()
        let plainFont = font(size: size, weight: .regular, serif: serif, italic: false)

        if showIcon, let icon = node.style.icon {
            if let f = JWIcons.shared.uiFont(pubID: env.pubID, size: size * 1.15),
               let glyph = JWIcons.shared.glyph(icon, pubID: env.pubID) {
                out.append(NSAttributedString(string: glyph + "  ", attributes: [.font: f, .foregroundColor: baseColor]))
            } else if let img = UIImage(systemName: JWIcons.symbol(icon))?.withTintColor(baseColor, renderingMode: .alwaysOriginal) {
                let a = NSTextAttachment(image: img)
                out.append(NSAttributedString(attachment: a))
                out.append(NSAttributedString(string: "  ", attributes: [.font: plainFont]))
            }
        }

        if env.bible, node.has("sb"), !node.runs.contains(where: \.chapterNum) {
            // Bible paragraphs start with an indent, as in JW Library.
            out.append(NSAttributedString(string: "\u{2003}\u{2003}", attributes: [.font: plainFont]))
        }

        var runs = node.runs
        if node.role == .note {
            // Footnotes: the "^" back-link becomes a plain bold label ("Sal. 23:2") or disappears.
            var i = 0
            while i < runs.count, let l = runs[i].link, l.contains("source") {
                let t = runs[i].text.replacingOccurrences(of: "^", with: "").trimmingCharacters(in: .whitespaces)
                if t.isEmpty {
                    runs.remove(at: i)
                } else {
                    runs[i].text = t + " "
                    runs[i].link = nil
                    runs[i].bold = true
                    i += 1
                }
            }
        }

        for r in runs {
            if let icon = r.icon {
                if let f = JWIcons.shared.uiFont(pubID: env.pubID, size: size * 1.1),
                   let glyph = JWIcons.shared.glyph(icon, pubID: env.pubID) {
                    out.append(NSAttributedString(string: glyph + " ", attributes: [.font: f, .foregroundColor: baseColor]))
                }
                continue
            }
            var weight: UIFont.Weight = (blockBold || r.bold) && !r.normalWeight ? .bold : .regular
            if heading && node.style.normalWeight && !r.bold { weight = .regular }
            var runSize = size
            var runSerif = serif
            var color: UIColor = r.color.flatMap(JWColor.uiColor) ?? baseColor
            var offset: CGFloat = 0

            if r.chapterNum {
                runSize = size * 2.1
                weight = .bold
                runSerif = false
                color = UIColor(JWColor.verse)
            } else if r.parNum {
                weight = .bold
                runSize = size * 0.86
                runSerif = false
                color = UIColor(JWColor.subdued)
            } else if r.isNoteMark {
                runSize = size * 0.7
                offset = size * 0.38
                runSerif = false
            } else if r.sup && (env.bible || r.bold) {
                // Verse numbers: bold, blue and on the line, like JW Library.
                weight = .bold
                runSize = size * 0.8
                runSerif = false
                color = UIColor(JWColor.verse)
            } else if r.sup {
                runSize = size * 0.7
                offset = size * 0.35
            }

            var text = r.text
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font(size: runSize, weight: weight, serif: runSerif, italic: r.italic),
                .foregroundColor: color,
            ]
            if offset != 0 { attrs[.baselineOffset] = offset }
            if let bg = r.background.flatMap(JWColor.uiBackground) {
                // A label such as the orange "A" on a picture.
                text = "\u{2009}" + text + "\u{2009}"
                attrs[.backgroundColor] = bg
                if r.color == nil { attrs[.foregroundColor] = UIColor.white }
            }
            if let link = r.link, let url = ReaderModel.linkURL(link, text: r.text) {
                attrs[.link] = url
                if r.color == nil, !r.chapterNum, !(r.sup && env.bible) { attrs[.foregroundColor] = UIColor(JWColor.link) }
            } else if env.verseLinks, r.chapterNum || (r.sup && !r.isNoteMark),
                      let v = r.chapterNum ? 1 : Int(r.text.trimmingCharacters(in: .whitespaces)),
                      let url = URL(string: "perla://verse?v=\(v)") {
                attrs[.link] = url
                // With the chapter's study notes loaded, verse numbers that have notes stay blue and
                // the rest turn gray.
                if !env.notedVerses.isEmpty, !r.chapterNum, !env.notedVerses.contains(v) {
                    attrs[.foregroundColor] = UIColor(JWColor.subdued)
                }
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }

        let all = NSRange(location: 0, length: out.length)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = size * (heading ? 0.14 : 0.36)
        para.alignment = centered ? .center : .natural
        out.addAttribute(.paragraphStyle, value: para, range: all)

        for m in highlights where NSMaxRange(m.range) <= out.length {
            out.addAttribute(.backgroundColor, value: m.tint.color, range: m.range)
        }
        if let term = env.findTerm, !term.isEmpty {
            let ns = out.string as NSString
            var search = all
            while search.length > 0 {
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard r.location != NSNotFound else { break }
                out.addAttribute(.backgroundColor, value: UIColor.tintColor.withAlphaComponent(0.35), range: r)
                search = NSRange(location: NSMaxRange(r), length: out.length - NSMaxRange(r))
            }
        }
        return out
    }
}
