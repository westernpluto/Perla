import SwiftUI
import CoreText

/// The publications' own design tokens (the "du-" / "dc-" classes in jw.org's EPUB files),
/// turned into native colors, spacing and icons. Light values come from the publication's
/// stylesheet; dark values are tuned to match JW Library's dark theme.
enum JWColor {
    private static let table: [String: (light: UInt32, dark: UInt32)] = [
        "teal-600": (0x3C7F8B, 0x3C8692), "teal-700": (0x2A6B77, 0x6DB8C4),
        "gold-600": (0xD68F00, 0xD68F00), "gold-700": (0x9B6D17, 0xF2B634),
        "maroon-600": (0x942926, 0xE0675F), "maroon-800": (0x680C0A, 0xE58A84),
        "red-600": (0xBF2F13, 0xC4361A), "sage-600": (0x5E8C6B, 0x5E8C6B),
        "coolGray-500": (0x597477, 0xA9BEC0), "coolGray-600": (0x476467, 0xB7CACC),
        "coolGray-700": (0x375255, 0xE9EEEE), "gray-800": (0x3C3C3C, 0xE8E8E8),
        "textDefault": (0x292929, 0xE8E8E8), "textSubdued": (0x626262, 0xA6A6A6),
        "bgSecondary": (0xF1F1F1, 0x232323), "borderDefault": (0xA7A7A7, 0x484848),
        "black": (0x121212, 0xF2F2F2), "white": (0xFFFFFF, 0xFFFFFF),
        "amber-600": (0xB47119, 0xE3A04A), "orange-400": (0xFF862E, 0xFF9A50),
        "orange-600": (0xD65A00, 0xF08A3C), "orange-700": (0xAC4700, 0xF29A5A),
        "purple-800": (0x522149, 0xD9A6CC), "purple-100": (0xE6CDE0, 0x3A2235),
        "gold-100": (0xFFEEB8, 0x3B3220), "cyan-100": (0xBCE8FF, 0x1E3340),
        "green-100": (0xD3F2B9, 0x24331B), "warmGray-50": (0xF0EEEA, 0x262523),
        "link": (0x3B5E9E, 0x9DB4E8), "verse": (0x4A6DA7, 0x8FA9E0),
        "cyan-50": (0xE8F6FD, 0x1B2A31), "warmGray-600": (0x6B635B, 0x4A443F),
    ]

    static func color(_ name: String) -> Color? {
        guard let pair = table[name] else { return nil }
        return Color(UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? pair.dark : pair.light)
        })
    }

    /// A background color. White and black panels in print become the page's own background in dark
    /// mode, so text never sits on a bright block.
    static func background(_ name: String) -> Color? {
        switch name {
        case "white": return Color(.systemBackground)
        case "black": return Color(UIColor(hex: 0x1C1C1E))
        default: return color(name)
        }
    }

    static var text: Color { color("textDefault") ?? .primary }
    static var subdued: Color { color("textSubdued") ?? .secondary }
    static var link: Color { color("link") ?? .blue }
    static var verse: Color { color("verse") ?? .blue }
    static var border: Color { color("borderDefault") ?? .gray }
    static var card: Color { color("bgSecondary") ?? Color(.secondarySystemBackground) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

struct JWBorder: Hashable {
    var width: CGFloat
    var color: String?
}

/// Visual style of one element, read from its classes.
struct NodeStyle: Hashable {
    var color: String?
    var background: String?
    var borderTop: JWBorder?
    var borderBottom: JWBorder?
    var borderLeading: JWBorder?
    var marginTop: CGFloat?
    var marginBottom: CGFloat?
    /// Space the element puts between its own children ("du-margin-children--N").
    var childGap: CGFloat?
    var paddingTop: CGFloat = 0
    var paddingBottom: CGFloat = 0
    var paddingLeading: CGFloat = 0
    var paddingTrailing: CGFloat = 0
    var indent: CGFloat = 0
    var fontScale: CGFloat?
    var normalWeight = false
    var centered = false
    var bleed = false
    var widthFraction: CGFloat?
    var icon: String?
    var iconBackground: String?
    var iconColor: String?
    var listNone = false

    var hasVisual: Bool {
        background != nil || borderTop != nil || borderBottom != nil || borderLeading != nil
            || icon != nil || indent > 0 || paddingLeading > 0 || paddingTop > 0 || paddingBottom > 0
            || fontScale != nil || color != nil || centered || bleed
    }

    static func parse(_ classes: [String]) -> NodeStyle {
        var s = NodeStyle()
        var borderWidth: CGFloat = 1
        var borderColor: String?
        var sides: [String] = []
        for c in classes where c.hasPrefix("du-") || c.hasPrefix("dc-") {
            if c.contains("desktopOnly") { continue }
            if let v = value(c, "du-color--") { s.color = v }
            else if let v = value(c, "du-bgColor--") { s.background = v }
            else if let v = value(c, "du-borderColor--") { borderColor = v }
            else if let v = value(c, "du-borderWidth--") { borderWidth = CGFloat(Double(v) ?? 1) }
            else if c.hasPrefix("du-borderStyle-"), c.hasSuffix("--solid") {
                sides.append(String(c.dropFirst("du-borderStyle-".count).dropLast("--solid".count)))
            }
            else if let v = value(c, "du-margin-top--") { s.marginTop = units(v) }
            else if let v = value(c, "du-margin-bottom--") { s.marginBottom = units(v) }
            else if let v = value(c, "du-margin-vertical--") { s.marginTop = units(v); s.marginBottom = units(v) }
            else if let v = value(c, "du-margin-inlineStart--") { s.indent = units(v) }
            else if let v = value(c, "du-margin-children--") { s.childGap = units(v) }
            else if let v = value(c, "du-margin-children-vertical--") { s.childGap = units(v) }
            else if let v = value(c, "du-margin-children-bottom--") { s.childGap = units(v) }
            else if let v = value(c, "du-padding-top--") { s.paddingTop = units(v) }
            else if let v = value(c, "du-padding-bottom--") { s.paddingBottom = units(v) }
            else if let v = value(c, "du-padding-vertical--") { s.paddingTop = units(v); s.paddingBottom = units(v) }
            else if let v = value(c, "du-padding-inlineStart--") { s.paddingLeading = units(v) }
            else if let v = value(c, "du-padding-horizontal--") { s.paddingLeading = units(v); s.paddingTrailing = units(v) }
            else if let v = value(c, "du-fontSize--") { s.fontScale = fontScale(v) }
            else if c == "du-fontWeight--normal" { s.normalWeight = true }
            else if c == "du-textAlign--center" { s.centered = true }
            else if c == "du-listStyleType--none" { s.listNone = true }
            else if c == "du-width--oneSixth" { s.widthFraction = 1.0 / 6 }
            else if c == "dc-bleedToArticleEdge" { s.bleed = true }
            else if let v = value(c, "dc-icon-bgColor--") { s.iconBackground = v }
            else if let v = value(c, "dc-icon-color--") { s.iconColor = v }
            else if let v = value(c, "dc-icon--") { s.icon = v }
        }
        for side in sides {
            let b = JWBorder(width: borderWidth, color: borderColor)
            switch side {
            case "top": s.borderTop = b
            case "bottom": s.borderBottom = b
            case "inlineStart": s.borderLeading = b
            default: break
            }
        }
        return s
    }

    private static func value(_ c: String, _ prefix: String) -> String? {
        c.hasPrefix(prefix) ? String(c.dropFirst(prefix.count)) : nil
    }

    /// The design system's spacing scale: step N is N × 4 points.
    private static func units(_ v: String) -> CGFloat {
        CGFloat(Double(v) ?? 0) * 4
    }

    private static func fontScale(_ v: String) -> CGFloat? {
        switch v {
        case "base": return 1
        case "baseMinus1": return 0.83
        case "baseMinus2": return 0.69
        // The web scale (1.205, 1.452, 1.75, 2.108) is a little large on a phone; JW Library
        // draws headings closer to these.
        case "basePlus1": return 1.15
        case "basePlus2": return 1.32
        case "basePlus3": return 1.55
        case "basePlus4": return 1.8
        default: return nil
        }
    }
}

/// JW icon glyphs, drawn with the icon font that ships inside each publication.
@MainActor
final class JWIcons {
    static let shared = JWIcons()
    private var fontNames: [String: String] = [:]
    private var glyphs: [String: [String: String]] = [:]

    private static let fallback: [String: String] = [
        "gem": "\u{e720}", "wheat": "\u{e898}", "sheep": "\u{e800}", "music": "\u{e78e}",
    ]

    /// Registers the publication's icon font (once) and reads its glyph table.
    func prepare(root: URL, pubID: String) {
        guard fontNames[pubID] == nil else { return }
        let fonts = root.appendingPathComponent("OEBPS/fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        guard let iconFont = files.first(where: { $0.lastPathComponent.hasPrefix("jw-icons-all") }) else {
            fontNames[pubID] = ""
            return
        }
        var name = ""
        if let descs = CTFontManagerCreateFontDescriptorsFromURL(iconFont as CFURL) as? [CTFontDescriptor],
           let first = descs.first,
           let n = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String {
            name = n
        }
        _ = CTFontManagerRegisterFontsForURL(iconFont as CFURL, .process, nil)
        fontNames[pubID] = name

        var table = Self.fallback
        if let css = try? String(contentsOf: root.appendingPathComponent("OEBPS/css/epubs.css"), encoding: .utf8),
           let re = try? NSRegularExpression(pattern: "\\.dc-icon--(gem|wheat|sheep|music)::before\\{content:\"\\\\([0-9a-fA-F]+)\"") {
            let ns = css as NSString
            for m in re.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1))
                if let v = UInt32(ns.substring(with: m.range(at: 2)), radix: 16), let scalar = Unicode.Scalar(v) {
                    table[key] = String(Character(scalar))
                }
            }
        }
        glyphs[pubID] = table
    }

    func font(pubID: String, size: CGFloat) -> Font? {
        guard let name = fontNames[pubID], !name.isEmpty else { return nil }
        return .custom(name, fixedSize: size)
    }

    func glyph(_ icon: String, pubID: String) -> String? {
        glyphs[pubID]?[icon] ?? Self.fallback[icon]
    }

    /// SF Symbol stand-ins if the icon font can't be loaded.
    static func symbol(_ icon: String) -> String {
        switch icon {
        case "gem": return "diamond"
        case "wheat": return "leaf"
        case "sheep": return "person.2"
        case "music": return "music.note"
        default: return "circle"
        }
    }
}
