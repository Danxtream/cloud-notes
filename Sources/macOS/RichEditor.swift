// Licensed under GPL-3.0-only with an additional term under section 7(b); see LICENSE and NOTICE.md.

import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// A character's Samsung Notes styles (`RichRun.styles`). Fonts, colours and list indents are derived from them.
    static let samsungStyles = NSAttributedString.Key("SamsungNotesStyles")
}

/// Formatting commands for the open `RichTextEditor`, used by the format bar and its keyboard shortcuts.
@MainActor final class RichTextController: ObservableObject {
    fileprivate weak var textView: NoteTextView?
    fileprivate var changed: () -> Void = {}
    /// Connects the controller to an editor's text view; `RichTextEditor` does this itself.
    func attach(_ textView: NoteTextView, changed: @escaping () -> Void) { self.textView = textView; self.changed = changed }
    /// The text size (points) at the cursor or the selection's start, for the size menu; 16 where none is set, as the
    /// editor draws it.
    @Published private(set) var selectionSize: Double = 16
    /// Updates `selectionSize` after the selection or its styles change, outside SwiftUI's view updates.
    func refreshSelection() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let size = RichStyle.fontSize(self.currentStyles["span/fontSize"]) ?? 16
            if size != self.selectionSize { self.selectionSize = size }
        }
    }

    /// Turns bold, italic, underline or strikethrough on for the selection, or off when its start already has it.
    func toggle(_ key: String) {
        let on = RichStyle.isOn(currentStyles[key])
        change { styles in styles[key] = on ? nil : "1,True" }
    }
    /// Text colour as 0xAARRGGBB, or nil for Samsung's default text colour.
    func setColor(_ argb: UInt32?) {
        change { $0["span/foregroundColor"] = "1," + String(Int32(bitPattern: argb ?? 0xFF25_2525)) }
    }
    func setHighlight(_ argb: UInt32?) {
        change { $0["span/backgroundColor"] = argb.map { "1," + String(Int32(bitPattern: $0)) } }
    }
    func setSize(_ points: Double) { change { $0["span/fontSize"] = String(format: "1,%.1f", points) } }
    /// Makes the selected paragraphs a list of `kind`, or plain paragraphs when they already are one.
    func setList(_ kind: RichStyle.Bullet) {
        let off = RichStyle.bullet(currentStyles["paragraph/bullet"])?.kind == kind
        let value = kind == .checkbox ? "2,false" : "\(kind.rawValue),1"
        change(paragraphs: true) { $0["paragraph/bullet"] = off ? nil : value }
    }
    var currentStyles: [String: String] {
        guard let textView else { return [:] }
        let location = textView.selectedRange().location
        if textView.selectedRange().length == 0 || location >= (textView.textStorage?.length ?? 0) {
            return textView.typingAttributes[.samsungStyles] as? [String: String] ?? [:]
        }
        return textView.textStorage?.attribute(.samsungStyles, at: location, effectiveRange: nil) as? [String: String] ?? [:]
    }

    /// Applies `update` to the styles of the selection (whole paragraphs with `paragraphs`), or to what is typed next
    /// when nothing is selected, as one undoable change.
    private func change(paragraphs: Bool = false, _ update: (inout [String: String]) -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        var range = textView.selectedRange()
        if paragraphs { range = (storage.string as NSString).paragraphRange(for: range) }
        if range.length == 0 {
            var styles = currentStyles; update(&styles)
            textView.typingAttributes = RichTextEditor.attributes(styles)
            if !paragraphs { return }
        }
        guard range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.samsungStyles, in: range) { value, run, _ in
            var styles = value as? [String: String] ?? [:]; update(&styles)
            storage.setAttributes(RichTextEditor.attributes(styles), range: run)
        }
        storage.endEditing()
        textView.didChangeText()
        textView.typingAttributes = storage.length > 0 ? storage.attributes(at: min(textView.selectedRange().location, storage.length - 1), effectiveRange: nil) : textView.typingAttributes
        refreshSelection()
    }
}

/// The note text as Samsung Notes formats it (colours, sizes, bold, italic, underline, strikethrough, highlights and
/// lists), editable with the formatting kept. Typed text takes the styles where it is typed; pasted text is plain.
struct RichTextEditor: NSViewRepresentable {
    /// The open note's id: the editor reloads when it changes, or when `runs` stop matching what it last showed.
    var noteID: String
    @Binding var runs: [RichRun]
    @Binding var text: String
    var editable: Bool
    /// Styles for text typed into an empty note.
    var defaults: [String: String]
    var controller: RichTextController

    /// Samsung's body size, 16, shows at 15 points, the size the plain editor used.
    static let scale: CGFloat = 15.0 / 16.0
    static let listIndent: CGFloat = 26

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        // Long notes lay out only what is on screen, so opening one does not wait for its whole text.
        layout.allowsNonContiguousLayout = true
        let textView = NoteTextView(frame: .zero, textContainer: container)
        textView.isRichText = true; textView.allowsUndo = true; textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true; textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.toggleChecked = { [weak coordinator = context.coordinator] in coordinator?.toggleChecked(at: $0) }
        let scroll = NSScrollView()
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        context.coordinator.textView = textView
        controller.attach(textView) { [weak coordinator = context.coordinator] in coordinator?.publish() }
        context.coordinator.load(runs, note: noteID)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = editable
        controller.textView = textView
        // A different note, or the same note reloaded from the cloud. While editing, `runs` is the array the editor
        // itself published, so this comparison returns at once.
        if !textView.hasMarkedText(), context.coordinator.shownNote != noteID || context.coordinator.shownRuns != runs {
            context.coordinator.load(runs, note: noteID)
        }
    }

    /// The display attributes for `styles`, with the styles themselves kept under `.samsungStyles`.
    static func attributes(_ styles: [String: String]) -> [NSAttributedString.Key: Any] {
        let size = CGFloat(RichStyle.fontSize(styles["span/fontSize"]) ?? 16) * scale
        var font = NSFont.systemFont(ofSize: size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if RichStyle.isOn(styles["span/bold"]) { traits.insert(.bold) }
        if RichStyle.isOn(styles["span/italic"]) { traits.insert(.italic) }
        if !traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font }
        var attributes: [NSAttributedString.Key: Any] = [.samsungStyles: styles, .font: font]
        let highlight = RichStyle.argb(styles["span/backgroundColor"])
        if let argb = RichStyle.argb(styles["span/foregroundColor"]), !RichStyle.isDefaultTextColor(argb) { attributes[.foregroundColor] = color(argb) }
        else { attributes[.foregroundColor] = highlight == nil ? NSColor.textColor : NSColor.black }
        if let highlight { attributes[.backgroundColor] = color(highlight) }
        if RichStyle.isOn(styles["span/underline"]) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if RichStyle.isOn(styles["span/strikethrough"]) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 2
        if RichStyle.bullet(styles["paragraph/bullet"]) != nil { paragraph.firstLineHeadIndent = listIndent; paragraph.headIndent = listIndent }
        attributes[.paragraphStyle] = paragraph
        return attributes
    }
    static func color(_ argb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat(argb >> 24) / 255)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NoteTextView?
        /// The note and runs the editor shows, as last loaded or published.
        private(set) var shownNote: String?
        private(set) var shownRuns: [RichRun] = []
        init(_ parent: RichTextEditor) { self.parent = parent }

        func load(_ runs: [RichRun], note: String) {
            shownNote = note; shownRuns = runs
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let text = NSMutableAttributedString()
            for run in runs { text.append(NSAttributedString(string: run.text, attributes: RichTextEditor.attributes(run.styles))) }
            storage.setAttributedString(text)
            textView.typingAttributes = RichTextEditor.attributes(runs.first?.styles ?? parent.defaults)
            if NSMaxRange(selection) <= storage.length { textView.setSelectedRange(selection) }
            textView.needsDisplay = true
        }

        /// The editor's text as runs, normalized and with lists numbered in order (see `RichText.numbered`).
        func currentRuns() -> [RichRun] { RichText.numbered(storageRuns()) }

        /// The text storage's runs as they stand.
        private func storageRuns() -> [RichRun] {
            guard let storage = textView?.textStorage else { return [] }
            let string = storage.string as NSString
            var runs: [RichRun] = []
            storage.enumerateAttribute(.samsungStyles, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                runs.append(RichRun(text: string.substring(with: range), styles: value as? [String: String] ?? parent.defaults))
            }
            return runs
        }

        func textDidChange(_ notification: Notification) { publish() }
        func textViewDidChangeSelection(_ notification: Notification) { parent.controller.refreshSelection() }

        /// Sends the text to the model, first redrawing paragraphs whose styles normalizing or numbering changed.
        func publish() {
            guard let textView, !textView.hasMarkedText() else { return }
            let raw = storageRuns(), runs = RichText.numbered(raw)
            if RichText.normalized(raw) != runs { restyle(runs) }
            textView.needsDisplay = true
            shownRuns = runs
            parent.text = runs.map(\.text).joined()
            parent.runs = runs
        }

        /// Reapplies `runs`' styles over the same text, keeping the selection and undo history.
        private func restyle(_ runs: [RichRun]) {
            guard let storage = textView?.textStorage else { return }
            storage.beginEditing()
            var location = 0
            for run in runs {
                let length = (run.text as NSString).length
                storage.setAttributes(RichTextEditor.attributes(run.styles), range: NSRange(location: location, length: length))
                location += length
            }
            storage.endEditing()
        }

        /// Return in an empty list item ends the list; Delete at the start of a list item removes its bullet.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let storage = textView.textStorage, storage.length > 0 else { return true }
            let string = storage.string as NSString
            let caret = textView.selectedRange()
            func removeBullet(_ paragraph: NSRange) -> Bool {
                let at = min(paragraph.location, storage.length - 1)
                guard var styles = storage.attribute(.samsungStyles, at: at, effectiveRange: nil) as? [String: String],
                      styles["paragraph/bullet"] != nil else { return true }
                styles["paragraph/bullet"] = nil
                // An empty last line has no characters yet: only what is typed next loses the bullet.
                if paragraph.length > 0, textView.shouldChangeText(in: paragraph, replacementString: nil) {
                    storage.setAttributes(RichTextEditor.attributes(styles), range: paragraph)
                    textView.didChangeText()
                }
                textView.typingAttributes = RichTextEditor.attributes(styles)
                return false
            }
            if replacementString == "\n", caret.length == 0 {
                let paragraph = string.paragraphRange(for: NSRange(location: min(caret.location, string.length), length: 0))
                let content = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
                if content.isEmpty, caret.location < storage.length || caret.location > 0 { return removeBullet(paragraph) }
            }
            if replacementString == "", caret.length == 0, range.length == 1, range.location + 1 == caret.location, caret.location < storage.length,
               string.character(at: range.location) == 10 {
                return removeBullet(string.paragraphRange(for: NSRange(location: caret.location, length: 0)))
            }
            return true
        }

        func toggleChecked(at paragraph: NSRange) {
            guard let textView, let storage = textView.textStorage, paragraph.length > 0,
                  var styles = storage.attribute(.samsungStyles, at: paragraph.location, effectiveRange: nil) as? [String: String],
                  let bullet = RichStyle.bullet(styles["paragraph/bullet"]), bullet.kind == .checkbox,
                  textView.shouldChangeText(in: paragraph, replacementString: nil) else { return }
            styles["paragraph/bullet"] = bullet.checked ? "2,false" : "2,true"
            storage.beginEditing()
            storage.enumerateAttribute(.samsungStyles, in: paragraph) { value, run, _ in
                var own = value as? [String: String] ?? [:]; own["paragraph/bullet"] = styles["paragraph/bullet"]
                storage.setAttributes(RichTextEditor.attributes(own), range: run)
            }
            storage.endEditing()
            textView.didChangeText()
        }
    }
}

/// A text view that draws Samsung list labels (•, 1., ☐ …) in the indent of list paragraphs and toggles checkboxes on click.
final class NoteTextView: NSTextView {
    var toggleChecked: (NSRange) -> Void = { _ in }

    /// Pasted text takes the styles where it lands, like typed text.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        forEachListParagraph(in: dirtyRect) { _, label, rect, font, color in
            guard rect.intersects(dirtyRect) else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let width = (label as NSString).size(withAttributes: attributes).width
            (label as NSString).draw(at: NSPoint(x: rect.maxX - width - 6, y: rect.minY), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var hit: NSRange?
        forEachListParagraph(in: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)) { paragraph, label, rect, _, _ in
            if (label == "☐" || label == "☑"), rect.insetBy(dx: -4, dy: -2).contains(point) { hit = paragraph }
        }
        if let hit, isEditable { toggleChecked(hit) } else { super.mouseDown(with: event) }
    }

    /// Calls `body` with each list paragraph that has text inside `rect`, its label and the label's box in the
    /// paragraph's indent. Only that part of the text is laid out, so long notes stay quick to draw.
    private func forEachListParagraph(in rect: NSRect, _ body: (NSRange, String, NSRect, NSFont, NSColor) -> Void) {
        guard let storage = textStorage, let layoutManager, let textContainer, storage.length > 0 else { return }
        let string = storage.string as NSString
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var location = string.paragraphRange(for: NSRange(location: min(visible.location, string.length - 1), length: 0)).location
        while location < string.length, location <= NSMaxRange(visible) {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraph) }
            guard let styles = storage.attribute(.samsungStyles, at: paragraph.location, effectiveRange: nil) as? [String: String],
                  let bullet = RichStyle.bullet(styles["paragraph/bullet"]) else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: paragraph.location)
            guard glyph < layoutManager.numberOfGlyphs else { continue }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = layoutManager.location(forGlyphAt: glyph).y
            let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 15)
            let color = storage.attribute(.foregroundColor, at: paragraph.location, effectiveRange: nil) as? NSColor ?? .textColor
            let top = origin.y + line.minY + baseline - font.ascender
            body(paragraph, RichStyle.label(bullet), NSRect(x: origin.x + textContainer.lineFragmentPadding, y: top,
                                                           width: RichTextEditor.listIndent, height: font.ascender - font.descender), font, color)
        }
    }
}
