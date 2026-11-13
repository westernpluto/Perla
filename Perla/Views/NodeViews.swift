import SwiftUI
import ImageIO

/// Page-wide settings for drawing a document.
struct PageEnv: Equatable {
    /// Body text size in points.
    var base: CGFloat
    /// Body text in a serif face (the Bible always is).
    var serif: Bool
    var bible: Bool
    var pubID: String
    /// How far a full-width band reaches past the text column on each side.
    var bleed: CGFloat
    var findTerm: String?
    /// Which document this is, so views from the last chapter are never reused by mistake.
    var doc: String
    /// Bible chapters: verse numbers open that verse's study notes.
    var verseLinks = false
    /// Verses with study notes, whose numbers are underlined.
    var notedVerses: Set<Int> = []
}

/// Style that flows from a container into everything inside it, like CSS inheritance.
struct Inherited: Equatable {
    var scale: CGFloat = 1
    var color: String?
    var centered = false

    func applying(_ s: NodeStyle) -> Inherited {
        var c = self
        if let f = s.fontScale { c.scale *= f }
        if let col = s.color { c.color = col }
        if s.centered { c.centered = true }
        return c
    }
}

// MARK: - Spacing

/// Space between blocks: the publication's own margins when it sets them, otherwise
/// spacing modelled on JW Library (tight under headings, roomy between parts).
enum PageLayout {
    static func gap(prev: DocNode?, node: DocNode, env: PageEnv, childGap: CGFloat? = nil) -> CGFloat {
        let b = env.base
        guard let prev else { return node.style.marginTop ?? 0 }
        if let m = node.style.marginTop { return max(m, prev.style.marginBottom ?? 0) }
        if let m = prev.style.marginBottom { return m }
        if let childGap { return childGap }
        if env.bible, node.kind == .text, prev.kind == .text, !isHeading(node), !isHeading(prev) {
            // Bible paragraphs and poetry lines run on like the printed page.
            return b * 0.36
        }
        if node.kind == .field { return 8 }
        if prev.kind == .field { return b * 0.9 }
        if prev.kind == .text {
            switch prev.role {
            case .h1: return b * 0.6
            case .h2: return b * 0.7
            case .h3, .h4: return b * 0.35
            default: break
            }
        }
        if node.kind == .text {
            switch node.role {
            case .h1: return b * 0.9
            case .h2: return b * 1.7
            case .h3, .h4: return b * 1.2
            case .caption: return 6
            case .note: return 10
            default: break
            }
        }
        if node.kind == .image || prev.kind == .image || node.tag == "figure" || prev.tag == "figure" { return b * 0.9 }
        if node.kind == .rule || prev.kind == .rule { return b * 0.6 }
        if node.tag == "li" || node.role == .listItem { return b * 0.45 }
        return b * 0.75
    }

    static func isHeading(_ n: DocNode) -> Bool {
        n.kind == .text && (n.role == .h1 || n.role == .h2 || n.role == .h3 || n.role == .h4)
    }
}

// MARK: - Nodes

/// Draws one element of a page and everything inside it.
struct NodeView: View, Equatable {
    let node: DocNode
    let env: PageEnv
    let inherited: Inherited
    let reader: ReaderModel
    let onImage: (String) -> Void

    init(node: DocNode, env: PageEnv, inherited: Inherited, reader: ReaderModel, onImage: @escaping (String) -> Void) {
        self.node = node
        self.env = env
        self.inherited = inherited
        self.reader = reader
        self.onImage = onImage
    }

    nonisolated static func == (a: NodeView, b: NodeView) -> Bool {
        a.node.id == b.node.id && a.env == b.env && a.inherited == b.inherited
    }

    var body: some View {
        switch node.kind {
        case .text:
            textNode
        case .container:
            ContainerBlock(node: node, env: env, inherited: inherited, reader: reader, onImage: onImage)
        case .image:
            imageNode
        case .rule:
            Rectangle()
                .fill(JWColor.border)
                .frame(width: 64, height: 1)
                .frame(maxWidth: .infinity, alignment: inherited.centered ? .center : .leading)
                .padding(.leading, node.style.indent)
        case .field:
            FieldBlock(reader: reader, questionID: reader.questionAtField[node.id],
                       size: env.base * inherited.scale, added: false)
                .padding(.leading, node.style.indent)
        }
    }

    @ViewBuilder
    private var textNode: some View {
        let size = TextBlock.size(node, env: env, inherited: inherited)
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let icon = node.style.icon, node.style.iconBackground != nil {
                    HStack(alignment: .center, spacing: env.base * 0.55) {
                        IconTile(icon: icon, pubID: env.pubID, size: size * 1.05,
                                 background: node.style.iconBackground, color: node.style.iconColor)
                        TextBlock(node: node, env: env, inherited: inherited, showIcon: false)
                    }
                } else if let marker = node.listMarker {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(.system(size: size, weight: .semibold))
                            .foregroundStyle(JWColor.text)
                        TextBlock(node: node, env: env, inherited: inherited, showIcon: true)
                    }
                } else {
                    TextBlock(node: node, env: env, inherited: inherited, showIcon: true)
                }
            }
            .modifier(Decoration(style: node.style, env: env, centered: inherited.centered || node.style.centered))

            // Prompts such as "PARA MEDITAR: …?" have no box in the publication; add one.
            if reader.questionAfterNode[node.id] != nil {
                FieldBlock(reader: reader, questionID: reader.questionAfterNode[node.id],
                           size: env.base * inherited.scale, added: true)
                    .padding(.leading, node.style.indent)
            }
        }
    }

    @ViewBuilder
    private var imageNode: some View {
        if let path = node.image {
            PageImage(path: path, root: reader.root, alt: node.alt, small: node.style.widthFraction != nil)
                .contentShape(Rectangle())
                .onTapGesture { onImage(path) }
                .padding(.leading, node.style.indent)
        }
    }
}

/// A group of elements with the publication's styling: colored bands, rules, indents and icons.
struct ContainerBlock: View {
    let node: DocNode
    let env: PageEnv
    let inherited: Inherited
    let reader: ReaderModel
    let onImage: (String) -> Void

    init(node: DocNode, env: PageEnv, inherited: Inherited, reader: ReaderModel, onImage: @escaping (String) -> Void) {
        self.node = node
        self.env = env
        self.inherited = inherited
        self.reader = reader
        self.onImage = onImage
    }

    var body: some View {
        let inner = inherited.applying(node.style)
        if let picture = node.backgroundImage, node.backgroundOnTop {
            // "Picture A": the picture across the top, its label below.
            VStack(alignment: .leading, spacing: 8) {
                PageImage(path: picture, root: reader.root, alt: "")
                    .contentShape(Rectangle())
                    .onTapGesture { onImage(picture) }
                content(inner)
            }
            .padding(.leading, node.style.indent)
        } else if let picture = node.backgroundImage {
            // Questions printed over a light illustration: keep print colors so they stay readable.
            content(inner)
                .modifier(Decoration(style: node.style, env: env, centered: inner.centered))
                .background {
                    BackgroundPicture(path: picture, root: reader.root)
                        .padding(.horizontal, node.style.bleed ? -env.bleed : 0)
                }
                .environment(\.colorScheme, .light)
        } else {
            content(inner)
                .modifier(Decoration(style: node.style, env: env, centered: inner.centered))
        }
    }

    @ViewBuilder
    private func content(_ inner: Inherited) -> some View {
        let s = node.style
        if node.tag == "tr" {
            HStack(alignment: .top, spacing: 12) {
                ForEach(node.children) { child in
                    NodeView(node: child, env: env, inherited: inner, reader: reader, onImage: onImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let icon = s.icon, s.iconBackground != nil {
            // Section headers: a colored square with the section's icon, then the title.
            HStack(alignment: .center, spacing: env.base * 0.55) {
                IconTile(icon: icon, pubID: env.pubID, size: env.base * inner.scale * 0.95,
                         background: s.iconBackground, color: s.iconColor)
                stack(inner)
            }
        } else if let icon = s.icon {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                IconGlyph(icon: icon, pubID: env.pubID, size: env.base * inner.scale * 1.15,
                          color: inner.color.flatMap(JWColor.color) ?? JWColor.text)
                stack(inner)
            }
        } else if let marker = node.listMarker {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(size: env.base * inner.scale, weight: .semibold))
                    .foregroundStyle(JWColor.text)
                stack(inner)
            }
        } else {
            stack(inner)
        }
    }

    private func stack(_ inner: Inherited) -> some View {
        VStack(alignment: inner.centered ? .center : .leading, spacing: 0) {
            ForEach(Array(node.children.enumerated()), id: \.element.id) { i, child in
                NodeView(node: child, env: env, inherited: inner, reader: reader, onImage: onImage)
                    .padding(.top, PageLayout.gap(prev: i > 0 ? node.children[i - 1] : nil, node: child, env: env,
                                                  childGap: node.style.childGap))
            }
        }
        .frame(maxWidth: .infinity, alignment: inner.centered ? .center : .leading)
    }
}

/// Backgrounds, rules, padding and indents from the publication's design classes.
struct Decoration: ViewModifier {
    let style: NodeStyle
    let env: PageEnv
    let centered: Bool

    func body(content: Content) -> some View {
        let s = style
        let bg = s.background.flatMap(JWColor.background)
        let top = s.paddingTop > 0 ? s.paddingTop : (s.borderTop != nil ? env.base * 0.6 : (bg != nil ? env.base * 0.9 : 0))
        let bottom = s.paddingBottom > 0 ? s.paddingBottom : (s.borderBottom != nil ? env.base * 0.5 : (bg != nil ? env.base * 0.9 : 0))
        let lead = s.paddingLeading > 0 ? s.paddingLeading : (s.borderLeading != nil ? 12 : (bg != nil && !s.bleed ? 14 : 0))
        let trail = s.paddingTrailing > 0 ? s.paddingTrailing : (bg != nil && !s.bleed ? 14 : 0)
        content
            .padding(.top, top)
            .padding(.bottom, bottom)
            .padding(.leading, lead + (s.borderLeading?.width ?? 0))
            .padding(.trailing, trail)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .overlay(alignment: .top) { line(s.borderTop, horizontal: true) }
            .overlay(alignment: .bottom) { line(s.borderBottom, horizontal: true) }
            .overlay(alignment: .leading) { line(s.borderLeading, horizontal: false) }
            .background {
                if let bg {
                    if s.bleed {
                        bg.padding(.horizontal, -env.bleed)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg)
                    }
                }
            }
            .padding(.leading, s.indent)
    }

    @ViewBuilder
    private func line(_ border: JWBorder?, horizontal: Bool) -> some View {
        if let border {
            let color = border.color.flatMap(JWColor.color) ?? JWColor.border
            if horizontal {
                Rectangle().fill(color).frame(height: max(1, border.width))
            } else {
                Rectangle().fill(color).frame(width: max(1, border.width))
            }
        }
    }
}

// MARK: - Text

/// A paragraph, heading or caption, drawn as native text with the publication's inline styles.
struct TextBlock: View {
    let node: DocNode
    let env: PageEnv
    let inherited: Inherited
    let showIcon: Bool

    static func size(_ node: DocNode, env: PageEnv, inherited: Inherited) -> CGFloat {
        env.base * inherited.scale * (node.style.fontScale ?? roleScale(node))
    }

    static func roleScale(_ n: DocNode) -> CGFloat {
        if n.has("contextTtl") { return 0.85 }
        if n.has("pubRefs") { return 0.9 }
        if n.has("sw") { return 0.92 }
        switch n.role {
        case .h1: return 1.7
        case .h2: return 1.22
        case .h3: return 1.06
        case .h4: return 1
        case .caption, .note: return 0.84
        default: return 1
        }
    }

    var body: some View {
        let size = Self.size(node, env: env, inherited: inherited)
        let heading = PageLayout.isHeading(node)
        let centered = inherited.centered || node.style.centered
        let iconFont = showIcon ? node.style.icon.flatMap { _ in JWIcons.shared.font(pubID: env.pubID, size: size * 1.15) } : nil
        let attributed = PageText.attributed(node, size: size, env: env, heading: heading,
                                             iconFont: iconFont, showIcon: showIcon)
        let colorName = node.style.color ?? inherited.color
        let color = colorName.flatMap(JWColor.color)
            ?? ((node.role == .caption || node.role == .note) ? JWColor.subdued : JWColor.text)

        textView(attributed, symbol: showIcon && iconFont == nil ? node.style.icon : nil)
            .foregroundStyle(color)
            .tint(JWColor.link)
            .lineSpacing(size * (heading ? 0.14 : 0.36))
            .multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, env.bible && node.has("sz") ? env.base * 1.6 : 0)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = node.plain }
                ShareLink(item: node.plain)
            }
    }

    private func textView(_ a: AttributedString, symbol: String?) -> Text {
        if let symbol {
            return Text("\(Image(systemName: JWIcons.symbol(symbol)))  \(Text(a))")
        }
        return Text(a)
    }
}

/// Builds the styled text of a block: bold and italic runs, paragraph and verse numbers,
/// footnote marks, links, icons and search matches.
@MainActor
enum PageText {
    static func attributed(_ node: DocNode, size: CGFloat, env: PageEnv, heading: Bool,
                           iconFont: Font?, showIcon: Bool) -> AttributedString {
        let design: Font.Design = env.serif && !heading ? .serif : .default
        let blockBold = heading && !node.style.normalWeight
        var out = AttributedString()

        if showIcon, let icon = node.style.icon, let iconFont, let glyph = JWIcons.shared.glyph(icon, pubID: env.pubID) {
            var g = AttributedString(glyph)
            g.font = iconFont
            out += g
            var space = AttributedString("  ")
            space.font = .system(size: size)
            out += space
        }

        if env.bible, node.has("sb"), !node.runs.contains(where: \.chapterNum) {
            // Bible paragraphs start with an indent, as in JW Library.
            var indent = AttributedString("\u{2003}\u{2003}")
            indent.font = .system(size: size, design: design)
            out += indent
        }

        var runs = node.runs
        if node.role == .note {
            // Footnotes: the "^" back-link becomes a plain bold label ("Sal. 23:2") or disappears.
            var i = 0
            while i < runs.count, let l = runs[i].link, l.contains("source") {
                var t = runs[i].text.replacingOccurrences(of: "^", with: "")
                t = t.trimmingCharacters(in: .whitespaces)
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
                if let f = JWIcons.shared.font(pubID: env.pubID, size: size * 1.1),
                   let glyph = JWIcons.shared.glyph(icon, pubID: env.pubID) {
                    var g = AttributedString(glyph + " ")
                    g.font = f
                    out += g
                }
                continue
            }
            var a = AttributedString(r.text)
            var weight: Font.Weight = (blockBold || r.bold) && !r.normalWeight ? .bold : .regular
            if heading && node.style.normalWeight && !r.bold { weight = .regular }
            var runSize = size
            var runDesign = design
            var color: Color? = r.color.flatMap(JWColor.color)
            var offset: CGFloat = 0

            if r.chapterNum {
                runSize = size * 2.1
                weight = .bold
                runDesign = .default
                color = JWColor.verse
            } else if r.parNum {
                weight = .bold
                runSize = size * 0.86
                runDesign = .default
                color = JWColor.subdued
            } else if r.isNoteMark {
                runSize = size * 0.7
                offset = size * 0.38
                runDesign = .default
            } else if r.sup && (env.bible || r.bold) {
                // Verse numbers: bold, blue and on the line, like JW Library.
                weight = .bold
                runSize = size * 0.8
                runDesign = .default
                color = JWColor.verse
            } else if r.sup {
                runSize = size * 0.7
                offset = size * 0.35
            }

            var font = Font.system(size: runSize, weight: weight, design: runDesign)
            if r.italic { font = font.italic() }
            a.font = font
            if let color { a.foregroundColor = color }
            if offset != 0 { a.baselineOffset = offset }
            if let link = r.link, let url = ReaderModel.linkURL(link, text: r.text) {
                a.link = url
            } else if env.verseLinks, r.chapterNum || (r.sup && !r.isNoteMark),
                      let v = r.chapterNum ? 1 : Int(r.text.trimmingCharacters(in: .whitespaces)),
                      let url = URL(string: "perla://verse?v=\(v)") {
                a.link = url
                if env.notedVerses.contains(v) { a.underlineStyle = .single }
            }
            out += a
        }

        if let term = env.findTerm, !term.isEmpty {
            var start = out.startIndex
            while start < out.endIndex,
                  let r = out[start..<out.endIndex].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                out[r].backgroundColor = Color.accentColor.opacity(0.35)
                start = r.upperBound
            }
        }
        return out
    }
}

// MARK: - Icons

/// The colored square that marks a meeting section (gem, wheat, sheep).
struct IconTile: View {
    let icon: String
    let pubID: String
    let size: CGFloat
    let background: String?
    let color: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(2, size * 0.08), style: .continuous)
                .fill(background.flatMap(JWColor.color) ?? JWColor.subdued)
            IconGlyph(icon: icon, pubID: pubID, size: size * 0.7,
                      color: color.flatMap(JWColor.color) ?? .white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A JW icon from the publication's own icon font, or a close SF Symbol.
struct IconGlyph: View {
    let icon: String
    let pubID: String
    let size: CGFloat
    let color: Color

    var body: some View {
        if let font = JWIcons.shared.font(pubID: pubID, size: size),
           let glyph = JWIcons.shared.glyph(icon, pubID: pubID) {
            Text(glyph).font(font).foregroundStyle(color)
        } else {
            Image(systemName: JWIcons.symbol(icon))
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Answer boxes

/// The answer box under a question, where the publication has one, filled in as you read.
struct FieldBlock: View {
    @ObservedObject var reader: ReaderModel
    let questionID: String?
    let size: CGFloat
    /// True when the publication has no box here and the app added one.
    let added: Bool
    @FocusState private var focused: Bool

    init(reader: ReaderModel, questionID: String?, size: CGFloat, added: Bool) {
        _reader = ObservedObject(wrappedValue: reader)
        self.questionID = questionID
        self.size = size
        self.added = added
    }

    var body: some View {
        let state = questionID.flatMap { reader.answers[$0] } ?? AnswerState()
        VStack(alignment: .leading, spacing: 6) {
            if let id = questionID {
                TextField("Your answer", text: Binding(
                    get: { reader.answers[id]?.text ?? "" },
                    set: { reader.setAnswer(id, text: $0) }
                ), axis: .vertical)
                .font(.system(size: size * 0.95))
                .lineSpacing(size * 0.2)
                .foregroundStyle(JWColor.text)
                .focused($focused)
                .textInputAutocapitalization(.sentences)
                if state.note == "Imported", !focused {
                    Label("From your answers file", systemImage: "doc.text")
                        .font(.system(size: size * 0.64))
                        .foregroundStyle(JWColor.subdued)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: size * 2.4, alignment: .topLeading)
        .background(focused ? Color.accentColor.opacity(0.06) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.8) : JWColor.border,
                              style: StrokeStyle(lineWidth: focused ? 1.5 : 1, dash: added ? [5, 3] : []))
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .contextMenu {
            if !state.text.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = state.text }
            }
            if let id = questionID, state.note == "Your answer", reader.importedAnswer(id) != nil {
                Button("Use the imported answer", systemImage: "arrow.uturn.backward") { reader.clearAnswer(id) }
            }
        }
    }
}

/// Answer text with the "Ask yourself" and "Source" lines styled.
struct AnswerText: View {
    let text: String
    var size: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if Self.has(line, PubLanguage.sourcePrefixes) {
                    Text(line).font(font(0.78)).foregroundStyle(JWColor.subdued)
                } else if Self.has(line, PubLanguage.askPrefixes) {
                    Text(line).font(font(1)).italic()
                } else {
                    Text(line).font(font(1))
                }
            }
        }
        .lineSpacing((size ?? 17) * 0.22)
        .foregroundStyle(JWColor.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func font(_ scale: CGFloat) -> Font {
        if let size { return .system(size: size * scale) }
        return scale < 0.9 ? .caption : .body
    }

    private var lines: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func has(_ line: String, _ prefixes: [String]) -> Bool {
        let l = line.lowercased()
        return prefixes.contains { l.hasPrefix($0.lowercased()) }
    }
}

// MARK: - Pictures

/// Pixel sizes of pictures, read from the file header so the page doesn't jump while they load.
@MainActor
enum ImageSizes {
    private static var cache: [String: CGSize] = [:]

    static func size(_ url: URL) -> CGSize? {
        if let s = cache[url.path] { return s }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let s = CGSize(width: w, height: h)
        cache[url.path] = s
        return s
    }
}

/// A picture from the publication, scaled to the width of the column.
/// A picture filling the space behind an element.
struct BackgroundPicture: View {
    let path: String
    let root: URL
    @State private var image: UIImage?

    var body: some View {
        Color(.white)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: path) {
                let url = root.appendingPathComponent(path)
                image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
            }
    }
}

struct PageImage: View {
    let path: String
    let root: URL
    let alt: String
    let small: Bool
    @State private var image: UIImage?

    init(path: String, root: URL, alt: String, small: Bool = false) {
        self.path = path
        self.root = root
        self.alt = alt
        self.small = small
    }

    var body: some View {
        let url = root.appendingPathComponent(path)
        let px = ImageSizes.size(url)
        let ratio = px.map { $0.width / $0.height } ?? 1.6
        let tiny = small || (px.map { $0.width < 160 } ?? false)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(ratio, contentMode: .fit)
            } else {
                Rectangle()
                    .fill(JWColor.card)
                    .aspectRatio(ratio, contentMode: .fit)
            }
        }
        .frame(maxWidth: tiny ? min(120, (px?.width ?? 240) / 2) : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: tiny ? 0 : 3, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(alt)
        .task(id: path) {
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let img = UIImage(contentsOfFile: url.path) else { return nil }
                return img.preparingForDisplay() ?? img
            }.value
        }
    }
}

/// Small, downsampled pictures for lists.
struct Thumbnail: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    @State private var image: UIImage?

    init(url: URL?, width: CGFloat, height: CGFloat) {
        self.url = url
        self.width = width
        self.height = height
    }

    var body: some View {
        ZStack {
            Rectangle().fill(JWColor.card)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if url == nil {
                Image(systemName: "doc.text")
                    .font(.system(size: min(width, height) * 0.4))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: url) {
            guard let url else { return }
            let side = max(width, height) * 3
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: side,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
        }
    }
}

struct ZoomItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Full-screen picture with pinch to zoom.
struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1

    init(url: URL) {
        self.url = url
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    if let img = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width * zoom, height: geo.size.height * zoom)
                    }
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { v in zoom = min(5, max(1, lastZoom * v.magnification)) }
                        .onEnded { _ in lastZoom = zoom }
                )
                .onTapGesture(count: 2) {
                    withAnimation { zoom = zoom > 1 ? 1 : 2.5 }
                    lastZoom = zoom
                }
            }
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - References

/// The body of a verse, footnote or cited publication, drawn natively, with what you can do with it
/// (open it in the full publication, read it as a page, play the song) in a bar along the bottom.
struct ReferenceContent: View {
    let sheet: ReferenceSheet
    let reader: ReaderModel
    let base: CGFloat

    var body: some View {
        let env = PageEnv(base: base, serif: sheet.scripture, bible: sheet.scripture, pubID: reader.pub.id,
                          bleed: 20, findTerm: nil, doc: "ref-\(sheet.id)")
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if sheet.nodes.isEmpty {
                    Text(sheet.text)
                        .font(.system(size: base, design: sheet.scripture ? .serif : .default))
                        .lineSpacing(base * 0.36)
                        .foregroundStyle(JWColor.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(sheet.nodes.enumerated()), id: \.offset) { i, n in
                        NodeView(node: n, env: env, inherited: Inherited(), reader: reader, onImage: { _ in })
                            .padding(.top, i == 0 ? 0 : PageLayout.gap(prev: sheet.nodes[i - 1], node: n, env: env))
                    }
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if sheet.media != nil || sheet.page != nil || sheet.open != nil {
                actions
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let song = sheet.media {
                Button {
                    reader.play(song)
                } label: {
                    Label("Play song", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            // The full publication first (it has the pictures); the text-only copy as a fallback.
            if let ref = sheet.open {
                Button {
                    reader.openRef(ref)
                } label: {
                    Label(ref.openTitle, systemImage: ref.isBible ? "book.closed" : "books.vertical")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if let page = sheet.page {
                Button {
                    reader.readAsPage(page)
                } label: {
                    Label("Read as a page", systemImage: "doc.text").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// A verse, footnote or cited publication in a half-height sheet (folded). The page stays visible and
/// can still be scrolled behind it.
struct ReferenceView: View {
    let sheet: ReferenceSheet
    let reader: ReaderModel
    let base: CGFloat
    @Environment(\.dismiss) private var dismiss

    init(sheet: ReferenceSheet, reader: ReaderModel, base: CGFloat) {
        self.sheet = sheet
        self.reader = reader
        self.base = base
    }

    var body: some View {
        NavigationStack {
            ReferenceContent(sheet: sheet, reader: reader, base: base)
                .navigationTitle(sheet.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .environment(\.openURL, OpenURLAction { url in reader.handleLink(url) })
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
    }
}

/// The same reference in a panel beside the page (unfolded): the page stays where you were reading.
struct ReferencePanel: View {
    let sheet: ReferenceSheet
    @ObservedObject var reader: ReaderModel
    let base: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(sheet.title.isEmpty ? L("Reference") : sheet.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Close", systemImage: "xmark") { reader.reference = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ReferenceContent(sheet: sheet, reader: reader, base: base)
                .id(sheet.id)
        }
        .background(Color(.secondarySystemBackground))
    }
}
