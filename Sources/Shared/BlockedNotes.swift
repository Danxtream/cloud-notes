// Licensed under GPL-3.0-only with an additional term under section 7(b); see LICENSE and NOTICE.md.

import Foundation
import CryptoKit

/// Notes the user keeps from Claude. `scnotes` (and so the Samsung Notes connector, which runs it) leaves them out of
/// lists and searches and refuses to open or change them, and this device keeps its copies of them encrypted (see
/// `LocalSeal`). The Mac app's Settings window writes the list: `BlockedNotes.json` holds note ids, which survive a
/// rename, and each note's title when it was blocked, for people reading the file.
enum BlockedNotes {
    struct Entry: Codable, Equatable { var id: String; var title: String }
    struct List: Codable { var version = 1; var notes: [Entry] = [] }
    static var url: URL { LocalStore.root.appendingPathComponent("BlockedNotes.json") }

    static func load() -> [Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(List.self, from: $0) }?.notes ?? []
    }
    static func ids() -> Set<String> { Set(load().map(\.id)) }
    static func contains(_ id: String) -> Bool { ids().contains(id) }

    /// Blocks or unblocks note `id`. Blocking writes the list first and then encrypts this device's copies, so the
    /// note is refused even if encryption fails; unblocking decrypts first and then takes the note off the list.
    static func set(_ id: String, title: String, blocked: Bool) throws {
        if !blocked { try LocalSeal.reseal(note: id, sealed: false) }
        var notes = load().filter { $0.id != id }
        if blocked { notes.append(Entry(id: id, title: title)) }
        try FileManager.default.createDirectory(at: LocalStore.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(List(notes: notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if blocked { try LocalSeal.reseal(note: id, sealed: true) }
    }
}

/// Encryption for this device's copies of blocked notes: AES-GCM with a key kept in the Keychain beside the Samsung
/// sign-in (`SessionStore.localKey`). A sealed file starts with `marker`; files without it are read as they are.
enum LocalSeal {
    static let marker = Data("SCN-SEALED-1\n".utf8)
    private static var cachedKey: SymmetricKey?
    static func key() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let key = SymmetricKey(data: try SessionStore.localKey())
        cachedKey = key
        return key
    }
    static func isSealed(_ data: Data) -> Bool { data.starts(with: marker) }
    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard !isSealed(data) else { return data }
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw NotesError.message("Could not encrypt the local copy.") }
        return marker + combined
    }
    static func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard isSealed(data) else { return data }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(marker.count)), using: key)
    }
    /// `data` encrypted with this device's key (unchanged if already sealed).
    static func seal(_ data: Data) throws -> Data { isSealed(data) ? data : try seal(data, with: key()) }
    /// `data` decrypted; unsealed data comes back as it is, without touching the Keychain.
    static func open(_ data: Data) throws -> Data { isSealed(data) ? try open(data, with: key()) : data }
    /// A local file's contents, decrypted if sealed; nil if it is missing or cannot be decrypted.
    static func read(_ url: URL) -> Data? { (try? Data(contentsOf: url)).flatMap { try? open($0) } }
    /// Writes a local file readable only by this user, sealed when `sealed`.
    static func write(_ data: Data, to url: URL, sealed: Bool) throws {
        try (sealed ? seal(data) : data).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Encrypts (`sealed`) or decrypts every copy this device keeps of note `id`: its cached document and the
    /// attachments of that revision for each signed-in account, its pre-save backups, its draft and archived drafts.
    /// Blocking also clears the note's text preview from the cached note list and drops the new-note template when it
    /// was copied from this note, as both hold some of its text.
    static func reseal(note id: String, sealed: Bool) throws {
        let files = FileManager.default
        var paths: [URL] = []
        let cacheRoot = LocalStore.root.appendingPathComponent("Cache", isDirectory: true)
        for account in (try? files.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? [] {
            let noteFile = account.appendingPathComponent(NoteCache.fileName(id, kind: "note"))
            if let data = try? Data(contentsOf: noteFile) {
                paths.append(noteFile)
                if let entry = try? JSONDecoder().decode(NoteCache.Entry.self, from: open(data)),
                   let document = try? CloudDocument(serverID: id, data: entry.xml) {
                    paths += document.assets.map { account.appendingPathComponent(NoteCache.fileName($0.id + ":" + entry.revision, kind: "asset")) }
                    if sealed, let template = LocalStore.noteTemplate,
                       (try? CloudDocument(serverID: "template", data: template))?.resource.attr("id") == document.resource.attr("id") {
                        try files.removeItem(at: LocalStore.root.appendingPathComponent("NoteTemplate.xml"))
                    }
                }
            }
            let index = account.appendingPathComponent("index.json")
            if sealed, let data = try? Data(contentsOf: index), var snapshot = try? JSONDecoder().decode(NoteCache.Snapshot.self, from: data),
               let position = snapshot.index.notes.firstIndex(where: { $0.id == id }), !snapshot.index.notes[position].snippet.isEmpty {
                snapshot.index.notes[position].snippet = ""
                try write(JSONEncoder().encode(snapshot), to: index, sealed: false)
            }
        }
        for folder in ["Backups", "DraftHistory"] {
            let directory = LocalStore.root.appendingPathComponent(folder, isDirectory: true)
            paths += ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(id + "-") }
        }
        paths.append(LocalStore.root.appendingPathComponent("Drafts", isDirectory: true).appendingPathComponent(id + ".json"))
        for path in paths where files.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            if isSealed(data) != sealed { try write(sealed ? data : open(data), to: path, sealed: sealed) }
        }
    }
}
