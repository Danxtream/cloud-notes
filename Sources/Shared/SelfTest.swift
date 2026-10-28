// Licensed under GPL-3.0-only with an additional term under section 7(b); see LICENSE and NOTICE.md.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CoreGraphics
import CryptoKit

/// Offline checks shared by every Apple client. No network, Keychain or account access.
enum SelfTest {
    static func run() throws {
        guard SamsungAuthCrypto.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" else { throw NotesError.message("PKCE reference vector failed.") }
        let callbackKey = Data("0123456789abcdef".utf8)
        let encryptedCallback = try SamsungAuthCrypto.aes(Data("synthetic-callback".utf8), key: callbackKey, encrypt: true, ecb: true).map { String(format: "%02x", $0) }.joined()
        guard try SamsungAuthCrypto.callback(encryptedCallback, key: "0123456789abcdef-extra") == "synthetic-callback" else { throw NotesError.message("Samsung callback decryption failed.") }
        do { _ = try SamsungAuthCrypto.callback("not-hex", key: "test"); throw NotesError.message("Malformed callback was accepted.") }
        catch let error as NotesError { if error.localizedDescription == "Malformed callback was accepted." { throw error } }
        let cases = ["", "hello", "café — 日本語 🚀", "first\nsecond\n", "<&> \"quotes\""]
        for value in cases { guard try StyledText.decode(StyledText.encode(value)) == value else { throw NotesError.message("Text round-trip mismatch.") } }
        // Samsung's parser rejects text that leaves a style open, so every 'key'='value' must be followed by a bare 'key'.
        let encoded = String(decoding: Data(base64Encoded: StyledText.encode("balanced"))!, as: UTF8.self)
        var open: [String: Int] = [:]
        for marker in StyledText.marker.matches(in: encoded, range: NSRange(encoded.startIndex..., in: encoded)).compactMap({ Range($0.range, in: encoded).map { String(encoded[$0]) } }) {
            for token in marker.dropFirst(4).dropLast(2).split(separator: " ") {
                let key = String(token.split(separator: "=", maxSplits: 1)[0])
                open[key, default: 0] += token.contains("=") ? 1 : -1
            }
        }
        guard open.values.allSatisfy({ $0 == 0 }) else { throw NotesError.message("Encoded text leaves a style open.") }
        guard decodedCloudName(Data("Math notes\u{200b}".utf8).base64EncodedString()) == "Math notes", decodedCloudName(Data("Math notes 📒".utf8).base64EncodedString()) == "Math notes 📒", decodedCloudName("My notes") == "My notes" else { throw NotesError.message("Folder name decoding failed.") }
        let nested = [FolderRecord(id: "a", name: "Dev", parent: "root"), FolderRecord(id: "b", name: "Repos", parent: "a"),
                      FolderRecord(id: "c", name: "Loop", parent: "d"), FolderRecord(id: "d", name: "Back", parent: "c"), FolderRecord(id: "e", name: "Orphan", parent: "gone")]
        guard nested.tree.map(\.id) == ["a", "c", "d", "e"], nested.tree[0].children?.map(\.id) == ["b"], nested.tree[1].children == nil,
              nested.path(of: "b") == "Dev/Repos", nested.path(of: "e") == "Orphan" else { throw NotesError.message("Folder tree mismatch.") }
        var inMath = NoteRecord(id: "m", resourceID: "m", commit: "c", modified: 0, locked: false, encrypted: false); inMath.folder = "math:///"
        let builtIn = [FolderRecord(id: "math:///", name: "Math notes", parent: "root"), FolderRecord(id: "screenOffMemo:///", name: "Screen off memo", parent: "root"), FolderRecord(id: "a", name: "Dev", parent: "root")]
        var trashedMath = inMath; trashedMath.trashed = true
        guard builtIn.listed(with: [inMath]).map(\.id) == ["math:///", "a"], builtIn.listed(with: [trashedMath]).map(\.id) == ["a"] else { throw NotesError.message("Built-in folder listing mismatch.") }
        let newFolder = try XMLDocument(data: CloudClient.newFolderXML(id: "f1", name: "Plans & <ideas> 📒", parent: "a", order: 3, latestSync: 42, now: 7), options: [.nodeLoadExternalEntitiesNever])
        guard let resource = newFolder.rootElement(), resource.name == "FolderResource", resource.value("syncModifiedTime") == "42",
              let node = resource.first("nodeList")?.first("node"), node.attr("id") == "f1", node.attr("type") == "folder",
              node.value("parentFolderNodeId") == "a", decodedCloudName(node.value("name")) == "Plans & <ideas> 📒", node.value("state") == "normal",
              node.value("order") == "3", node.value("color") == "-1", node.value("createdTime") == "7", node.value("syncModifiedTime") == "7" else { throw NotesError.message("New folder request mismatch.") }
        let oldIDs = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333",
                      "44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555", "66666666-6666-4666-8666-666666666666"]
        func templateXML(attachment: Bool = false) -> String {
            "<CompareNoteView><noteResource id=\"\(oldIDs[0])\" isLocked=\"false\" isEncrypted=\"false\" createdTime=\"1\" syncModifiedTime=\"1\">"
            + "<noteTree ver=\"1\"><pageList><page h=\"x\" id=\"\(oldIDs[1])\" t=\"1\"><layerList><layer h=\"x\" id=\"\(oldIDs[2])\" t=\"1\"/></layerList></page></pageList>"
            + "<bodyText h=\"x\" id=\"\(oldIDs[3])\" t=\"1\"/></noteTree><contentFileList>\(attachment ? "<contentFile id=\"f\" hash=\"h\"/>" : "")</contentFileList>"
            + "<attributes modifiedTime=\"1\"><title><object id=\"\(oldIDs[4])\" hash=\"x\"><text>\(StyledText.encode("Old title"))</text></object></title></attributes>"
            + "<pageList><page id=\"\(oldIDs[1])\" hash=\"x\"><layerList><layer id=\"\(oldIDs[2])\" hash=\"x\"><objectList/></layer></layerList></page></pageList>"
            + "<bodyText id=\"\(oldIDs[3])\"><object id=\"\(oldIDs[5])\" hash=\"x\" timeStamp=\"1793058153714309\"><spanOrderDataList><spanOrderData val=\"OLDSPAN\"/></spanOrderDataList>"
            + "<text>\(StyledText.encode("Old private text"))</text></object></bodyText></noteResource><commitId>c</commitId></CompareNoteView>"
        }
        let newNote = try CloudDocument.newNoteXML(template: Data(templateXML().utf8), id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "New idea", body: "Line one", now: Date(timeIntervalSince1970: 2))
        let made = try XMLDocument(data: newNote, options: [.nodeLoadExternalEntitiesNever])
        guard let note = made.rootElement(), note.name == "NoteResource", note.attr("id") == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", note.attr("syncModifiedTime") == "2000", note.attr("createdTime") == "2000000",
              let page = note.first("pageList")?.first("page"), let treePage = note.first("noteTree")?.first("pageList")?.first("page"),
              treePage.attr("id") == page.attr("id"), treePage.attr("h") == page.attr("hash"), treePage.attr("t") == page.attr("modifiedTime"),
              let layer = page.first("layerList")?.first("layer"), let treeLayer = treePage.first("layerList")?.first("layer"),
              treeLayer.attr("t") == layer.attr("modifiedTime"), treeLayer.attr("h") == layer.attr("hash"),
              note.first("bodyText")?.first("object")?.attr("timeStamp") == "0",
              note.first("bodyText")?.first("object")?.first("spanOrderDataList") == nil,
              note.first("bodyText")?.attr("id") == note.first("noteTree")?.first("bodyText")?.attr("id"),
              try StyledText.decode(note.first("bodyText")?.first("object")?.value("text") ?? "") == "Line one",
              try StyledText.decode(note.first("attributes")?.first("title")?.first("object")?.value("text") ?? "") == "New idea",
              !(oldIDs + ["OLDSPAN", StyledText.encode("Old private text"), StyledText.encode("Old title")]).contains(where: { String(decoding: newNote, as: UTF8.self).contains($0) })
        else { throw NotesError.message("New note XML mismatch.") }
        do { _ = try CloudDocument.newNoteXML(template: Data(templateXML(attachment: true).utf8), id: "b", title: "", body: ""); throw NotesError.message("A template with attachments was accepted.") }
        catch let error as NotesError { if error.localizedDescription == "A template with attachments was accepted." { throw error } }
        guard try XMLDocument(data: CloudClient.newFolderXML(id: "f2", name: "Later", parent: "root", order: 0, latestSync: 42, now: 99), options: [.nodeLoadExternalEntitiesNever])
              .rootElement()?.value("syncModifiedTime") == "99" else { throw NotesError.message("New folder request time mismatch.") }
        func treeNode(_ id: String, _ type: String, _ parent: String, _ name: String) -> String {
            "<node id=\"\(id)\" type=\"\(type)\"><parentFolderNodeId>\(parent)</parentFolderNodeId><syncModifiedTime>5</syncModifiedTime><createdTime>1</createdTime>"
            + "<lastModifiedTime>2</lastModifiedTime><name>\(Data(name.utf8).base64EncodedString())</name><state>normal</state><trashedTime>0</trashedTime><color>-1</color><order>4</order></node>"
        }
        let treeXML = try XMLDocument(xmlString: "<r>" + treeNode("a", "folder", "root", "Dev") + treeNode("b", "folder", "a", "Repos") + treeNode("n", "note", "b", "Note")
            + treeNode("x", "folder", "y", "Loop") + treeNode("y", "folder", "x", "Back") + "</r>", options: [.nodeLoadExternalEntitiesNever])
        let treeNodes = treeXML.rootElement()?.elements(forName: "node") ?? []
        let inRepos = try XMLDocument(data: CloudClient.newFolderXML(id: "f3", name: "Ideas", parent: "b", order: 0, latestSync: 42, now: 99,
                                                                     ancestors: CloudClient.ancestors(of: "b", in: treeNodes)), options: [.nodeLoadExternalEntitiesNever])
        let sent = inRepos.rootElement()?.first("nodeList")?.elements(forName: "node") ?? []
        guard sent.map({ $0.attr("id") }) == ["f3", "b", "a"], sent.allSatisfy({ $0.value("syncModifiedTime") == "99" }),
              decodedCloudName(sent[1].value("name")) == "Repos", sent[1].value("parentFolderNodeId") == "a", sent[2].value("parentFolderNodeId") == "root",
              sent[1].value("createdTime") == "1", sent[1].value("lastModifiedTime") == "2", sent[1].value("order") == "4",
              CloudClient.ancestors(of: "root", in: treeNodes).isEmpty, CloudClient.ancestors(of: "x", in: treeNodes).map(\.id) == ["x", "y"],
              CloudClient.ancestors(of: "n", in: treeNodes).isEmpty else { throw NotesError.message("Parent folders in a nested request mismatch.") }
        let tree = [FolderRecord(id: "a", name: "Dev", parent: "root"), FolderRecord(id: "b", name: "Repos", parent: "a")]
        guard CloudClient.restorePath(of: "b", folders: tree) == "uncategorized:///Dev/Repos", CloudClient.restorePath(of: "root", folders: tree) == "uncategorized:///",
              CloudClient.restoreParent("uncategorized:///Dev/Repos", folders: tree) == "b", CloudClient.restoreParent("uncategorized:///Gone", folders: tree) == "root",
              CloudClient.restoreParent("uncategorized:///", folders: tree) == "root", CloudClient.restoreParent("", folders: tree) == "root" else { throw NotesError.message("Restore path mismatch.") }
        // Deleting a folder as a phone did: it goes to the top level with a restore path to where it was, what it holds
        // is trashed where it stands, and the folder it left goes along with a fresh modified time.
        let deleting = try XMLDocument(xmlString: "<r>" + treeNode("a", "folder", "root", "Dev") + treeNode("b", "folder", "a", "Repos") + treeNode("c", "folder", "b", "Old")
            + treeNode("n", "note", "b", "Note") + treeNode("m", "note", "c", "Deep") + treeNode("o", "note", "a", "Stays") + "</r>", options: [.nodeLoadExternalEntitiesNever])
        let trashing = try CloudClient.trashFolderNodes("b", in: deleting.rootElement()?.elements(forName: "node") ?? [], now: 9)
        guard trashing.map(\.id) == ["b", "c", "n", "m", "a"], trashing[0].state == "trashed", trashing[0].parent == "root",
              trashing[0].restorePath == "uncategorized:///Dev/Repos", trashing[0].trashed == 9, trashing[0].modified == 9,
              trashing[1...3].allSatisfy({ $0.state == "trashed" && $0.trashed == 9 && $0.modified == 2 }), trashing[1...3].map(\.parent) == ["b", "b", "c"],
              trashing[1...3].map(\.restorePath) == ["uncategorized:///Dev/Repos/Old", "uncategorized:///Dev/Repos", "uncategorized:///Dev/Repos/Old"],
              trashing[4].state == "normal", trashing[4].modified == 9 else { throw NotesError.message("Folder delete nodes mismatch.") }
        // Note orders: dates newest first, names A to Z the way Finder sorts them (case, accents, numbers), ties by date
        // modified, a missing creation date counting as the modification date, favourites first when asked.
        func sortable(_ id: String, _ title: String, modified: Double, created: Double?, favorite: Bool = false) -> NoteRecord {
            var note = NoteRecord(id: id, resourceID: id, commit: "c", modified: modified, locked: false, encrypted: false)
            note.title = title; note.created = created; note.favorite = favorite; return note
        }
        let sortNotes = [sortable("1", "banana", modified: 50, created: 10), sortable("2", "Apple", modified: 40, created: 30, favorite: true),
                         sortable("3", "Éclair", modified: 30, created: nil), sortable("4", "item 10", modified: 20, created: 20),
                         sortable("5", "item 9", modified: 20, created: 5)]
        func order(_ sort: NoteSort) -> [String] { sort.sorted(sortNotes).map(\.id) }
        guard order(NoteSort()) == ["1", "2", "3", "4", "5"], order(NoteSort(key: .modified, reversed: true)) == ["4", "5", "3", "2", "1"],
              order(NoteSort(key: .name)) == ["2", "1", "3", "5", "4"], order(NoteSort(key: .name, reversed: true)) == ["4", "5", "3", "1", "2"],
              order(NoteSort(key: .created)) == ["2", "3", "4", "1", "5"], order(NoteSort(key: .name, favoritesFirst: true)) == ["2", "1", "3", "5", "4"],
              order(NoteSort(key: .modified, favoritesFirst: true)) == ["2", "1", "3", "4", "5"] else { throw NotesError.message("Note order mismatch.") }
        // Local copies of blocked notes: sealed data starts with the marker, opens back to the original, is never sealed
        // twice, fails to open with another key, and unsealed data passes through; the block list reads back.
        let fixtureLocalKey = SymmetricKey(data: Data(repeating: 7, count: 32)), plainCopy = Data("<note>fixture</note>".utf8)
        let sealedCopy = try LocalSeal.seal(plainCopy, with: fixtureLocalKey)
        guard LocalSeal.isSealed(sealedCopy), !LocalSeal.isSealed(plainCopy), sealedCopy.range(of: plainCopy) == nil,
              try LocalSeal.open(sealedCopy, with: fixtureLocalKey) == plainCopy, try LocalSeal.seal(sealedCopy, with: fixtureLocalKey) == sealedCopy,
              try LocalSeal.open(plainCopy, with: fixtureLocalKey) == plainCopy,
              (try? LocalSeal.open(sealedCopy, with: SymmetricKey(data: Data(repeating: 8, count: 32)))) == nil,
              try JSONDecoder().decode(BlockedNotes.List.self, from: Data(#"{"version":1,"notes":[{"id":"n1","title":"Untitled"}]}"#.utf8)).notes == [BlockedNotes.Entry(id: "n1", title: "Untitled")]
        else { throw NotesError.message("Local encryption mismatch.") }
        // Folder colours: every picker value and its 70% alpha variant read back as that colour; -1 and others are grey.
        guard FolderColor.allCases.allSatisfy({ FolderColor(stored: $0.stored) == $0 }), FolderColor.red.stored == -48845,
              FolderColor(stored: Int(Int32(bitPattern: 0xB3FF_4133))) == .red, FolderColor(stored: -1) == .grey, FolderColor(stored: 0) == .grey,
              FolderColor(name: "Light Blue") == .lightBlue, FolderColor(name: "light-purple") == .lightPurple, FolderColor(name: "default") == .grey,
              FolderColor(name: "teal") == nil else { throw NotesError.message("Folder colour mismatch.") }
        let trashedNode = try XMLDocument(data: CloudClient.folderResourceXML([CloudClient.TreeNodeFields(id: "n1", type: "note", encodedName: "IA==", parent: "root", state: "trashed",
            order: 999_999, created: 1, modified: 2, trashed: 5, restorePath: "uncategorized:///Dev")], latestSync: 3, now: 5), options: [.nodeLoadExternalEntitiesNever])
        guard let trashed = trashedNode.rootElement()?.first("nodeList")?.first("node"), trashed.value("state") == "trashed", trashed.value("trashedTime") == "5",
              Data(base64Encoded: trashed.value("restorePath")).flatMap({ String(data: $0, encoding: .utf8) }) == "uncategorized:///Dev",
              trashed.value("name") == "IA==", trashed.value("createdTime") == "1", trashed.value("requestDevice").contains("deviceName") else { throw NotesError.message("Trash request mismatch.") }
        var inTrash = NoteRecord(id: "t", resourceID: "r", commit: "c", modified: 0, locked: false, encrypted: false)
        inTrash.trashed = true; inTrash.trashedTime = 1_000_000_000_000
        guard inTrash.daysLeftInTrash(now: Date(timeIntervalSince1970: 1_000_000_000 + 2.5 * 86_400)) == 28,
              inTrash.daysLeftInTrash(now: Date(timeIntervalSince1970: 1_000_000_000 + 40 * 86_400)) == 0 else { throw NotesError.message("Trash days mismatch.") }
        typealias Token = RichText.Token
        let rich = RichText(items: [
            .marker([Token(key: "paragraph/alignment", value: "0"), Token(key: "span/fontSize", value: "1,16.0"), Token(key: "span/foregroundColor", value: "1,-14342875")]),
            .text("Plan *1*"), .marker([Token(key: "paragraph/bullet", value: "8,0")]), .text("\ndot"),
            .marker([Token(key: "paragraph/bullet", value: nil), Token(key: "paragraph/bullet", value: "4,2")]), .text("\ntwo"),
            .marker([Token(key: "paragraph/bullet", value: nil), Token(key: "paragraph/bullet", value: "2,true")]), .text("\ndone"),
            .marker([Token(key: "paragraph/bullet", value: nil)]), .text("\n- "),
            .marker([Token(key: "span/bold", value: "1,True"), Token(key: "span/foregroundColor", value: nil), Token(key: "span/foregroundColor", value: "1,-1762269")]), .text("red bold"),
            .marker([Token(key: "span/bold", value: nil), Token(key: "span/fontSize", value: nil), Token(key: "span/fontSize", value: "3,20.0")]), .text(" big"),
            .marker([Token(key: "span/fontSize", value: nil), Token(key: "span/foregroundColor", value: nil), Token(key: "paragraph/alignment", value: nil)])])
        let oddSpacing = Data("<?a  'span/bold'='1,True'?>".utf8).base64EncodedString()
        guard try RichText(encoded: rich.encoded) == rich, try RichText(encoded: StyledText.encode("Plain")).plain == "Plain",
              rich.plain == "Plan *1*\ndot\ntwo\ndone\n- red bold big",
              rich.markdown == "Plan \\*1\\*\n- dot\n2. two\n- [x] done\n\\- {color=#E51C23}**red bold**{/} {color=#E51C23 size=20}big{/}",
              (try? RichText(encoded: oddSpacing)) == nil,
              RichStyle.label((.roman, 4, false)) == "iv.", RichStyle.label((.letter, 28, false)) == "ab.", RichStyle.label((.circledNumber, 3, false)) == "③"
        else { throw NotesError.message("Styled text mismatch.") }
        // Written back from runs, the styles survive, every style is closed, and plain text matches StyledText.encode.
        // Samsung Notes opens the note only when every paragraph style starts at the text's start or on a newline.
        func readableOnDevices(_ text: RichText) -> Bool {
            let units = Array(text.plain.utf16)
            var offset = 0, open: [String: Int] = [:], starts: [Int] = []
            for item in text.items {
                switch item {
                case .text(let run): offset += run.utf16.count
                case .marker(let tokens):
                    for token in tokens {
                        open[token.key, default: 0] += token.value == nil ? -1 : 1
                        if token.value != nil, token.key.hasPrefix("paragraph/") { starts.append(offset) }
                    }
                }
            }
            return open.values.allSatisfy { $0 == 0 } && starts.allSatisfy { $0 == 0 || ($0 < units.count && units[$0] == 10) }
        }
        let rebuilt = RichText(runs: rich.styledRuns)
        let blankLines = RichText(runs: [RichRun(text: "\n", styles: [:]), RichRun(text: "dot\n", styles: ["paragraph/bullet": "8,0"]),
                                         RichRun(text: "\nend", styles: ["span/bold": "1,True"])])
        guard RichText.normalized(rebuilt.styledRuns).map(\.text) == RichText.normalized(rich.styledRuns).map(\.text),
              zip(RichText.normalized(rebuilt.styledRuns), RichText.normalized(rich.styledRuns)).allSatisfy({
                  $0.styles.merging(RichText.defaultStyles) { a, _ in a } == $1.styles.merging(RichText.defaultStyles) { a, _ in a } }),
              readableOnDevices(rebuilt), try RichText(encoded: rebuilt.encoded) == rebuilt,
              readableOnDevices(blankLines), try RichText(encoded: blankLines.encoded) == blankLines, blankLines.plain == "\ndot\n\nend",
              RichText(runs: [RichRun(text: "Plain", styles: [:])]).encoded == StyledText.encode("Plain")
        else { throw NotesError.message("Styled text rebuild mismatch.") }
        // Markdown-style edits: unchanged lines keep their exact styles, changed and new lines take their markup.
        let edited = rich.runs(fromMarkdown: rich.markdown.replacingOccurrences(of: "2. two", with: "2. **two** {color=#43A047 size=24}green{/}") + "\n- [ ] new \\*")
        let green = edited.first { $0.text.hasPrefix("green") }
        guard rich.runs(fromMarkdown: rich.markdown) == RichText.numbered(rich.styledRuns),
              edited.map(\.text).joined() == "Plan *1*\ndot\ntwo green\ndone\n- red bold big\nnew *",
              edited.first == RichText.numbered(rich.styledRuns).first,
              edited.first(where: { $0.text == "two" })?.styles["span/bold"] == "1,True",
              green?.styles["span/foregroundColor"] == "1,-12345273", green?.styles["span/fontSize"] == "1,24.0",
              edited.last?.styles["paragraph/bullet"] == "2,false"
        else { throw NotesError.message("Markdown-style edit mismatch.") }
        let inkFixture = Data(base64Encoded:"/////wQAAACgDwAADQAAAAAADQAAAAEIAEoAAAABAEIAAAABAAEMAgAAAAAAAAAkQAAAAAAAADRAAAAAAAAAPkAAAAAAAABEQAAAAD8AAEA/AAAAAAoAAAACAFY0Ev8AAEBA")!
        let ink = try InkStroke(inkFixture)
        guard ink.points.count == 2, ink.points[1] == CGPoint(x: 30, y: 40), ink.color == 0xff123456 else { throw NotesError.message("Drawing coordinates or color mismatch.") }
        do { _ = try InkStroke(inkFixture.prefix(25)); throw NotesError.message("Truncated drawing was accepted.") }
        catch let error as NotesError { if error.localizedDescription == "Truncated drawing was accepted." { throw error } }
        let mixed = "<?a 'span/bold'='1,True'?>" + Data("one".utf8).base64EncodedString() + "<?a 'span/bold'?>" + Data("\ntwo".utf8).base64EncodedString()
        guard try StyledText.decode(Data(mixed.utf8).base64EncodedString()) == "one\ntwo" else { throw NotesError.message("Styled spans mismatch.") }
        let cursor = Data(base64Encoded: CloudClient.initialCursor("NOTE"))!
        guard let initial = try JSONSerialization.jsonObject(with: cursor) as? [String: Any], initial["purpose"] as? String == "INITIAL" else { throw NotesError.message("Invalid initial cursor.") }
        // A synthetic signed-in session for the cache checks below.
        let session = AccountSession(authorization: "Bearer synthetic-connection-fixture", account: "Fixture")
        let fixtureXML = "<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\" unknownField=\"retain\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree><attributes><title><object/></title></attributes><bodyText id=\"body\"><object type=\"textBox\" hash=\"old\"><text>\(StyledText.encode("Before"))</text></object></bodyText><pageList><page id=\"page\"><opaqueDrawing value=\"preserve\"/></page></pageList><contentFileList><contentFile id=\"asset\" hash=\"original\"/></contentFileList></noteResource><commitId>fixture-revision</commitId><downloadUrls/></CompareNoteView>"
        // The portable DOM must round-trip the fixture exactly as the shared code sees it.
        let portable = try PortableXMLDocument(data: Data(fixtureXML.utf8), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard try PortableXMLDocument(data: Data(portable.xmlString.utf8)).xmlString == portable.xmlString,
              portable.rootElement()?.first("noteResource")?.first("bodyText")?.first("object")?.value("text") == StyledText.encode("Before"),
              try portable.nodes(forXPath: "/CompareNoteView/noteResource/pageList/page/opaqueDrawing[@value='preserve']").count == 1,
              try portable.rootElement()?.nodes(forXPath: ".//contentFile").count == 1 else { throw NotesError.message("Portable XML round-trip failed.") }
        let escaped = try PortableXMLDocument(data: Data("<?xml version=\"1.0\"?><!-- c --><a x='1 &amp; &quot;2&quot;' y=\"&#x1F680;\"><b/>t&lt;&#233;<![CDATA[<raw>]]></a>".utf8))
        guard escaped.rootElement()?.attr("x") == "1 & \"2\"", escaped.rootElement()?.attr("y") == "🚀", escaped.rootElement()?.stringValue == "t<é<raw>",
              escaped.xmlString == "<?xml version=\"1.0\"?><!-- c --><a x=\"1 &amp; &quot;2&quot;\" y=\"🚀\"><b/>t&lt;é<![CDATA[<raw>]]></a>" else { throw NotesError.message("Portable XML escaping failed.") }
        for invalid in ["<a><b></a>", "<!DOCTYPE a [<!ENTITY x \"y\">]><a>&x;</a>", "<a/><b/>", "<a x='1' x='2'/>"] {
            guard (try? PortableXMLDocument(data: Data(invalid.utf8))) == nil else { throw NotesError.message("Portable XML accepted invalid input.") }
        }
        #if os(macOS)
        let foundation = try Foundation.XMLDocument(data: Data(portable.xmlString.utf8), options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard foundation.rootElement()?.xmlString(options: []) == portable.rootElement()?.xmlString() else { throw NotesError.message("Portable XML differs from Foundation XML.") }
        #endif
        let fixture = try CloudDocument(serverID: "fixture", data: Data(fixtureXML.utf8))
        let starred = try XMLDocument(data: CloudDocument(serverID: "star", data: Data(fixtureXML.utf8)).uploadXML(title: "", body: "Before", favorite: true),
                                      options: [.nodeLoadExternalEntitiesNever]).rootElement()
        guard starred?.first("attributes")?.attr("isFavorite") == "true", !fixture.isFavorite else { throw NotesError.message("Favorite flag mismatch.") }
        // Saves must stay readable on Samsung devices: timeStamp fits an Int32 and stale span data is gone, even when an
        // earlier version of this client left a microsecond timeStamp behind.
        let damaged = try CloudDocument(serverID: "damaged", data: Data(("<CompareNoteView><noteResource isLocked=\"false\" isEncrypted=\"false\"><noteTree ver=\"4000\"><bodyText id=\"body\" h=\"old\" t=\"0\"/></noteTree>"
            + "<attributes><title><object timeStamp=\"1793068308238575\"><text>\(StyledText.encode("Title"))</text></object></title></attributes><bodyText id=\"body\"><object hash=\"old\" timeStamp=\"1793068308238575\">"
            + "<spanOrderDataList><spanOrderData val=\"x\"/></spanOrderDataList><text>\(StyledText.encode("Old"))</text></object></bodyText></noteResource><commitId>c</commitId></CompareNoteView>").utf8))
        let repaired = try XMLDocument(data: damaged.uploadXML(title: "Title", body: "New"), options: [.nodeLoadExternalEntitiesNever]).rootElement()
        guard repaired?.first("bodyText")?.first("object")?.attr("timeStamp") == "0", repaired?.first("attributes")?.first("title")?.first("object")?.attr("timeStamp") == "0",
              repaired?.first("bodyText")?.first("object")?.first("spanOrderDataList") == nil else { throw NotesError.message("A save left the note unreadable on Samsung devices.") }
        let cacheTestRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SamsungCloudNotes-CacheTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheTestRoot) }
        let cache = try NoteCache(session: session, base: cacheTestRoot)
        var record = NoteRecord(id: "fixture", resourceID: "r", commit: "revision-1", modified: 0, locked: false, encrypted: false)
        try cache.save(fixture, revision: record.commit)
        try cache.saveIndex(CloudIndex(notes: [record], folders: []))
        let reopened = try NoteCache(session: session, base: cacheTestRoot)
        guard reopened.snapshot()?.index.notes.count == 1, reopened.document(record)?.body == "Before" else { throw NotesError.message("Cache did not survive reopening.") }
        record.commit = "revision-2"
        guard reopened.document(record) == nil else { throw NotesError.message("A stale cached revision was accepted.") }
        record.commit = "revision-1"; record.locked = true
        guard reopened.document(record) == nil else { throw NotesError.message("A locked note was restored from cache.") }
        let nativeOne = AccountSession(authorization: "Bearer synthetic-native-first", account: "Fixture", nativeID: "native:fixture:mac")
        let nativeCache = try NoteCache(session: nativeOne, base: cacheTestRoot)
        try nativeCache.saveIndex(CloudIndex(notes: [record], folders: []))
        let nativeTwo = AccountSession(authorization: "Bearer synthetic-native-renewed", account: "Fixture", nativeID: "native:fixture:mac")
        guard try NoteCache(session: nativeTwo, base: cacheTestRoot).snapshot()?.index.notes.count == 1 else { throw NotesError.message("Native token renewal lost its cache.") }
        let differentNative = AccountSession(authorization: "Bearer synthetic-other-account", account: "Fixture", nativeID: "native:other:mac")
        guard try NoteCache(session: differentNative, base: cacheTestRoot).snapshot() == nil else { throw NotesError.message("Native cache leaked between accounts.") }
        let other = try NoteCache(session: AccountSession(authorization: "Bearer different-synthetic-session", account: session.account), base: cacheTestRoot)
        guard other.snapshot() == nil else { throw NotesError.message("Cache leaked between sessions with identical labels.") }
        try cache.saveAsset(Data("offline attachment".utf8), id: "asset", revision: "one")
        guard reopened.asset(id: "asset", revision: "one") == Data("offline attachment".utf8), reopened.asset(id: "asset", revision: "two") == nil else { throw NotesError.message("Attachment cache revision check failed.") }
        try reopened.prune([])
        record.locked = false
        guard reopened.document(record) == nil else { throw NotesError.message("Removed note was retained in cache.") }
        // The sync queue: a draft with the cloud's text is up to date, one made from the newest revision is saved, and one
        // from an older revision with other text is a conflict for the user, as Samsung Notes sets such notes aside.
        guard DraftSync.decide(["title": fixture.title, "body": fixture.body, "commit": "older"], current: fixture) == .upToDate,
              DraftSync.decide(["title": fixture.title, "body": "Changed here", "commit": fixture.commit], current: fixture) == .save,
              DraftSync.decide(["title": fixture.title, "body": "Changed here", "commit": "older"], current: fixture) == .conflict
        else { throw NotesError.message("Sync queue decision mismatch.") }
        let updated = try XMLDocument(data: fixture.uploadXML(title: "Test title", body: "After 日本語 🚀", now: Date(timeIntervalSince1970: 1_800_000_000)))
        // Other devices download the change only when its syncModifiedTime is newer than their copy's.
        guard updated.rootElement()?.attr("syncModifiedTime") == "1800000000000" else { throw NotesError.message("A save would not reach other devices.") }
        guard updated.rootElement()?.attr("unknownField") == "retain",
              try updated.nodes(forXPath: "/noteResource/pageList/page/opaqueDrawing[@value='preserve']").count == 1,
              try updated.nodes(forXPath: "/noteResource/contentFileList/contentFile[@hash='original']").count == 1 else { throw NotesError.message("Opaque drawing or attachment metadata was lost.") }
    }
}
