// Licensed under GPL-3.0-only with an additional term under section 7(b); see LICENSE and NOTICE.md.

import SwiftUI

/// The app's Settings window (Cloud Notes for Samsung Notes → Settings…).
struct SettingsView: View {
    var body: some View {
        TabView {
            BlockedNotesSettings().tabItem { Label("Claude", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 480)
    }
}

/// Notes blocked from Claude: ticking a note adds it to `BlockedNotes` and encrypts this Mac's copies of it; unticking
/// decrypts them and takes it off. The notes come from the cached library, so the list works offline.
struct BlockedNotesSettings: View {
    @State private var notes: [NoteRecord] = []
    @State private var folders: [FolderRecord] = []
    @State private var blocked = BlockedNotes.ids()
    @State private var search = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocked notes").font(.headline)
            Text("Claude can't list, search, read or change a blocked note through the Samsung Notes connector or scnotes, and this Mac keeps its copies of it encrypted. You still see and edit it here as usual.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search notes", text: $search).textFieldStyle(.roundedBorder)
            List(shown) { note in
                Toggle(isOn: Binding(get: { blocked.contains(note.id) }, set: { change(note, to: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).lineLimit(1)
                        Text(note.trashed ? "Trash" : folders.path(of: note.folder).isEmpty ? "No folder" : folders.path(of: note.folder))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20)
        .onAppear(perform: load)
    }

    /// Blocked notes first, then the rest by title, filtered by the search text.
    private var shown: [NoteRecord] {
        notes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { (blocked.contains($0.id) ? 0 : 1, $0.title.lowercased()) < (blocked.contains($1.id) ? 0 : 1, $1.title.lowercased()) }
    }

    private func load() {
        blocked = BlockedNotes.ids()
        do {
            guard let snapshot = try NoteCache(session: SessionStore.load()).snapshot() else { problem = "Open your notes once so they can be listed here."; return }
            notes = snapshot.index.notes; folders = snapshot.index.folders; problem = nil
        } catch { problem = "Sign in to Samsung to list your notes here." }
    }

    private func change(_ note: NoteRecord, to on: Bool) {
        do {
            try BlockedNotes.set(note.id, title: note.title, blocked: on)
            problem = nil
        } catch {
            problem = (on ? "The note is blocked, but its copies on this Mac could not all be encrypted: " : "The note could not be unblocked: ") + error.localizedDescription
        }
        blocked = BlockedNotes.ids()
    }
}
