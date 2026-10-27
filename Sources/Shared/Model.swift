import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit
import Combine

@MainActor final class NotesModel: ObservableObject {
    @Published var notes: [NoteRecord] = []
    @Published var folders: [FolderRecord] = []
    @Published var selection: String?
    @Published var folder = "all"
    @Published var search = ""
    @Published var title = ""
    @Published var body = ""
    /// The open note's text with its formatting, kept in step with `body` by an editor that shows formatting; nil
    /// when the note's formatting cannot be read. A plain-text editor leaves it behind, and its text is saved plain.
    @Published var styledBody: [RichRun]?
    @Published var status = "Connect your Samsung account to load your notes."
    @Published var busy = false
    @Published var draftConflict = false
    @Published var error: String?
    /// Cloud saves under way; autosave uploads in the background, so editing never waits for them.
    @Published var savesInFlight = 0
    /// Why the last save failed, shown next to Retry; nil after a successful save.
    @Published var saveError: String?
    @Published var lastSaved: Date?
    private var autosaveTask: Task<Void, Never>?
    /// An edit goes to Samsung Cloud one second after typing pauses, and at least every ten seconds during continuous
    /// typing. Uploads run in the background and text typed meanwhile is queued, so the editor never waits.
    static let autosaveDelay: UInt64 = 1_000_000_000
    static let autosaveMaxWait: TimeInterval = 10
    /// When the oldest edit not yet sent to Samsung Cloud was made.
    private var unsavedSince: Date?
    @Published var account = ""
    @Published var document: CloudDocument?
    @Published var pendingConnection: Data?
    @Published var importCode = ""
    private var client: CloudClient?
    private var cache: NoteCache?
    private(set) var downloadedNotes = 0
    private var loaded: [String: CloudDocument] = [:]
    private var generation = 0
    private var draftTask: Task<Void, Never>?
    /// Opens the newest note after loading. Compact layouts navigate on selection, so they opt out.
    var autoSelectFirst = true
    var dirty: Bool { document.map { $0.title != title || $0.body != body || (styledBody != nil && styledBody != $0.styledBody) } ?? false }
    /// `styledBody` as a draft stores it.
    private var styledDraft: String? { styledBody.map { RichText(runs: $0, defaults: document?.richBody?.commonStyles ?? RichText.defaultStyles).encoded } }
    var visibleNotes: [NoteRecord] {
        notes.filter { note in
            let inFolder = folder == "all" ? !note.trashed : folder == "trash" ? note.trashed
                : folder == "favorites" ? note.isFavorite && !note.trashed : note.folder == folder && !note.trashed
            return inFolder && (search.isEmpty || (note.title + " " + note.snippet).localizedCaseInsensitiveContains(search))
        }
    }
    var editable: Bool {
        guard let doc = document else { return false }
        return doc.resource.attr("isLocked") != "true" && doc.resource.attr("isEncrypted") != "true" && doc.textIssue == nil && folder != "trash" && !draftConflict
    }
    func connect(cacheOnly: Bool = false) async {
        do {
            let session = try transientSession ?? SessionStore.load()
            preserveDraft()
            client = CloudClient(account: session); account = session.account
            loaded = [:]; document = nil; selection = nil; notes = []; folders = []
            cache = try NoteCache(session: session)
            restoreCache()
            if let id = selection { await open(id) }
            if !cacheOnly { await refresh() }
        } catch { status = error.localizedDescription }
    }
    func signIn(useAnotherAccount: Bool = false) async {
        guard !busy else { return }
        busy = true; preserveDraft()
        do {
            let credentials: NativeCredentials
            if !useAnotherAccount, let saved = try NativeAuthStore.loadIfPresent() { credentials = saved; status = "Connecting your saved Samsung sign-in…" }
            else { credentials = try await SamsungSignIn.shared.signIn(status: { self.status = $0 }) }
            let session: AccountSession
            do { session = try await SamsungSignIn.shared.cloudSession(credentials) }
            catch let error as SamsungHTTPError where error.path.hasPrefix("/auth/oauth2/") && [400, 401, 403].contains(error.status) {
                status = "Samsung needs a new browser sign-in…"
                let fresh = try await SamsungSignIn.shared.signIn(status: { self.status = $0 })
                session = try await SamsungSignIn.shared.cloudSession(fresh)
            }
            status = "Checking Notes access…"
            _ = try await CloudClient(account: session).loadIndex()
            try SessionStore.save(session)
            busy = false
            await connect()
        } catch { busy = false; self.error = error.localizedDescription; status = "Samsung sign-in did not finish. Your existing notes and local drafts are retained." }
    }
    func signOut() {
        guard !busy else { return }
        do {
            if let document, dirty, !draftConflict {
                try LocalStore.writeDraft(id: document.serverID, title: title, body: body, commit: document.commit, styled: styledDraft)
            }
            try SamsungSignIn.shared.signOut()
            generation += 1
            draftTask?.cancel(); draftTask = nil
            transientSession = nil
            client = nil; cache = nil; loaded = [:]
            document = nil; selection = nil; notes = []; folders = []
            title = ""; body = ""; styledBody = nil; account = ""; folder = "all"; search = ""
            draftConflict = false; downloadedNotes = 0
            pendingConnection = nil; importCode = ""; error = nil
            status = "Signed out. Sign in with Samsung to load your notes."
        } catch { self.error = "Could not log out: " + error.localizedDescription }
    }
    func importConnection(_ data: Data, code: String = "") async {
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let sessionData: Data
            if let sealed = json?["sealed"] as? String {
                guard json?["format"] as? String == "samsung-cloud-notes-connection", json?["version"] as? Int == 1 else { throw NotesError.message("This connection file version is not supported.") }
                guard let keyData = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), keyData.count == 32,
                      let combined = Data(base64Encoded: sealed) else { throw NotesError.message("Paste the 44-character connection code shown by the Windows exporter.") }
                let box = try AES.GCM.SealedBox(combined: combined)
                sessionData = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            } else { sessionData = data }
            let session = try JSONDecoder().decode(AccountSession.self, from: sessionData)
            try SessionStore.save(session)
            pendingConnection = nil; importCode = ""
            await connect()
        } catch { self.error = "Could not import the connection: " + error.localizedDescription }
    }
    func restoreCache() {
        guard let snapshot = cache?.snapshot() else { return }
        notes = snapshot.index.notes; folders = snapshot.index.folders
        for record in notes {
            if let doc = cache?.document(record) { loaded[record.id] = doc }
        }
        if autoSelectFirst { selection = visibleNotes.first?.id }
        status = "Cached notes · Last synced " + snapshot.updated.formatted(date: .abbreviated, time: .shortened)
    }
    func refresh() async {
        guard let client, !busy else { return }
        preserveDraft()
        busy = true; downloadedNotes = 0
        status = notes.isEmpty ? "Reading Samsung Cloud…" : "Checking Samsung Cloud for changes…"
        defer { busy = false }
        do {
            let previous = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.commit) })
            let index = try await client.loadIndex()
            notes = index.notes; folders = index.folders
            let allowed = Set(notes.filter { !$0.locked && !$0.encrypted }.map(\.id))
            loaded = loaded.filter { allowed.contains($0.key) }
            var failures = 0
            for record in notes {
                if record.locked || record.encrypted { continue }
                var doc: CloudDocument?
                if previous[record.id] == record.commit, let existing = loaded[record.id] { doc = existing }
                else if let cached = cache?.document(record) { doc = cached; loaded[record.id] = cached }
                else {
                    do {
                        let fresh = try await client.download(record.id)
                        downloadedNotes += 1; loaded[record.id] = fresh; doc = fresh
                        try cache?.save(fresh, revision: record.commit)
                    } catch {
                        if error is CancellationError { throw error }
                        // Never label an old document as matching a new revision.
                        loaded.removeValue(forKey: record.id); doc = nil; failures += 1
                    }
                }
                if let doc, let i = notes.firstIndex(where: { $0.id == record.id }) { describe(i, document: doc) }
            }
            try cache?.prune(notes)
            try cache?.saveIndex(CloudIndex(notes: notes, folders: folders))
            if let id = selection, !notes.contains(where: { $0.id == id && !$0.locked && !$0.encrypted }) {
                selection = nil; document = nil
            }
            if selection == nil, autoSelectFirst { selection = visibleNotes.first?.id }
            // A local draft keeps its original cloud baseline for conflict checks.
            if let id = selection, !dirty { await open(id) }
            status = "\(notes.filter { !$0.trashed }.count) notes · Updated \(Date().formatted(date: .omitted, time: .shortened))"
            if failures > 0 { status += " · \(failures) notes could not be downloaded" }
        } catch let error as SamsungHTTPError where error.path.hasPrefix("/auth/oauth2/") && [400, 401, 403].contains(error.status) {
            status = "Samsung sign-in expired · Cached notes and drafts retained. Choose Sign in with Samsung to reconnect."
        } catch {
            status = notes.isEmpty ? "Could not reach Samsung Cloud. Try Refresh." : "Offline · Showing cached notes and local drafts. Try Refresh to reconnect."
            if notes.isEmpty { self.error = error.localizedDescription }
        }
    }
    /// Where a new folder goes: inside the selected folder, or at the top level when All notes, Trash or a built-in folder is selected.
    var newFolderParent: String { folders.contains { $0.id == folder } && !folder.contains(":///") ? folder : "root" }
    /// Creates a folder in Samsung Cloud, refreshes the library and selects the new folder.
    func createFolder(named name: String) async {
        guard let client, !busy else { return }
        busy = true; status = "Creating folder…"
        do {
            let created = try await client.createFolder(named: name, in: newFolderParent)
            busy = false
            await refresh()
            folder = created.id
            status = "Created folder \(created.name)"
        } catch { busy = false; self.error = error.localizedDescription; status = "The folder was not created." }
    }
    /// Creates a text note in the selected folder (none for All notes, Trash or a built-in folder), refreshes the
    /// library and opens the new note. The first time, the simplest cached text note lends its structure.
    func createNote(title: String) async {
        guard let client, !busy else { return }
        busy = true; status = "Creating note…"
        do {
            let template = try LocalStore.noteTemplate(choosingFrom: notes.compactMap { loaded[$0.id] ?? cache?.document($0) })
            let created = try await client.createNote(title: title, body: "", in: newFolderParent, template: template)
            busy = false
            await refresh()
            selection = created.serverID
            status = "Created note \(created.title.isEmpty ? "(untitled)" : created.title)"
        } catch { busy = false; self.error = error.localizedDescription; status = "The note was not created." }
    }
    /// Stars or unstars a note through the usual save path (one upload per note), so it can't collide with an autosave.
    /// An open note keeps its current text; another note is downloaded first so the star goes onto the newest revision.
    func setFavorite(_ id: String, _ on: Bool) async {
        guard let client else { return }
        do {
            let isOpen = selection == id && document != nil
            let base = isOpen ? document! : try await client.download(id)
            if !isOpen { loaded[id] = base }
            starChanges[id] = on
            await upload(base, title: isOpen ? title : base.title, body: isOpen ? body : base.body, styled: isOpen ? styledBody : nil)
            if starChanges[id] == nil { status = on ? "Added to Favorites." : "Removed from Favorites." }
        } catch { self.error = error.localizedDescription }
    }
    enum NoteChange { case trash, restore, deleteForever }
    /// Moves a note to the Trash, restores it to its folder, or deletes it for good (only from the Trash), then
    /// refreshes the library. Samsung Notes deletes trashed notes for good after 30 days.
    func change(note id: String, _ change: NoteChange) async {
        guard let client, !busy, let note = notes.first(where: { $0.id == id }) else { return }
        preserveDraft(); busy = true
        status = change == .trash ? "Moving to Trash…" : change == .restore ? "Restoring…" : "Deleting…"
        do {
            switch change {
            case .trash: try await client.setNoteState(note, to: "trashed", folders: folders)
            case .restore: try await client.setNoteState(note, to: "normal", folders: folders)
            case .deleteForever: try await client.deleteNote(note, folders: folders)
            }
            busy = false
            if selection == id { selection = nil; document = nil }
            await refresh()
            status = change == .trash ? "Moved to Trash. Samsung Notes deletes it for good after 30 days."
                : change == .restore ? "Restored \(note.title)." : "Deleted \(note.title) for good."
        } catch { busy = false; self.error = error.localizedDescription; status = "The note was not changed." }
    }
    private func describe(_ index: Int, document: CloudDocument) { notes[index].describe(document) }
    func select(_ id: String?) async {
        autosaveTask?.cancel()
        preserveDraft()
        // Save the note being left in the background so the next one opens at once.
        if let document, dirty, !draftConflict {
            let title = self.title, body = self.body, styled = styledBody
            Task { await upload(document, title: title, body: body, styled: styled) }
        }
        if let id { await open(id) } else { document = nil }
    }
    func open(_ id: String, force: Bool = false) async {
        guard let client else { return }
        generation += 1; let taskGeneration = generation
        do {
            let doc: CloudDocument
            if !force, let cached = loaded[id] { doc = cached }
            else {
                doc = try await client.download(id); loaded[id] = doc
                if let record = notes.first(where: { $0.id == id }) { try cache?.save(doc, revision: record.commit) }
            }
            guard generation == taskGeneration, selection == id else { return }
            document = doc; title = doc.title; body = doc.body; styledBody = doc.styledBody; draftConflict = false
            if force {
                try LocalStore.archiveDraft(id: id)
                try LocalStore.writeDraft(id: id, title: doc.title, body: doc.body, commit: doc.commit)
            }
            if !force, let draftURL = try? LocalStore.directory("Drafts").appendingPathComponent(id + ".json"),
               let draft = try? Data(contentsOf: draftURL),
               let values = try? JSONSerialization.jsonObject(with: draft) as? [String: String],
               let draftTitle = values["title"], let draftBody = values["body"],
               draftBody != doc.body || draftTitle != doc.title || (values["styled"] != nil && values["styled"] != doc.bodyObject?.value("text")) {
                title = draftTitle; body = draftBody
                styledBody = values["styled"].flatMap { try? RichText(encoded: $0) }.map { RichText.numbered($0.styledRuns) }
                draftConflict = values["commit"] != doc.commit
                status = draftConflict ? "Draft is based on an older revision. Reload to archive it and use the cloud copy." : "Recovered unsaved changes; saving them to Samsung Cloud."
            }
        } catch {
            guard generation == taskGeneration, selection == id else { return }
            self.error = error.localizedDescription
        }
    }
    func preserveDraft() {
        guard let document, dirty, !draftConflict else { return }
        do { try LocalStore.writeDraft(id: document.serverID, title: title, body: body, commit: document.commit, styled: styledDraft) }
        catch { self.error = "Could not save your local draft: " + error.localizedDescription }
    }
    func scheduleDraft() {
        draftTask?.cancel()
        draftTask = Task { try? await Task.sleep(nanoseconds: 600_000_000); if !Task.isCancelled { preserveDraft() } }
    }
    /// Called for every change to the title or text: keeps a local draft at once and saves to Samsung Cloud after a pause.
    func edited() { scheduleDraft(); scheduleAutosave() }
    func scheduleAutosave() {
        autosaveTask?.cancel()
        guard dirty, editable else { unsavedSince = nil; return }
        let since = unsavedSince ?? Date(); unsavedSince = since
        let wait = Date().timeIntervalSince(since) >= Self.autosaveMaxWait ? 0 : Self.autosaveDelay
        autosaveTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            guard !Task.isCancelled else { return }
            // The upload gets its own task: this timer is cancelled by the next keystroke (and by save itself), and
            // cancelling a task aborts its network requests ("cancelled").
            Task { await self?.save() }
        }
    }
    /// One line on where the open note stands: saving, saved, not saved, or changes waiting for the next autosave.
    var saveStatus: String {
        if draftConflict { return "Not saved: changed on another device" }
        if savesInFlight > 0 { return "Saving…" }
        if let saveError { return "Not saved: " + saveError }
        if dirty { return "Unsaved changes" }
        return lastSaved.map { "Saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "Saved"
    }
    /// Saves the open note now (autosave, Retry). While another operation runs it tries again after the usual pause.
    func save() async {
        guard let document, dirty, !draftConflict else { return }
        if busy { scheduleAutosave(); return }
        autosaveTask?.cancel(); unsavedSince = nil
        preserveDraft()
        await upload(document, title: title, body: body, styled: styledBody)
    }
    /// Saves `title` and `body` of `document`, one upload per note at a time: a second upload from the same revision
    /// would be refused as a conflict, so text that arrives during an upload is queued and sent from the fresh revision.
    private func upload(_ document: CloudDocument, title: String, body: String, styled: [RichRun]?) async {
        let id = document.serverID
        guard !uploading.contains(id) else { queued[id] = (title, body, styled); return }
        uploading.insert(id); defer { uploading.remove(id) }
        var base = document, nextTitle = title, nextBody = body, nextStyled = styled
        while let fresh = await uploadOnce(base, title: nextTitle, body: nextBody, styled: nextStyled), let next = queued.removeValue(forKey: id),
              next.title != fresh.title || next.body != fresh.body || (next.styled != nil && next.styled != fresh.styledBody) || starChanges[id] != nil {
            base = fresh; nextTitle = next.title; nextBody = next.body; nextStyled = next.styled
        }
        queued[id] = nil
    }
    private var uploading: Set<String> = []
    private var queued: [String: (title: String, body: String, styled: [RichRun]?)] = [:]
    /// Star changes waiting to go up with the note's next save.
    private var starChanges: [String: Bool] = [:]
    /// One verified save. Typing that happened meanwhile is kept and saved next; a note changed on another device stops
    /// autosave and keeps the local draft. Returns the saved document, or nil when the save failed.
    private func uploadOnce(_ document: CloudDocument, title savedTitle: String, body savedBody: String, styled: [RichRun]?) async -> CloudDocument? {
        guard let client else { return nil }
        let id = document.serverID
        savesInFlight += 1; saveError = nil
        defer { savesInFlight -= 1 }
        do {
            // Use a fresh object so a failed upload cannot mutate the displayed baseline.
            let copy = try CloudDocument(serverID: id, data: document.original)
            let star = starChanges[id]
            let fresh = try await client.save(copy, title: savedTitle, body: savedBody, styled: styled, favorite: star)
            if star != nil, starChanges[id] == star { starChanges[id] = nil }
            loaded[id] = fresh
            if let i = notes.firstIndex(where: { $0.id == id }) {
                notes[i].commit = fresh.commit
                try cache?.save(fresh, revision: fresh.commit)
            }
            try LocalStore.writeDraft(id: id, title: savedTitle, body: savedBody, commit: fresh.commit, styled: fresh.bodyObject?.value("text"))
            if selection == id { self.document = fresh }
            if let i = notes.firstIndex(where: { $0.id == id }) { describe(i, document: fresh) }
            try cache?.saveIndex(CloudIndex(notes: notes, folders: folders))
            lastSaved = Date()
            status = "Saved to Samsung Cloud · \(Date().formatted(date: .omitted, time: .shortened))"
            if selection == id { scheduleAutosave() }
            return fresh
        } catch {
            LocalStore.logSaveFailure(id: id, reason: error.localizedDescription)
            if error.localizedDescription == CloudClient.changedElsewhere {
                if selection == id { draftConflict = true }
                status = "Not saved: \(savedTitle.isEmpty ? "this note" : savedTitle) changed on another device. Your text is kept as a local draft."
            } else {
                saveError = error.localizedDescription
                status = "Not saved: " + error.localizedDescription
            }
            return nil
        }
    }
    func attachmentData(_ asset: AssetRecord, document: CloudDocument) async throws -> Data {
        if let data = cache?.asset(id: asset.id, revision: document.commit) { return data }
        guard let client else { throw NotesError.message("Connect to Samsung Cloud to download this attachment.") }
        // Cached XML deliberately omits expiring signed download URLs.
        var current = asset
        if current.url == nil {
            let fresh = try await client.download(document.serverID)
            guard fresh.commit == document.commit, let found = fresh.assets.first(where: { $0.id == asset.id }) else {
                throw NotesError.message("This note changed. Refresh its cloud copy to open the attachment.")
            }
            current = found
        }
        let data = try await client.downloadAsset(current)
        try cache?.saveAsset(data, id: asset.id, revision: document.commit)
        return data
    }
    func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let result = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String(result.prefix(100)).isEmpty ? "note" : String(result.prefix(100))
    }
}

extension NoteRecord {
    /// List metadata derived from a downloaded document.
    mutating func describe(_ document: CloudDocument) {
        let heading = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = document.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = heading.isEmpty ? (firstLine.isEmpty ? "Untitled note" : firstLine) : heading
        snippet = String(document.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        resourceID = document.resource.attr("id")
        favorite = document.isFavorite
    }
}
