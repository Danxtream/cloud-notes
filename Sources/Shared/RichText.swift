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
    var markdown: String { markdownParagraphs.map(\.line).joined(separator: "\n") }

    /// Each paragraph's Markdown-style line and its runs (newline excluded).
    private var markdownParagraphs: [(line: String, runs: [RichRun])] {
        let runs = self.runs
        var sizes: [Double: Int] = [:]
        for run in runs { if let size = RichStyle.fontSize(run.styles["span/fontSize"]) { sizes[size, default: 0] += run.text.utf16.count } }
        let baseSize = sizes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        var result: [(line: String, runs: [RichRun])] = [], pieces: [(String, [String: String])] = [], paragraph: [String: String]? = nil
        func finish() {
            let styles = paragraph ?? [:]
            result.append((Self.markdownLine(styles, pieces, baseSize: baseSize),
                           pieces.isEmpty ? [RichRun(text: "", styles: styles)] : pieces.map { RichRun(text: $0.0, styles: $0.1) }))
            pieces = []; paragraph = nil
        }
        for run in runs {
            var text = Substring(run.text)
            while !text.isEmpty {
                // A paragraph's styles are the ones open at its first character (its newline, when it is empty).
                if paragraph == nil { paragraph = run.styles }
                guard let newline = text.firstIndex(of: "\n") else { pieces.append((String(text), run.styles)); break }
                pieces.append((String(text[..<newline]), run.styles))
                finish()
                text = text[text.index(after: newline)...]
            }
        }
        finish()
        return result
    }

    /// The runs for Markdown-style text (see `markdown`), as `edit --markdown` writes it. A line that equals a line of
    /// this text's Markdown keeps that paragraph's exact styles; other lines get this text's common styles plus their
    /// markup. Literal `*`, `~`, `{`, `}` and `\` need a backslash.
    func runs(fromMarkdown markdown: String) -> [RichRun] {
        let old = markdownParagraphs, new = markdown.components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old.map(\.line)) {
            switch change { case .remove(let offset, _, _): removed.insert(offset); case .insert(let offset, _, _): inserted.insert(offset) }
        }
        let kept = Dictionary(uniqueKeysWithValues: zip(new.indices.filter { !inserted.contains($0) }, old.indices.filter { !removed.contains($0) }))
        let common = items.isEmpty ? Self.typingStyles : commonStyles
        var runs: [RichRun] = []
        for (index, line) in new.enumerated() {
            var paragraph = kept[index].map { old[$0].runs } ?? Self.parseMarkdownLine(line, defaults: common)
            if index < new.count - 1 { paragraph[paragraph.count - 1].text += "\n" }
            runs += paragraph
        }
        return Self.numbered(runs)
    }

    static func parseMarkdownLine(_ source: String, defaults: [String: String]) -> [RichRun] {
        var line = Substring(source), paragraph = defaults.filter { $0.key.hasPrefix("paragraph/") }
        let base = defaults.filter { !$0.key.hasPrefix("paragraph/") }
        if line.hasPrefix("- [ ] ") { paragraph["paragraph/bullet"] = "2,false"; line = line.dropFirst(6) }
        else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { paragraph["paragraph/bullet"] = "2,true"; line = line.dropFirst(6) }
        else if line.hasPrefix("- ") { paragraph["paragraph/bullet"] = "8,0"; line = line.dropFirst(2) }
        else if let match = line.range(of: "^[0-9]+\\. ", options: .regularExpression) {
            paragraph["paragraph/bullet"] = "4," + line[match].dropLast(2); line = line[match.upperBound...]
        }
        var bold = false, italic = false, strike = false, underline = false, tags: [[String: String]] = []
        var runs: [RichRun] = [], buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            var styles = base.merging(paragraph) { $1 }
            for tag in tags { styles.merge(tag) { $1 } }
            if bold { styles["span/bold"] = "1,True" }
            if italic { styles["span/italic"] = "1,True" }
            if underline { styles["span/underline"] = "1,True" }
            if strike { styles["span/strikethrough"] = "1,True" }
            runs.append(RichRun(text: buffer, styles: styles)); buffer = ""
        }
        while let first = line.first {
            if first == "\\", line.count >= 2 { buffer.append(line[line.index(after: line.startIndex)]); line = line.dropFirst(2) }
            else if line.hasPrefix("**") { flush(); bold.toggle(); line = line.dropFirst(2) }
            else if line.hasPrefix("~~") { flush(); strike.toggle(); line = line.dropFirst(2) }
            else if first == "*" { flush(); italic.toggle(); line = line.dropFirst() }
            else if line.hasPrefix("<u>") { flush(); underline = true; line = line.dropFirst(3) }
            else if line.hasPrefix("</u>") { flush(); underline = false; line = line.dropFirst(4) }
            else if line.hasPrefix("{/}") { flush(); _ = tags.popLast(); line = line.dropFirst(3) }
            else if first == "{", let close = line.firstIndex(of: "}"), let tag = markdownTag(line[line.index(after: line.startIndex)..<close]) {
                flush(); tags.append(tag); line = line[line.index(after: close)...]
            } else { buffer.append(first); line = line.dropFirst() }
        }
        flush()
        return runs.isEmpty ? [RichRun(text: "", styles: base.merging(paragraph) { $1 })] : runs
    }

    /// The styles of a `{color=#RRGGBB size=20 highlight=#RRGGBB}` tag, or nil when it is not one.
    private static func markdownTag(_ body: Substring) -> [String: String]? {
        var styles: [String: String] = [:]
        for part in body.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            func argb(_ hex: String) -> String? {
                guard hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16), [6, 8].contains(hex.count - 1) else { return nil }
                return "1," + String(Int32(bitPattern: hex.count == 7 ? value | 0xFF00_0000 : value))
            }
            switch pair[0] {
            case "color": guard let value = argb(pair[1]) else { return nil }; styles["span/foregroundColor"] = value
            case "highlight": guard let value = argb(pair[1]) else { return nil }; styles["span/backgroundColor"] = value
            case "size": guard let size = Double(pair[1]), size > 0, size <= 200 else { return nil }; styles["span/fontSize"] = String(format: "1,%.1f", size)
            default: return nil
            }
        }
        return styles.isEmpty ? nil : styles
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

/// A piece of text and the Samsung styles over it (`RichText` keys → values), the form the editor works in.
struct RichRun: Equatable {
    var text: String
    var styles: [String: String]
}

extension RichText {
    /// The styles Samsung Notes always writes, with the values `StyledText.encode` uses when a note has none of its own.
    static let defaultStyles = ["paragraph/alignment": "0", "paragraph/parsingState": "False", "span/fontSize": "1,12", "span/foregroundColor": "1,-14342875"]
    /// Styles for text typed into an empty note: Samsung Notes' default size (16) and text colour.
    static let typingStyles = defaultStyles.merging(["span/fontSize": "1,16.0"]) { $1 }
    /// Bookkeeping Samsung writes around the text rather than over it.
    static let sectionKey = "sectionData/sectionData"

    /// The text as runs, with `sectionData` left out, empty runs dropped and neighbours with the same styles joined: two
    /// texts with the same runs look the same, whatever markers they were written with.
    var styledRuns: [RichRun] {
        var result: [RichRun] = []
        for run in runs where !run.text.isEmpty {
            var styles = run.styles; styles[Self.sectionKey] = nil
            if let last = result.last, last.styles == styles { result[result.count - 1].text += run.text }
            else { result.append(RichRun(text: run.text, styles: styles)) }
        }
        return result
    }

    /// The most common value of each always-written style in this text, for text typed where no style is set.
    var commonStyles: [String: String] {
        var counts: [String: [String: Int]] = [:]
        for run in runs { for key in Self.defaultStyles.keys { if let value = run.styles[key] { counts[key, default: [:]][value, default: 0] += run.text.utf16.count } } }
        return Self.defaultStyles.merging(counts.compactMapValues { $0.max { $0.value < $1.value }?.key }) { $1 }
    }

    /// `runs` split after every newline, with each paragraph's styles taken from its first piece, `sectionData` left out,
    /// empty runs dropped and, unless `split`, neighbours with the same styles joined. Samsung Notes writes a line's
    /// newline with either its own or the next line's paragraph styles, so two texts that differ only there are the same.
    static func normalized(_ runs: [RichRun], split: Bool = false) -> [RichRun] {
        var result: [RichRun] = [], paragraph: [String: String]? = nil
        for run in runs where !run.text.isEmpty {
            var text = Substring(run.text)
            while !text.isEmpty {
                let end = text.firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
                var styles = run.styles.filter { !$0.key.hasPrefix("paragraph/") && $0.key != sectionKey }
                let own = run.styles.filter { $0.key.hasPrefix("paragraph/") }
                styles.merge(paragraph ?? own) { $1 }
                paragraph = text[..<end].hasSuffix("\n") ? nil : (paragraph ?? own)
                let piece = String(text[..<end])
                if !split, let last = result.last, last.styles == styles { result[result.count - 1].text += piece }
                else { result.append(RichRun(text: piece, styles: styles)) }
                text = text[end...]
            }
        }
        return result
    }

    /// Samsung's marker stream for `runs` (see `normalized`), written the way Samsung Notes writes it: the always-written
    /// styles are filled in from `defaults` where a run lacks them, paragraph styles are closed and reopened at every
    /// paragraph, other styles are closed where they end or change and opened where they start, and the text's length
    /// opens a `sectionData` that is closed at the end, as in `StyledText.encode`. Paragraph keys come before span keys.
    init(runs: [RichRun], defaults: [String: String] = RichText.defaultStyles) {
        func order(_ key: String) -> (Int, String) { (key.hasPrefix("paragraph/") ? 0 : key == Self.sectionKey ? 2 : 1, key) }
        let filled = runs.map { run in RichRun(text: run.text, styles: run.styles.merging(defaults) { own, _ in own }) }
        var items: [Item] = [], open: [String: String] = [:], startsParagraph = true
        for piece in Self.normalized(filled, split: true) {
            var tokens: [Token] = []
            let closing = open.filter { key, value in
                key != Self.sectionKey && ((startsParagraph && key.hasPrefix("paragraph/")) || piece.styles[key] != value)
            }.keys.sorted { order($0) < order($1) }
            for key in closing { tokens.append(Token(key: key, value: nil)); open[key] = nil }
            for key in piece.styles.keys.sorted(by: { order($0) < order($1) }) where open[key] == nil {
                tokens.append(Token(key: key, value: piece.styles[key])); open[key] = piece.styles[key]
            }
            if items.isEmpty { tokens.append(Token(key: Self.sectionKey, value: String(runs.map(\.text).joined().utf16.count))); open[Self.sectionKey] = "" }
            if !tokens.isEmpty { items.append(.marker(tokens)); items.append(.text(piece.text)) }
            else if case .text(let previous) = items.last { items[items.count - 1] = .text(previous + piece.text) }
            else { items.append(.text(piece.text)) }
            startsParagraph = piece.text.hasSuffix("\n")
        }
        if !open.isEmpty {
            // As `StyledText.encode` ends: spans (last opened first), then paragraph styles, then the section.
            let spans = open.keys.filter { order($0).0 == 1 }.sorted(by: >), paragraphs = open.keys.filter { order($0).0 == 0 }.sorted()
            items.append(.marker((spans + paragraphs + [Self.sectionKey]).map { Token(key: $0, value: nil) }))
            items.append(.marker([Token(key: Self.sectionKey, value: "0"), Token(key: Self.sectionKey, value: nil)]))
        }
        self.init(items: items)
    }
}

extension RichText {
    /// `runs` normalized (see `normalized`), with each sequence of list paragraphs of one numbered kind counted on from
    /// the first one's number, as Samsung Notes draws them. This is the form the editor shows and change checks compare.
    static func numbered(_ runs: [RichRun]) -> [RichRun] {
        var pieces = normalized(runs, split: true), previous: (kind: RichStyle.Bullet, number: Int)? = nil, startsParagraph = true
        for index in pieces.indices {
            let value = pieces[index].styles["paragraph/bullet"]
            if startsParagraph {
                if let bullet = RichStyle.bullet(value), bullet.kind.isNumbered {
                    previous = (bullet.kind, previous?.kind == bullet.kind ? previous!.number + 1 : max(bullet.number, 1))
                } else { previous = nil }
            }
            if let previous, var parts = value?.split(separator: ",", omittingEmptySubsequences: false), parts.count >= 2 {
                parts[1] = Substring(String(previous.number))
                pieces[index].styles["paragraph/bullet"] = parts.joined(separator: ",")
            }
            startsParagraph = pieces[index].text.hasSuffix("\n")
        }
        return normalized(pieces)
    }
}

extension RichStyle.Bullet {
    var isNumbered: Bool { [.number, .circledNumber, .letter, .roman, .capitalLetter].contains(self) }
}
