import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit
import Security

let appVersion = "1.1.0"
let appShortVersion = appVersion.components(separatedBy: "-")[0]
var transientSession: AccountSession?

enum NotesError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct AccountSession: Codable {
    var authorization: String
    var account: String
    var nativeID: String? = nil
    var expiresAt: Date? = nil
    var importedAt: Date = Date()
    enum CodingKeys: String, CodingKey { case authorization, account, nativeID, expiresAt }
}

enum SessionStore {
    static let service = "local.samsung-cloud-notes.session"
    static func save(_ value: AccountSession) throws {
        guard value.authorization.hasPrefix("Bearer "), value.authorization.count > 30,
              !value.authorization.contains("\n"), !value.authorization.contains("\r") else {
            throw NotesError.message("This connection file does not contain a valid Samsung session.")
        }
        _ = try CredentialVault.perform("save", service: service, data: JSONEncoder().encode(value))
    }
    static func load() throws -> AccountSession {
        guard let data = try CredentialVault.perform("load", service: service) else { throw CredentialError.status(errSecItemNotFound) }
        return try JSONDecoder().decode(AccountSession.self, from: data)
    }
    static func delete() throws { _ = try CredentialVault.perform("delete", service: service) }
}

extension XMLElement {
    var bytes: Data { Data(xmlString(options: []).utf8) }
    func first(_ name: String) -> XMLElement? { elements(forName: name).first }
    func value(_ name: String) -> String { first(name)?.stringValue ?? "" }
    func attr(_ name: String) -> String { attribute(forName: name)?.stringValue ?? "" }
    func set(_ name: String, _ value: String) {
        if let attribute = attribute(forName: name) { attribute.stringValue = value }
        else { addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
}

enum StyledText {
    static let marker = try! NSRegularExpression(pattern: "<\\?.*?\\?>", options: [.dotMatchesLineSeparators])
    static func decode(_ encoded: String) throws -> String {
        if encoded.isEmpty { return "" }
        guard let data = Data(base64Encoded: encoded), let source = String(data: data, encoding: .utf8) else {
            throw NotesError.message("This text uses an unsupported encoding. Its original data has been retained.")
        }
        var output = ""
        var offset = source.startIndex
        for match in marker.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            output += try decodeRun(String(source[offset..<range.lowerBound]))
            offset = range.upperBound
        }
        output += try decodeRun(String(source[offset...]))
        return output
    }
    static func decodeRun(_ value: String) throws -> String {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        let compact = value.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact),
              let text = String(data: data, encoding: .utf8) else {
            throw NotesError.message("This text includes an unsupported span. Export the original document to retain it.")
        }
        return text
    }
    static func encode(_ text: String) -> String {
        let count = text.utf16.count
        let header = "<?a 'paragraph/alignment'='0' 'paragraph/parsingState'='False' 'span/fontSize'='1,12' 'span/foregroundColor'='1,-14342875' 'sectionData/sectionData'='\(count)'?>"
        // Every style opened in the header must be closed here: Samsung's rich-text parser rejects a note whose
        // paragraph style is left open ("Wrong Annotater Type", the phone then cannot open or sync the note).
        let tail = "<?a 'span/foregroundColor' 'span/fontSize' 'paragraph/alignment' 'paragraph/parsingState' 'sectionData/sectionData'?><?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>"
        return Data((header + Data(text.utf8).base64EncodedString() + tail).utf8).base64EncodedString()
    }
}

struct NoteRecord: Identifiable, Codable {
    var id: String
    var resourceID: String
    var commit: String
    var modified: Double
    var locked: Bool
    var encrypted: Bool
    var title: String = "Untitled"
    var snippet: String = ""
    var folder: String = ""
    var trashed: Bool = false
    /// When the note was moved to the Trash (milliseconds), from its tree node.
    var trashedTime: Double? = nil
    /// Days until Samsung Notes deletes a trashed note for good: it empties its Trash after 30 days.
    func daysLeftInTrash(now: Date = Date()) -> Int? {
        guard trashed, let moved = trashedTime, moved > 0 else { return nil }
        return max(0, 30 - Int((now.timeIntervalSince1970 * 1000 - moved) / 86_400_000))
    }
}
struct FolderRecord: Identifiable, Codable { var id: String; var name: String; var parent: String }
/// A folder and its subfolders for outline views. `children` is nil for a leaf, so no disclosure arrow is shown.
struct FolderNode: Identifiable { var folder: FolderRecord; var children: [FolderNode]?; var id: String { folder.id } }
extension Array where Element == FolderRecord {
    /// Top-level folders with subfolders nested under their parents, in the array's order.
    /// Folders whose parent is missing (for example trashed) or whose parent chain loops are shown at the top level.
    var tree: [FolderNode] {
        let byID = Dictionary(map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func parentKey(_ folder: FolderRecord) -> String {
            var seen: Set<String> = [folder.id], current = folder.parent
            while let next = byID[current] {
                if !seen.insert(current).inserted { return "" }
                current = next.parent
            }
            return byID[folder.parent] == nil ? "" : folder.parent
        }
        let byParent = Dictionary(grouping: self, by: parentKey)
        func nodes(_ parent: String) -> [FolderNode] {
            (byParent[parent] ?? []).map { folder in
                let children = nodes(folder.id)
                return FolderNode(folder: folder, children: children.isEmpty ? nil : children)
            }
        }
        return nodes("")
    }
    /// The folder's names from the top level down, joined with "/", for example "Dev/Repos".
    func path(of id: String) -> String {
        var names: [String] = [], current = id, seen: Set<String> = []
        while let folder = first(where: { $0.id == current }), seen.insert(current).inserted {
            names.insert(folder.name, at: 0); current = folder.parent
        }
        return names.joined(separator: "/")
    }
}
struct CloudIndex: Codable { var notes: [NoteRecord]; var folders: [FolderRecord] }
func decodedCloudName(_ value: String) -> String {
    guard let data = Data(base64Encoded: value), let decoded = String(data: data, encoding: .utf8),
          !decoded.isEmpty, !decoded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return value }
    return String(String.UnicodeScalarView(decoded.unicodeScalars.filter { $0.value != 0x200b && $0.value != 0xfeff }))
}
struct AssetRecord: Identifiable {
    var id: String; var name: String; var url: URL?
    var fileName: String { name.components(separatedBy: "@").dropFirst().joined(separator: "@").nonEmpty ?? name }
    var isInternal: Bool { ["spi", "spd", "page", "dat"].contains((fileName as NSString).pathExtension.lowercased()) }
}
private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

final class CloudDocument {
    let serverID: String
    let xml: XMLDocument
    let resource: XMLElement
    let commit: String
    let bodyObject: XMLElement?
    let titleObject: XMLElement?
    var body: String
    var title: String
    var assets: [AssetRecord] = []
    let original: Data
    let textIssue: String?
    var drawingPages: [DrawingPage] = []
    init(serverID: String, data: Data) throws {
        self.serverID = serverID; self.original = data
        xml = try XMLDocument(data: data, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard let root = xml.rootElement(), root.name == "CompareNoteView",
              let resource = root.first("noteResource") else { throw NotesError.message("Samsung returned an unsupported note document.") }
        self.resource = resource
        commit = root.value("commitId")
        bodyObject = resource.first("bodyText")?.first("object")
        titleObject = resource.first("attributes")?.first("title")?.first("object")
        var issues: [String] = []
        do { body = try StyledText.decode(bodyObject?.value("text") ?? "") }
        catch { body = ""; issues.append(error.localizedDescription) }
        do { title = try StyledText.decode(titleObject?.value("text") ?? "") }
        catch { title = ""; issues.append(error.localizedDescription) }
        textIssue = issues.isEmpty ? nil : issues.joined(separator: " ")
        let contentFiles = resource.first("contentFileList")?.elements(forName: "contentFile") ?? []
        for download in root.first("downloadUrls")?.elements(forName: "downloadUrl") ?? [] {
            let id = download.value("id")
            guard let url = URL(string: download.value("url")), url.scheme == "https",
                  let host = url.host, host == "samsungcloud.com" || host.hasSuffix(".samsungcloud.com") else { continue }
            let file = contentFiles.first(where: { $0.attr("id") == id })
            assets.append(AssetRecord(id: id, name: decodedCloudName(file?.attr("name") ?? id), url: url))
        }
        if root.first("downloadUrls") == nil {
            for file in contentFiles {
                assets.append(AssetRecord(id: file.attr("id"), name: decodedCloudName(file.attr("name")), url: nil))
            }
        }
        drawingPages = (resource.first("pageList")?.elements(forName: "page") ?? []).enumerated().compactMap { index, page in DrawingPage(page, index: index) }
    }
    func uploadXML(title newTitle: String, body newBody: String, now: Date = Date()) throws -> Data {
        if let textIssue { throw NotesError.message(textIssue) }
        if resource.attr("isEncrypted") == "true" || resource.attr("isLocked") == "true" {
            throw NotesError.message("Locked or encrypted notes cannot be edited by this version.")
        }
        // Repair objects an earlier version of this client left unreadable on Samsung devices (see updateObject).
        if let object = bodyObject, let tree = resource.first("noteTree")?.first("bodyText"), Int32(object.attr("timeStamp")) == nil, !object.attr("timeStamp").isEmpty {
            updateObject(object, tree: tree, now: now)
        }
        if let object = titleObject, Int32(object.attr("timeStamp")) == nil, !object.attr("timeStamp").isEmpty {
            object.set("timeStamp", "0"); object.set("modifiedTime", String(Int64(now.timeIntervalSince1970 * 1_000_000))); object.set("hash", hash(object.bytes))
        }
        if body != newBody {
            guard let object = bodyObject, let text = object.first("text"),
                  let tree = resource.first("noteTree")?.first("bodyText") else {
                throw NotesError.message("This note has no supported typed-text body. Its drawings are retained in the original document.")
            }
            text.stringValue = StyledText.encode(newBody)
            Self.dropSpanOrder(object)
            updateObject(object, tree: tree, now: now)
        }
        if title != newTitle {
            guard let object = titleObject else { throw NotesError.message("This note's title cannot be edited yet.") }
            Self.dropSpanOrder(object)
            if let field = object.first("text") { field.stringValue = StyledText.encode(newTitle) }
            else { object.addChild(XMLElement(name: "text", stringValue: StyledText.encode(newTitle))) }
            object.set("modifiedTime", String(Int64(now.timeIntervalSince1970 * 1_000_000)))
            object.set("hash", hash(object.bytes))
        }
        let micros = String(Int64(now.timeIntervalSince1970 * 1_000_000))
        if let attrs = resource.first("attributes") {
            attrs.set("modifiedTime", micros); attrs.set("editTime", micros)
            attrs.set("displayModifiedTime", String(Int64(now.timeIntervalSince1970 * 1000)))
        }
        return resource.bytes
    }
    /// Removes an object's span order data, which describes the styled runs of the text being replaced; the new text is
    /// one plain run. The whole list goes: Samsung Notes reads at least one entry from any list present, and fails to
    /// open the note ("Spen SDK can't parse a xml note") when the list is empty.
    static func dropSpanOrder(_ object: XMLElement) {
        object.first("spanOrderDataList")?.detach()
    }
    private func updateObject(_ object: XMLElement, tree: XMLElement, now: Date) {
        let micros = String(Int64(now.timeIntervalSince1970 * 1_000_000))
        object.set("modifiedTime", micros)
        // Samsung Notes reads timeStamp as a 32-bit integer (real notes keep 0). Earlier versions of this client wrote a
        // microsecond time there, which the phone cannot parse ("Spen SDK can't parse a xml note"), so such values are reset.
        let stamp = object.attr("timeStamp")
        if !stamp.isEmpty, Int32(stamp) == nil { object.set("timeStamp", "0") }
        let digest = hash(object.bytes)
        object.set("hash", digest); tree.set("h", digest); tree.set("t", micros)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension CloudDocument {
    /// Why `self` cannot lend its structure to new notes, or nil if it can: it must be an unlocked, single-page typed-text
    /// note without attachments or drawings. Its title, text and span data are never copied (see `newNoteXML`).
    var templateIssue: String? {
        if resource.attr("isLocked") == "true" || resource.attr("isEncrypted") == "true" { return "Locked notes cannot be templates." }
        if let textIssue { return textIssue }
        if !(resource.first("contentFileList")?.elements(forName: "contentFile").isEmpty ?? true) || !drawingPages.isEmpty
            || (resource.first("pageList")?.elements(forName: "page").count ?? 0) > 1 { return "The template must be a single page without attachments or drawings." }
        if bodyObject == nil || titleObject == nil || resource.first("noteTree")?.first("bodyText") == nil { return "This note has no typed-text body or title to fill in." }
        return nil
    }
    /// The simplest of `documents` that can lend its structure to new notes, or nil if none can.
    static func templateCandidate(_ documents: [CloudDocument]) -> CloudDocument? {
        documents.filter { $0.templateIssue == nil }.min { $0.original.count < $1.original.count }
    }
    /// The `NoteResource` for a brand-new note built from `template`, a typed-text note as downloaded with
    /// `compareForDownsync`. Every id is replaced with a fresh one wherever it appears, so the note tree still
    /// matches its page, layer, title and body objects; the note gets `id`. The template's title, text and span
    /// order data are replaced or removed, rewritten elements get fresh hashes, and all times are now (Samsung
    /// stores `syncModifiedTime` as sent).
    static func newNoteXML(template: Data, id: String, title: String, body: String, now: Date = Date()) throws -> Data {
        let original = try CloudDocument(serverID: "template", data: template)
        if let issue = original.templateIssue { throw NotesError.message(issue) }
        var source = String(decoding: template, as: UTF8.self)
        let pattern = try NSRegularExpression(pattern: "id=\"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\"")
        let ids = Set(pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
        for old in ids { source = source.replacingOccurrences(of: "\"\(old)\"", with: "\"\(old == original.resource.attr("id") ? id : UUID().uuidString.lowercased())\"") }
        let document = try CloudDocument(serverID: "new", data: Data(source.utf8))
        guard let bodyObject = document.bodyObject, let bodyTree = document.resource.first("noteTree")?.first("bodyText"),
              let titleObject = document.titleObject else { throw NotesError.message("The template lost its text objects.") }
        let millis = String(Int64(now.timeIntervalSince1970 * 1000)), micros = String(Int64(now.timeIntervalSince1970 * 1_000_000))
        // Samsung Notes writes the resource's createdTime in microseconds and its syncModifiedTime in milliseconds.
        document.resource.set("createdTime", micros); document.resource.set("syncModifiedTime", millis)
        if let attributes = document.resource.first("attributes") {
            attributes.set("displayCreatedTime", millis); attributes.set("displayModifiedTime", millis)
            attributes.set("modifiedTime", micros); attributes.set("editTime", micros)
        }
        for object in [bodyObject, titleObject] { Self.dropSpanOrder(object) }
        if let text = bodyObject.first("text") { text.stringValue = StyledText.encode(body) }
        else { bodyObject.addChild(XMLElement(name: "text", stringValue: StyledText.encode(body))) }
        document.updateObject(bodyObject, tree: bodyTree, now: now)
        if let text = titleObject.first("text") { text.stringValue = title.isEmpty ? "" : StyledText.encode(title) }
        else if !title.isEmpty { titleObject.addChild(XMLElement(name: "text", stringValue: StyledText.encode(title))) }
        titleObject.set("modifiedTime", micros); titleObject.set("hash", document.hash(titleObject.bytes))
        // The page holds the layer, so the layer is hashed first. Samsung matches each note tree entry to its element by
        // id + time + hash (`t` must equal the element's `modifiedTime`, `h` its `hash`), so both are set together.
        let pages = document.resource.first("pageList")?.elements(forName: "page") ?? []
        let treePages = document.resource.first("noteTree")?.first("pageList")?.elements(forName: "page") ?? []
        for page in pages {
            let treePage = treePages.first { $0.attr("id") == page.attr("id") }
            for layer in page.first("layerList")?.elements(forName: "layer") ?? [] {
                layer.set("modifiedTime", micros); layer.set("hash", document.hash(layer.bytes))
                if let treeLayer = treePage?.first("layerList")?.elements(forName: "layer").first(where: { $0.attr("id") == layer.attr("id") }) {
                    treeLayer.set("h", layer.attr("hash")); treeLayer.set("t", micros)
                }
            }
            page.set("modifiedTime", micros); page.set("hash", document.hash(page.bytes))
            treePage?.set("h", page.attr("hash")); treePage?.set("t", micros)
        }
        // Samsung Notes names the upload's root NoteResource; the download calls it noteResource.
        var xml = String(decoding: document.resource.bytes, as: UTF8.self)
        if xml.hasPrefix("<noteResource") { xml = "<NoteResource" + xml.dropFirst("<noteResource".count) }
        if xml.hasSuffix("</noteResource>") { xml = String(xml.dropLast("</noteResource>".count)) + "</NoteResource>" }
        return Data(xml.utf8)
    }
}

private final class CloudRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var redirected = request
        if request.url?.host != task.originalRequest?.url?.host { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(redirected)
    }
}

final class CloudClient {
    private(set) var account: AccountSession
    private let transport: URLSession
    private let base = URL(string: "https://api.samsungcloud.com")!
    init(account: AccountSession) {
        self.account = account
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.httpCookieStorage = nil
        transport = URLSession(configuration: configuration, delegate: CloudRedirectDelegate(), delegateQueue: nil)
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> Data {
        guard path.hasPrefix("/"), let url = URL(string: path, relativeTo: base), url.host == base.host else { throw NotesError.message("Invalid Samsung Cloud path.") }
        if account.nativeID != nil { account = try await SamsungSignIn.shared.renew(account) }
        for attempt in 0...1 {
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue(account.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("5500", forHTTPHeaderField: "x-sn-sdk-ver")
        request.setValue("4000", forHTTPHeaderField: "x-sn-app-ver")
        request.setValue("2", forHTTPHeaderField: "X-SN-XML-VER")
        request.setValue("O4vARCbQ3G", forHTTPHeaderField: "X-SN-Feature-ID")
        request.setValue(ClientPlatform.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Data(ClientPlatform.model.utf8).base64EncodedString(), forHTTPHeaderField: "x-sn-model-name")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotesError.message("No response from Samsung Cloud.") }
        if http.statusCode == 401 || http.statusCode == 403 {
            if account.nativeID != nil, attempt == 0 { account = try await SamsungSignIn.shared.renew(account, force: true); continue }
            throw NotesError.message(account.nativeID == nil ? "This imported connection expired. Sign in with Samsung on this device, or import a refreshed Windows connection." : "Samsung rejected the renewed connection. Sign in with Samsung again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
            let message = xml?.rootElement()?.value("message") ?? ""
            let details = Self.errorDetails(String(decoding: data.prefix(8192), as: UTF8.self))
            throw NotesError.message("Samsung Cloud returned \(http.statusCode)\(message.isEmpty ? "" : ": " + message)\(details.isEmpty ? "" : " (" + details + ")").")
        }
        return data
        }
        throw NotesError.message("Samsung could not renew the Notes connection.")
    }
    /// The `field`, `value` and `reason` entries of a Samsung `ErrorResource`, e.g. "id: 1234 duplicated", which say what a 4xx rejected.
    static func errorDetails(_ body: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "<(field|value|reason)>([^<]{1,200})</(?:field|value|reason)>") else { return "" }
        let parts = pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match -> (String, String)? in
            guard let kind = Range(match.range(at: 1), in: body), let value = Range(match.range(at: 2), in: body) else { return nil }
            return (String(body[kind]), String(body[value]))
        }
        return parts.map { $0.0 == "field" ? $0.1 + ":" : $0.1 }.joined(separator: " ")
    }
    static func initialCursor(_ type: String) -> String {
        let value: [String: Any] = ["version": 0, "encryptedGuid": "", "requestTimeStamp": 0,
            "modifiedTime": 0, "appVersion": "0", "sdkVersion": "0", "purpose": "INITIAL", "type": type]
        return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).base64EncodedString()
    }
    func loadIndex() async throws -> CloudIndex {
        var cursor = Self.initialCursor("NOTE")
        var notes: [String: NoteRecord] = [:]
        var seen = Set<String>()
        var completed = false
        for _ in 0..<10_000 {
            guard seen.insert(cursor).inserted else { throw NotesError.message("Samsung returned a repeated pagination cursor.") }
            let query = URLQueryItem(name: "lastChangePoint", value: cursor)
            var parts = URLComponents(); parts.queryItems = [query]
            let data = try await request("/samsungnotes/v1/notes/changes?" + parts.percentEncodedQuery!)
            let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
            guard let root = document.rootElement(), root.name == "NoteChangesView" else { throw NotesError.message("Samsung returned an unexpected note index.") }
            for change in root.elements(forName: "changes") {
                let id = change.value("serverId")
                if change.value("isDeleted") == "true" { notes.removeValue(forKey: id); continue }
                notes[id] = NoteRecord(id: id, resourceID: change.value("resourceId"), commit: change.value("commitId"),
                    modified: Double(change.value("serverModifiedTime")) ?? 0,
                    locked: change.value("isLocked") == "true", encrypted: change.value("isEncrypted") == "true")
            }
            if root.value("hasNext") != "true" { completed = true; break }
            cursor = root.value("lastChangePoint")
            if cursor.isEmpty { throw NotesError.message("Samsung omitted the next pagination cursor.") }
        }
        guard completed else { throw NotesError.message("The note index exceeded the pagination limit.") }
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "lastChangePoint", value: Self.initialCursor("FOLDER"))]
        let folderData = try await request("/samsungnotes/v1/folder/changes?" + components.percentEncodedQuery!)
        let folderXML = try XMLDocument(data: folderData, options: [.nodeLoadExternalEntitiesNever])
        var folders: [FolderRecord] = []
        for node in folderXML.rootElement()?.first("folderResource")?.first("nodeList")?.elements(forName: "node") ?? [] {
            let state = node.value("state")
            if node.attr("type") == "folder", state == "normal" {
                folders.append(FolderRecord(id: node.attr("id"), name: decodedCloudName(node.value("name")), parent: node.value("parentFolderNodeId")))
            } else if node.attr("type") == "note" {
                if let id = notes.values.first(where: { $0.resourceID == node.attr("id") })?.id {
                    notes[id]?.folder = node.value("parentFolderNodeId")
                    notes[id]?.trashed = state == "trashed"
                    notes[id]?.trashedTime = Double(node.value("trashedTime"))
                    if state == "deleted" { notes.removeValue(forKey: id) }
                }
            }
        }
        return CloudIndex(notes: notes.values.sorted { $0.modified > $1.modified }, folders: folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    /// The `FolderResource` body Samsung Notes sends to create one folder with `PATCH /folder`; `order` places it after its siblings.
    static func newFolderXML(id: String, name: String, parent: String, order: Int, latestSync: Int64, now: Int64) -> Data {
        treeNodeXML(id: id, type: "folder", name: name, parent: parent, order: order, latestSync: latestSync, now: now)
    }
    /// A `FolderResource` holding one new tree node, as Samsung Notes 4.4.45 for Android sends it with `PATCH /folder`
    /// for a new folder, or for a new note before the note itself is uploaded (a note's node places it in a folder).
    /// Samsung stores the node's `syncModifiedTime` as sent and other devices only download nodes newer than their
    /// last change point, so the node is stamped with the current time and the resource with the newest time in the
    /// tree. The colour is Samsung's default (-1).
    static func treeNodeXML(id: String, type: String, name: String, parent: String, order: Int, latestSync: Int64, now: Int64) -> Data {
        folderResourceXML(TreeNodeFields(id: id, type: type, encodedName: Data(name.utf8).base64EncodedString(), parent: parent,
                                         order: order, created: now, modified: now), latestSync: latestSync, now: now)
    }
    /// One folder or note node as Samsung Notes writes it for `PATCH /folder`.
    struct TreeNodeFields {
        var id: String
        var type: String
        var encodedName: String
        var parent: String
        var state = "normal"
        var order: Int
        var color = -1
        var created: Int64
        var modified: Int64
        var trashed: Int64 = 0
        /// Where Restore puts a trashed node, e.g. "uncategorized:///Dev/Repos"; sent Base64-encoded.
        var restorePath: String? = nil
    }
    /// A `FolderResource` holding `node`, with its fields in Samsung Notes' order. The node is stamped with the current
    /// time (`syncModifiedTime`) and, like Samsung Notes, names the device for changes other than normal ones.
    static func folderResourceXML(_ node: TreeNodeFields, latestSync: Int64, now: Int64) -> Data {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var device = ["model": ClientPlatform.model, "ver": appShortVersion]
        if node.state != "normal" { device["deviceName"] = Data(ClientPlatform.model.utf8).base64EncodedString() }
        let deviceJSON = (try? JSONSerialization.data(withJSONObject: device, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let restore = node.restorePath.map { "<restorePath>\(Data($0.utf8).base64EncodedString())</restorePath>" } ?? ""
        let xml = "<node id=\"\(escaped(node.id))\" type=\"\(escaped(node.type))\"><parentFolderNodeId>\(escaped(node.parent))</parentFolderNodeId>"
            + "<syncModifiedTime>\(now)</syncModifiedTime><createdTime>\(node.created)</createdTime><lastModifiedTime>\(node.modified)</lastModifiedTime>"
            + "<name>\(escaped(node.encodedName))</name><state>\(escaped(node.state))</state>\(restore)<trashedTime>\(node.trashed)</trashedTime>"
            + "<color>\(node.color)</color><order>\(node.order)</order><requestTime>\(now)</requestTime><requestDevice>\(escaped(deviceJSON))</requestDevice></node>"
        return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><FolderResource><syncModifiedTime>\(max(latestSync, now))</syncModifiedTime><nodeList>\(xml)</nodeList></FolderResource>".utf8)
    }
    /// The restore path Samsung Notes records for something in `folder` ("root" for the top level).
    static func restorePath(of folder: String, folders: [FolderRecord]) -> String {
        "uncategorized:///" + (folder == "root" ? "" : folders.path(of: folder))
    }
    /// The folder a restore path points to, or "root" when it names the top level or a folder that no longer exists.
    static func restoreParent(_ restorePath: String, folders: [FolderRecord]) -> String {
        guard restorePath.hasPrefix("uncategorized:///") else { return "root" }
        let path = String(restorePath.dropFirst("uncategorized:///".count))
        return path.isEmpty ? "root" : folders.first { folders.path(of: $0.id) == path }?.id ?? "root"
    }
    /// The account's whole folder tree (folder and note nodes) exactly as Samsung returns it.
    func folderTreeXML() async throws -> Data {
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "lastChangePoint", value: Self.initialCursor("FOLDER"))]
        return try await request("/samsungnotes/v1/folder/changes?" + components.percentEncodedQuery!)
    }
    /// The folder and note nodes of the account's tree, with names decoded.
    func treeNodes() async throws -> [(id: String, type: String, parent: String, state: String, name: String, synced: Int64)] {
        let xml = try XMLDocument(data: try await folderTreeXML(), options: [.nodeLoadExternalEntitiesNever])
        return (xml.rootElement()?.first("folderResource")?.first("nodeList")?.elements(forName: "node") ?? []).map {
            (id: $0.attr("id"), type: $0.attr("type"), parent: $0.value("parentFolderNodeId"), state: $0.value("state"),
             name: decodedCloudName($0.value("name")), synced: Int64($0.value("syncModifiedTime")) ?? 0)
        }
    }
    /// Creates a folder under `parent` ("root" for the top level) the way Samsung Notes does, then reads the
    /// tree back to confirm Samsung stored it. Built-in folders such as Math notes cannot hold subfolders.
    func createFolder(named rawName: String, in parent: String) async throws -> FolderRecord {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw NotesError.message("Folder names need 1 to 100 characters and no \"/\".")
        }
        guard !parent.contains(":///") else { throw NotesError.message("Built-in folders cannot contain subfolders.") }
        let tree = try await treeNodes()
        let folders = tree.filter { $0.type == "folder" && $0.state == "normal" }
        if parent != "root", !folders.contains(where: { $0.id == parent }) { throw NotesError.message("The parent folder no longer exists. Refresh and try again.") }
        let siblings = folders.filter { $0.parent == parent }
        if siblings.contains(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            throw NotesError.message("A folder named \"\(name)\" already exists there.")
        }
        let id = UUID().uuidString.lowercased()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let body = Self.newFolderXML(id: id, name: name, parent: parent, order: siblings.count, latestSync: tree.map(\.synced).max() ?? 0, now: now)
        _ = try await request("/samsungnotes/v1/folder", method: "PATCH", body: body, contentType: "application/xml;Charset=utf-8")
        guard try await treeNodes().contains(where: { $0.id == id && $0.state == "normal" && $0.name == name }) else {
            throw NotesError.message("Samsung accepted the request, but the new folder did not appear. Refresh before trying again.")
        }
        return FolderRecord(id: id, name: name, parent: parent)
    }
    /// Creates a text note in `folder` ("root" for none) the way Samsung Notes does: its tree node goes up first with
    /// `PATCH /folder`, then the note itself with `POST /notes`, built from `template` (see `CloudDocument.newNoteXML`).
    /// The note is downloaded again to confirm its title and text. Returns the new note as Samsung stores it.
    func createNote(title rawTitle: String, body: String, in folder: String, template: Data) async throws -> CloudDocument {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.contains(":///") else { throw NotesError.message("Built-in folders cannot hold new notes from this app.") }
        let tree = try await treeNodes()
        if folder != "root", !tree.contains(where: { $0.id == folder && $0.type == "folder" && $0.state == "normal" }) {
            throw NotesError.message("That folder no longer exists. Refresh and try again.")
        }
        let id = UUID().uuidString.lowercased(), now = Date()
        let xml = try CloudDocument.newNoteXML(template: template, id: id, title: title, body: body, now: now)
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        // Samsung Notes places a new note (order 999999 = after existing notes) before uploading it.
        let node = Self.treeNodeXML(id: id, type: "note", name: title.isEmpty ? " " : title, parent: folder, order: 999_999,
                                    latestSync: tree.map(\.synced).max() ?? 0, now: millis)
        _ = try await request("/samsungnotes/v1/folder", method: "PATCH", body: node, contentType: "application/xml;Charset=utf-8")
        let boundary = "SamsungNotesMac-" + UUID().uuidString
        var payload = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"noteResource\"\r\nContent-Type: application/xml\r\n\r\n".utf8)
        payload.append(xml); payload.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await request("/samsungnotes/v1/notes", method: "POST", body: payload, contentType: "multipart/form-data; boundary=\(boundary)")
        let view = try XMLDocument(data: response, options: [.nodeLoadExternalEntitiesNever]).rootElement()
        let serverID = view.map { $0.value("resourceId").isEmpty ? $0.attr("resourceId") : $0.value("resourceId") } ?? ""
        guard !serverID.isEmpty else { throw NotesError.message("Samsung queued the new note without an id yet. Refresh in a minute to see it.") }
        let fresh = try await download(serverID)
        guard fresh.title == title, fresh.body == body else { throw NotesError.message("Samsung created the note, but its readback differs. Refresh and check it before editing.") }
        return fresh
    }
    /// Moves a note to the Trash ("trashed"), back out of it ("normal") or marks it deleted ("deleted") by rewriting its
    /// tree node as Samsung Notes does: a trashed note sits at the top level with its folder kept in `restorePath`, and
    /// Samsung Notes deletes it for good 30 days after `trashedTime`. A restored note goes back to that folder, or to the
    /// top level if the folder is gone. The tree is read again to confirm the change.
    func setNoteState(_ note: NoteRecord, to state: String, folders: [FolderRecord]) async throws {
        let xml = try XMLDocument(data: try await folderTreeXML(), options: [.nodeLoadExternalEntitiesNever])
        let nodes = xml.rootElement()?.first("folderResource")?.first("nodeList")?.elements(forName: "node") ?? []
        guard let node = nodes.first(where: { $0.attr("id") == note.resourceID && $0.attr("type") == "note" }) else {
            throw NotesError.message("Samsung Cloud no longer lists this note. Refresh and try again.")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let saved = Data(base64Encoded: node.value("restorePath")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var fields = TreeNodeFields(id: note.resourceID, type: "note", encodedName: node.value("name"), parent: node.value("parentFolderNodeId"),
                                    state: state, order: Int(node.value("order")) ?? 999_999, color: Int(node.value("color")) ?? -1,
                                    created: Int64(node.value("createdTime")) ?? now, modified: Int64(node.value("lastModifiedTime")) ?? now,
                                    trashed: Int64(node.value("trashedTime")) ?? 0, restorePath: saved.isEmpty ? nil : saved)
        switch state {
        case "trashed": fields.restorePath = Self.restorePath(of: fields.parent, folders: folders); fields.parent = "root"; fields.trashed = now
        case "normal": fields.parent = Self.restoreParent(saved, folders: folders); fields.restorePath = Self.restorePath(of: fields.parent, folders: folders); fields.trashed = 0
        default: fields.parent = "root"; if fields.trashed == 0 { fields.trashed = now }
        }
        let latest = nodes.compactMap { Int64($0.value("syncModifiedTime")) }.max() ?? 0
        _ = try await request("/samsungnotes/v1/folder", method: "PATCH", body: Self.folderResourceXML(fields, latestSync: latest, now: now),
                              contentType: "application/xml;Charset=utf-8")
        guard try await treeNodes().contains(where: { $0.id == note.resourceID && $0.state == state }) else {
            throw NotesError.message("Samsung accepted the change, but the note's state did not update. Refresh and check it.")
        }
    }
    /// Deletes a note in the Trash for good, as Samsung Notes does from its Trash: the tree node becomes "deleted",
    /// then the note itself is removed with `DELETE /notes/{id}?syncModifiedTime=…`. Notes outside the Trash are refused.
    func deleteNote(_ note: NoteRecord, folders: [FolderRecord]) async throws {
        guard note.trashed else { throw NotesError.message("Only notes in the Trash can be deleted for good. Move it to the Trash first.") }
        try await setNoteState(note, to: "deleted", folders: folders)
        try await deleteNoteResource(id: note.id, serverModified: Int64(note.modified))
    }
    /// `DELETE /notes/{id}`. Samsung requires the note's last known server time and refuses (409) when the note changed
    /// since; 404 means it is already gone.
    func deleteNoteResource(id: String, serverModified: Int64) async throws {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw NotesError.message("Invalid note identifier.") }
        _ = try await request("/samsungnotes/v1/notes/\(id)?syncModifiedTime=\(serverModified)", method: "DELETE")
    }
    func download(_ id: String) async throws -> CloudDocument {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw NotesError.message("Invalid note identifier.") }
        let data = try await request("/samsungnotes/v1/notes/\(id)/compareForDownsync", method: "POST", body: Data("<note ver=\"1\"/>".utf8), contentType: "application/xml")
        return try CloudDocument(serverID: id, data: data)
    }
    func currentCommit(_ id: String) async throws -> String {
        let data = try await request("/samsungnotes/v1/notes/\(id)/info")
        guard let value = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]).rootElement()?.attr("commitId"), !value.isEmpty else { throw NotesError.message("Samsung omitted the current revision.") }
        return value
    }
    /// Why a save was refused because the note has a newer revision in Samsung Cloud.
    static let changedElsewhere = "This note changed on another device. Your draft is saved locally; reload the cloud copy before saving again."
    func save(_ document: CloudDocument, title: String, body: String) async throws -> CloudDocument {
        let remoteCommit = try await currentCommit(document.serverID)
        guard remoteCommit == document.commit else { throw NotesError.message(Self.changedElsewhere) }
        try LocalStore.backup(document)
        let xml = try document.uploadXML(title: title, body: body)
        let boundary = "SamsungNotesMac-" + UUID().uuidString
        var payload = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"noteResource\"\r\nContent-Type: application/xml\r\n\r\n".utf8)
        payload.append(xml); payload.append(Data("\r\n--\(boundary)--\r\n".utf8))
        _ = try await request("/samsungnotes/v1/notes/\(document.serverID)/update", method: "POST", body: payload, contentType: "multipart/form-data; boundary=\(boundary)")
        let fresh = try await download(document.serverID)
        guard fresh.body == body, fresh.title == title else { throw NotesError.message("Samsung accepted the upload, but its readback differs from the draft. The local draft and backup are retained.") }
        return fresh
    }
    func downloadAsset(_ asset: AssetRecord) async throws -> Data {
        guard let url = asset.url else { throw NotesError.message("Reload the note to retrieve this attachment from Samsung Cloud.") }
        if account.nativeID != nil { account = try await SamsungSignIn.shared.renew(account) }
        var request = URLRequest(url: url)
        request.setValue(account.authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NotesError.message("The attachment download failed. Reload the note to refresh its download URL.") }
        return data
    }
}

enum LocalStore {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SamsungCloudNotes", isDirectory: true)
    static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func backup(_ document: CloudDocument) throws {
        let destination = try directory("Backups").appendingPathComponent("\(document.serverID)-\(Int(Date().timeIntervalSince1970 * 1000)).xml")
        try document.original.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    /// The note whose structure new notes copy (its downloaded XML), kept only on this device.
    static var noteTemplate: Data? { try? Data(contentsOf: root.appendingPathComponent("NoteTemplate.xml")) }
    /// The saved template, or the simplest suitable note among `documents`, saved for next time.
    static func noteTemplate(choosingFrom documents: [CloudDocument]) throws -> Data {
        if let saved = noteTemplate { return saved }
        guard let candidate = CloudDocument.templateCandidate(documents) else {
            throw NotesError.message("No plain text note to copy Samsung's note layout from yet. Make a short text note on another device, refresh, and try again.")
        }
        try saveNoteTemplate(candidate)
        return candidate.original
    }
    static func saveNoteTemplate(_ document: CloudDocument) throws {
        if let issue = document.templateIssue { throw NotesError.message(issue) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("NoteTemplate.xml")
        try document.original.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Appends a failed cloud save (time, note id, reason; never note text) to SaveFailures.log for diagnosis.
    static func logSaveFailure(id: String, reason: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(id)\t\(reason.replacingOccurrences(of: "\n", with: " "))\n"
        let url = root.appendingPathComponent("SaveFailures.log")
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? Data(line.utf8).write(to: url, options: [.atomic]); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }
    static func writeDraft(id: String, title: String, body: String, commit: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["title": title, "body": body, "commit": commit])
        let url = try directory("Drafts").appendingPathComponent(id + ".json")
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func archiveDraft(id: String) throws {
        let source = try directory("Drafts").appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        let target = try directory("DraftHistory").appendingPathComponent("\(id)-\(Int(Date().timeIntervalSince1970 * 1000)).json")
        try data.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
