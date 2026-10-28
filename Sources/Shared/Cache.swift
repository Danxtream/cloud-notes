// Licensed under GPL-3.0-only with an additional term under section 7(b); see LICENSE and NOTICE.md.

import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Session-scoped, disposable local copies. Credentials are never written here.
final class NoteCache {
    struct Snapshot: Codable {
        var version = 1
        var updated: Date
        var index: CloudIndex
    }
    struct Entry: Codable {
        var revision: String
        var xml: Data
    }
    let root: URL
    init(session: AccountSession, base: URL = LocalStore.root.appendingPathComponent("Cache")) throws {
        // A generic display label is not an account identifier. Separate different
        // sessions even when both imports are labelled "Samsung account". Native
        // sign-ins retain the same cache across automatic token renewal.
        root = base.appendingPathComponent(Self.key(session.nativeID ?? session.authorization), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static func key(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// The file name for a cached note (`kind` "note", keyed by note id) or attachment ("asset", "id:revision").
    static func fileName(_ key: String, kind: String) -> String { kind + "-" + Self.key(key) }
    private func url(_ key: String, kind: String) -> URL { root.appendingPathComponent(Self.fileName(key, kind: kind)) }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func snapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 else { return nil }
        return snapshot
    }
    /// Saves the note list; blocked notes are saved without their text preview (see `BlockedNotes`).
    func saveIndex(_ index: CloudIndex, updated: Date = Date()) throws {
        var index = index
        let blocked = BlockedNotes.ids()
        for position in index.notes.indices where blocked.contains(index.notes[position].id) { index.notes[position].snippet = "" }
        try write(JSONEncoder().encode(Snapshot(updated: updated, index: index)), to: root.appendingPathComponent("index.json"))
    }
    func document(_ record: NoteRecord) -> CloudDocument? {
        guard !record.locked && !record.encrypted,
              let data = LocalSeal.read(url(record.id, kind: "note")),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.revision == record.commit else { return nil }
        return try? CloudDocument(serverID: record.id, data: entry.xml)
    }
    func save(_ document: CloudDocument, revision: String) throws {
        let xml = try XMLDocument(data: document.original, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        // Signed download URLs expire and may carry access parameters. Keep only
        // document data on disk; attachments already opened have their own cache.
        if let urls = xml.rootElement()?.first("downloadUrls") { urls.detach() }
        let entry = try JSONEncoder().encode(Entry(revision: revision, xml: Data(xml.xmlString.utf8)))
        try write(BlockedNotes.contains(document.serverID) ? LocalSeal.seal(entry) : entry, to: url(document.serverID, kind: "note"))
    }
    func asset(id: String, revision: String) -> Data? { LocalSeal.read(url(id + ":" + revision, kind: "asset")) }
    /// Caches an attachment; `sealed` for the attachments of a blocked note.
    func saveAsset(_ data: Data, id: String, revision: String, sealed: Bool = false) throws {
        try write(sealed ? LocalSeal.seal(data) : data, to: url(id + ":" + revision, kind: "asset"))
    }
    func prune(_ records: [NoteRecord]) throws {
        let keep = Set(records.filter { !$0.locked && !$0.encrypted }.map { url($0.id, kind: "note").lastPathComponent })
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("note-") && !keep.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
