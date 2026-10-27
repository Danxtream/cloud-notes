import Foundation

/// Samsung Notes' styled text: the decoded `<text>` of a title or body object, Base64 UTF-8 runs between `<?a …?>`
/// markers. A marker's tokens open a style where it stands (`'span/bold'='1,True'`) or close one (`'span/bold'`).
/// In every note checked, a key is never opened while already open and every key is closed by the end. Samsung
/// counts positions in UTF-16 units. The canonical form below reproduces Samsung's bytes exactly, so a note that
/// parses can be written back unchanged; anything else throws, and callers fall back to plain text.
struct RichText: Equatable {
    struct Token: Equatable {
        var key: String
        /// The opened value, or nil for a token that closes `key`.
        var value: String?
    }
    enum Item: Equatable { case text(String), marker([Token]) }
    var items: [Item]

    init(items: [Item]) { self.items = items }

    /// Parses a `<text>` value (Base64 of the marker stream).
    init(encoded: String) throws {
        guard !encoded.isEmpty else { self.init(items: []); return }
        guard let data = Data(base64Encoded: encoded), let stream = String(data: data, encoding: .utf8) else { throw Self.unsupported }
        var items: [Item] = []
        var rest = Substring(stream)
        while !rest.isEmpty {
            if rest.hasPrefix("<?a ") {
                guard let end = rest.range(of: "?>") else { throw Self.unsupported }
                items.append(.marker(try Self.tokens(String(rest[rest.index(rest.startIndex, offsetBy: 4)..<end.lowerBound]))))
                rest = rest[end.upperBound...]
            } else {
                let end = rest.range(of: "<?")?.lowerBound ?? rest.endIndex
                guard let run = Data(base64Encoded: String(rest[..<end])), let text = String(data: run, encoding: .utf8) else { throw Self.unsupported }
                items.append(.text(text))
                rest = rest[end...]
            }
        }
        self.init(items: items)
        guard self.encoded == encoded else { throw Self.unsupported }
    }

    static let unsupported = NotesError.message("This text uses styling this version cannot read. Its original data has been retained.")
    private static let tokenPattern = try! NSRegularExpression(pattern: "'((?:[^']|'')*)'(?:='((?:[^']|'')*)')?")

    private static func tokens(_ body: String) throws -> [Token] {
        let range = NSRange(body.startIndex..., in: body)
        let tokens = tokenPattern.matches(in: body, range: range).map { match in
            Token(key: String(body[Range(match.range(at: 1), in: body)!]),
                  value: match.range(at: 2).location == NSNotFound ? nil : String(body[Range(match.range(at: 2), in: body)!]))
        }
        guard !tokens.isEmpty else { throw unsupported }
        return tokens
    }

    /// The `<text>` value in Samsung's form.
    var encoded: String {
        if items.isEmpty { return "" }
        let stream = items.map { item -> String in
            switch item {
            case .text(let text): return Data(text.utf8).base64EncodedString()
            case .marker(let tokens): return "<?a " + tokens.map { "'\($0.key)'" + ($0.value.map { "='\($0)'" } ?? "") }.joined(separator: " ") + "?>"
            }
        }.joined()
        return Data(stream.utf8).base64EncodedString()
    }

    var plain: String { items.map { if case .text(let text) = $0 { return text } else { return "" } }.joined() }

    /// The text in pieces, each with the styles open over it (key → value). Pieces are split only where markers stand.
    var runs: [(text: String, styles: [String: String])] {
        var open: [String: String] = [:], runs: [(text: String, styles: [String: String])] = []
        for item in items {
            switch item {
            case .marker(let tokens): for token in tokens { open[token.key] = token.value }
            case .text(let text): runs.append((text, open))
            }
        }
        return runs
    }
}

/// What a style value means. Span values are `flag,property`, where the flag is Samsung's span expansion flag.
enum RichStyle {
    /// The property part of a span value: "1,16.0" → "16.0".
    static func property(_ value: String?) -> String? {
        guard let value, let comma = value.firstIndex(of: ",") else { return nil }
        return String(value[value.index(after: comma)...])
    }
    static func isOn(_ value: String?) -> Bool { property(value)?.lowercased() == "true" }
    /// A colour value ("1,-14342875", a signed ARGB integer) as 0xAARRGGBB, or nil for none (0) and malformed values.
    static func argb(_ value: String?) -> UInt32? {
        guard let number = property(value).flatMap({ Int64($0) }), number != 0, let bits = UInt32(exactly: number & 0xFFFF_FFFF) else { return nil }
        return bits
    }
    static func fontSize(_ value: String?) -> Double? { property(value).flatMap(Double.init) }
    /// Near-black greys are Samsung's default text colours (#000000, #030303, #252525), shown in the reader's own text colour.
    static func isDefaultTextColor(_ argb: UInt32) -> Bool {
        let r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF
        return r < 0x40 && g < 0x40 && b < 0x40 && max(r, g, b) - min(r, g, b) < 0x08
    }
    static func hex(_ argb: UInt32) -> String {
        argb >> 24 == 0xFF ? String(format: "#%06X", argb & 0xFF_FFFF) : String(format: "#%08X", argb)
    }

    /// Samsung Notes' bullet kinds, in the order of its `paragraph/bullet` type numbers.
    enum Bullet: Int { case none, arrow, checkbox, diamond, number, circledNumber, letter, roman, dot, circle, capitalLetter, square, whiteSquare }
    /// A `paragraph/bullet` value ("type,number" or "2,true" for a checkbox) as a kind and its number or checked state.
    static func bullet(_ value: String?) -> (kind: Bullet, number: Int, checked: Bool)? {
        guard let parts = value?.split(separator: ",", omittingEmptySubsequences: false), parts.count >= 2,
              let type = Int(parts[0]), let kind = Bullet(rawValue: type), kind != .none else { return nil }
        let second = parts[1].trimmingCharacters(in: .whitespaces)
        return (kind, Int(second) ?? 0, second.lowercased() == "true")
    }
    /// The list label Samsung Notes draws for a bullet, e.g. "•", "3.", "c.", "iv.", "③".
    static func label(_ bullet: (kind: Bullet, number: Int, checked: Bool)) -> String {
        let n = max(bullet.number, 1)
        switch bullet.kind {
        case .none: return ""
        case .arrow: return "➤"
        case .checkbox: return bullet.checked ? "☑" : "☐"
        case .diamond: return "◆"
        case .number: return "\(n)."
        case .circledNumber: return n <= 20 ? String(UnicodeScalar(0x245F + UInt32(n))!) : "(\(n))"
        case .letter: return letters(n).lowercased() + "."
        case .capitalLetter: return letters(n) + "."
        case .roman: return roman(n).lowercased() + "."
        case .dot: return "•"
        case .circle: return "◦"
        case .square: return "▪"
        case .whiteSquare: return "▫"
        }
    }
    private static func letters(_ n: Int) -> String {
        var n = n, out = ""
        while n > 0 { n -= 1; out = String(UnicodeScalar(65 + UInt32(n % 26))!) + out; n /= 26 }
        return out
    }
    private static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (value, numeral) in table { while n >= value { out += numeral; n -= value } }
        return out
    }
}

extension RichText {
    /// The text as Markdown-style text, for reading in a terminal or by an assistant: `**bold**`, `*italic*`,
    /// `~~strikethrough~~`, `<u>underline</u>`, list prefixes (`- `, `2. `, `- [ ] `, `- [x] `, `c. `) and
    /// `{color=#RRGGBB size=20 highlight=#RRGGBB}…{/}` for colour, size and highlight. Samsung's default text colours and
    /// the text's most common size are left out. Characters that would read as markup are escaped with a backslash.
    var markdown: String {
        let runs = self.runs
        var sizes: [Double: Int] = [:]
        for run in runs { if let size = RichStyle.fontSize(run.styles["span/fontSize"]) { sizes[size, default: 0] += run.text.utf16.count } }
        let baseSize = sizes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        var lines: [String] = [], pieces: [(String, [String: String])] = [], paragraph: [String: String]? = nil
        for run in runs {
            var text = Substring(run.text)
            while !text.isEmpty {
                // A paragraph's styles are the ones open at its first character (its newline, when it is empty).
                if paragraph == nil { paragraph = run.styles }
                guard let newline = text.firstIndex(of: "\n") else { pieces.append((String(text), run.styles)); break }
                pieces.append((String(text[..<newline]), run.styles))
                lines.append(Self.markdownLine(paragraph ?? [:], pieces, baseSize: baseSize)); pieces = []; paragraph = nil
                text = text[text.index(after: newline)...]
            }
        }
        lines.append(Self.markdownLine(paragraph ?? [:], pieces, baseSize: baseSize))
        return lines.joined(separator: "\n")
    }

    private static func markdownLine(_ paragraph: [String: String], _ pieces: [(String, [String: String])], baseSize: Double?) -> String {
        var merged: [(text: String, marks: Marks)] = []
        for (text, styles) in pieces where !text.isEmpty {
            let marks = Marks(styles, baseSize: baseSize)
            if let last = merged.last, last.marks == marks { merged[merged.count - 1].text += text } else { merged.append((text, marks)) }
        }
        var line = merged.map { $0.marks.wrap(escaped($0.text)) }.joined()
        guard let bullet = RichStyle.bullet(paragraph["paragraph/bullet"]) else {
            if line.hasPrefix("- ") || line.hasPrefix("+ ") || line.range(of: "^[0-9]+\\. ", options: .regularExpression) != nil { line = "\\" + line }
            return line
        }
        switch bullet.kind {
        case .checkbox: return (bullet.checked ? "- [x] " : "- [ ] ") + line
        case .number: return "\(max(bullet.number, 1)). " + line
        case .letter, .capitalLetter, .roman, .circledNumber: return RichStyle.label(bullet) + " " + line
        default: return "- " + line
        }
    }

    private static func escaped(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\\", with: "\\\\")
        for mark in ["*", "~", "{", "}"] { out = out.replacingOccurrences(of: mark, with: "\\" + mark) }
        return out.replacingOccurrences(of: "<u>", with: "\\<u>").replacingOccurrences(of: "</u>", with: "\\</u>")
    }

    /// The inline styles Markdown-style text shows for a run.
    private struct Marks: Equatable {
        var bold: Bool, italic: Bool, underline: Bool, strike: Bool, tag: String
        init(_ styles: [String: String], baseSize: Double?) {
            bold = RichStyle.isOn(styles["span/bold"]); italic = RichStyle.isOn(styles["span/italic"])
            underline = RichStyle.isOn(styles["span/underline"]); strike = RichStyle.isOn(styles["span/strikethrough"])
            var parts: [String] = []
            if let color = RichStyle.argb(styles["span/foregroundColor"]), !RichStyle.isDefaultTextColor(color) { parts.append("color=" + RichStyle.hex(color)) }
            if let size = RichStyle.fontSize(styles["span/fontSize"]), size != baseSize { parts.append("size=" + (size == size.rounded() ? String(Int(size)) : String(size))) }
            if let highlight = RichStyle.argb(styles["span/backgroundColor"]) { parts.append("highlight=" + RichStyle.hex(highlight)) }
            tag = parts.joined(separator: " ")
        }
        /// `text` wrapped in its markup, with spaces at either end kept outside it.
        func wrap(_ text: String) -> String {
            let lead = text.prefix { $0 == " " || $0 == "\t" }
            guard lead.count < text.count else { return text }
            let trail = String(text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            let core = text.dropFirst(lead.count).dropLast(trail.count)
            var open = "", close = ""
            if !tag.isEmpty { open += "{\(tag)}"; close = "{/}" + close }
            if underline { open += "<u>"; close = "</u>" + close }
            if strike { open += "~~"; close = "~~" + close }
            if italic { open += "*"; close = "*" + close }
            if bold { open += "**"; close = "**" + close }
            return lead + open + core + close + trail
        }
    }
}
