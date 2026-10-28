import SwiftUI
import AppKit
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit
import UniformTypeIdentifiers

extension NotesModel {
    func export() async {
        guard let document else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(safeName(title.isEmpty ? "Samsung note" : title)).samsungnote"
        panel.title = "Export original Samsung Cloud document and attachments"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try document.original.write(to: destination.appendingPathComponent("document.xml"), options: [.atomic])
            try Data(body.utf8).write(to: destination.appendingPathComponent("text.txt"), options: [.atomic])
            for asset in document.assets {
                let data = try await attachmentData(asset, document: document)
                let name = safeName(asset.id)
                try data.write(to: destination.appendingPathComponent(name), options: [.atomic])
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination]); status = "Exported original document and \(document.assets.count) attachments."
        } catch { self.error = "Export did not finish: " + error.localizedDescription }
    }
    func showAttachment(_ asset: AssetRecord) async {
        guard let document else { return }
        do {
            guard !asset.isInternal else { throw NotesError.message("This is an internal Samsung page resource. Use the drawing preview or export the original document.") }
            let data = try await attachmentData(asset, document: document)
            let ext: String
            if data.starts(with: [0x89,0x50,0x4e,0x47]) { ext = ".png" }
            else if data.starts(with: [0xff,0xd8,0xff]) { ext = ".jpg" }
            else if data.starts(with: Data("%PDF".utf8)) { ext = ".pdf" }
            else if NSImage(data: data) != nil {
                let image = NSImage(data: data)!
                guard let png = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) else { throw NotesError.message("This image could not be opened.") }
                let url = try LocalStore.directory("Attachments").appendingPathComponent(safeName(asset.id) + ".png")
                try png.write(to: url, options: [.atomic]); NSWorkspace.shared.open(url); return
            }
            else {
                let suffix = (asset.fileName as NSString).pathExtension.lowercased()
                guard ["txt", "csv", "rtf", "docx", "xlsx", "pptx", "mp3", "m4a", "wav", "mp4", "mov"].contains(suffix) else { throw NotesError.message("This Samsung resource has no supported preview. Export the original document to keep it.") }
                ext = "." + suffix
            }
            let url = try LocalStore.directory("Attachments").appendingPathComponent(safeName(asset.fileName) + "-" + safeName(asset.id) + ext)
            try data.write(to: url, options: [.atomic])
            NSWorkspace.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }
    func showDrawing() {
        guard let document else { return }
        do {
            let url = try LocalStore.directory("Previews").appendingPathComponent(safeName(document.serverID) + ".pdf")
            try DrawingPage.pdf(document.drawingPages).write(to: url, options: [.atomic])
            NSWorkspace.shared.open(url)
        } catch { self.error = error.localizedDescription }
    }
}

struct NotesView: View {
    @StateObject var model = NotesModel()
    @StateObject var formatting = RichTextController()
    @State var importing = false
    @State var showDrawing = false
    @State var creatingFolder = false
    @State var newFolderName = ""
    /// The folder a new folder goes into when created from a folder's menu; nil for the + button's usual place.
    @State var newFolderParent: String?
    @State var renamingFolder: FolderRecord?
    @State var folderNewName = ""
    @State var deletingFolder: FolderRecord?
    @State var creatingNote = false
    @State var newNoteTitle = ""
    @State var pendingDelete: String?
    @State var columns: NavigationSplitViewVisibility = .all
    /// The open note fills the window, like opening a note in Samsung Notes; Back (Esc) returns to the list.
    @State var noteFullView = false
    /// Below this width (about a third of a laptop screen) the folder sidebar hides itself.
    static let narrowWidth: CGFloat = 720
    @State var narrow = false
    var body: some View {
        VStack(spacing: 0) {
        Group {
            // On macOS a three-column split view keeps its note list with .detailOnly, so the open note replaces the
            // split view instead.
            if noteFullView {
                detailPane.navigationTitle("Samsung Cloud Notes")
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebarPane
                } content: {
                    notesListPane
                } detail: {
                    detailPane.navigationSplitViewColumnWidth(min: 240, ideal: 520)
                }
            }
        }
        .toolbar { windowToolbar }
        .alert("New note", isPresented: $creatingNote) {
            TextField("Title", text: $newNoteTitle)
            Button("Create") { let title = newNoteTitle; Task { await model.createNote(title: title) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let folder = model.newFolderParent
            Text(folder == "root" ? "Not in a folder." : "In \(model.folders.path(of: folder)).")
        }
        Divider()
        HStack(spacing: 8) {
            if model.busy || model.savesInFlight > 0 { ProgressView().controlSize(.small).frame(width: 14, height: 14) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).frame(height: 32).background(.bar)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if dictionary?["sealed"] != nil { model.pendingConnection = data }
                else { Task { await model.importConnection(data) } }
            } catch { model.error = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { model.pendingConnection != nil }, set: { if !$0 { model.pendingConnection = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Unlock Samsung connection").font(.title2)
                Text("Paste the connection code shown by the Windows exporter. Your session will be stored in this Mac's Keychain.").frame(width: 390)
                SecureField("Connection code", text: $model.importCode).textFieldStyle(.roundedBorder)
                HStack { Button("Cancel") { model.pendingConnection = nil }; Spacer(); Button("Connect") { if let data = model.pendingConnection { Task { await model.importConnection(data, code: model.importCode) } } }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 440)
        }
        .alert("Samsung Cloud Notes", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onChange(of: model.selection) { value in Task { await model.select(value) } }
        .onChange(of: model.title) { _ in model.edited() }
        .onChange(of: model.body) { _ in model.edited() }
        .onChange(of: model.styledBody) { _ in model.edited() }
        .onChange(of: model.document?.serverID) { _ in showDrawing = model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(model.document?.drawingPages.isEmpty ?? true) }
        .onChange(of: model.folder) { _ in model.preserveDraft(); model.selection = model.visibleNotes.first?.id }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.preserveDraft() }
        .task { await model.connect() }
        .background(GeometryReader { proxy in Color.clear.onAppear { adapt(to: proxy.size.width) }.onChange(of: proxy.size.width) { adapt(to: $0) } })
        .onChange(of: model.selection) { if $0 == nil && noteFullView { showList() } }
        .frame(minWidth: 440, minHeight: 400)
    }
    /// Back or Open fully, then New note, the star, Refresh, Sort, and the note and library actions.
    @ToolbarContentBuilder var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if noteFullView {
                Button { showList() } label: { Label("Notes", systemImage: "chevron.left") }.keyboardShortcut(.cancelAction).help("Back to the note list (Esc)")
            } else {
                Button { openNoteFully() } label: { Label("Open note fully", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .disabled(model.document == nil).help("Open the note in the whole window (or double-click it)")
            }
        }
        ToolbarItem {
            Button { newNoteTitle = ""; creatingNote = true } label: { Label("New note", systemImage: "square.and.pencil") }
                .disabled(model.busy || model.account.isEmpty).help("New note")
        }
        ToolbarItem {
            let open = model.selection.flatMap { id in model.notes.first { $0.id == id } }
            Button { if let open { Task { await model.setFavorite(open.id, !open.isFavorite) } } } label: {
                Label(open?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites", systemImage: open?.isFavorite == true ? "star.fill" : "star")
            }.disabled(open == nil || open?.trashed == true || model.busy)
        }
        ToolbarItem {
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.busy || model.account.isEmpty)
        }
        ToolbarItem { sortMenu }
        ToolbarItem {
            Button { Task { if let id = model.selection { model.preserveDraft(); await model.open(id, force: true) } } } label: { Label("Reload note", systemImage: "arrow.down.doc") }.disabled(model.busy || model.document == nil)
        }
        ToolbarItem {
            Button { Task { await model.export() } } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(model.busy || model.document == nil)
        }
        ToolbarItem {
            Button { do { _ = try LocalStore.directory("Backups"); NSWorkspace.shared.open(LocalStore.root) } catch { model.error = error.localizedDescription } } label: { Label("Local copies", systemImage: "folder") }
        }
    }
    /// Folders (collapsible), the account menu and the version.
    @ViewBuilder var sidebarPane: some View {
        VStack(spacing: 0) {
        List(selection: $model.folder) {
            Label("All notes", systemImage: "doc.text").tag("all")
            Label("Favorites", systemImage: "star").tag("favorites")
            Section {
                OutlineGroup(model.folders.listed(with: model.notes).tree, children: \.children) { node in
                    Label { Text(node.folder.name) } icon: {
                        // Grey folders are drawn grey, as on the phone, not in the accent colour.
                        Image(systemName: "folder").foregroundStyle(node.folder.folderColor.shown.map { AnyShapeStyle(Self.shade($0)) } ?? AnyShapeStyle(.secondary))
                    }
                    .tag(node.id)
                    .contextMenu { folderMenu(node.folder) }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { newFolderParent = nil; newFolderName = ""; creatingFolder = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).disabled(model.busy || model.account.isEmpty)
                        .help("New folder").accessibilityLabel("New folder")
                }
            }
            Label("Trash", systemImage: "trash").tag("trash")
        }
        .navigationTitle("Samsung Cloud Notes")
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { let name = newFolderName, parent = newFolderParent; Task { await model.createFolder(named: name, in: parent) } }
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            let parent = newFolderParent ?? model.newFolderParent
            Text(parent == "root" ? "At the top level of your Samsung Notes folders." : "Inside \(model.folders.path(of: parent)).")
        }
        .alert("Rename folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $folderNewName)
            Button("Rename") { if let folder = renamingFolder { let name = folderNewName; Task { await model.renameFolder(folder.id, to: name) } } }
                .disabled(folderNewName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Rename \"\(renamingFolder?.name ?? "")\" in Samsung Notes.") }
        .confirmationDialog("Delete this folder?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
            Button("Move to Trash", role: .destructive) { if let folder = deletingFolder { Task { await model.trashFolder(folder.id) } } }
            Button("Cancel", role: .cancel) { deletingFolder = nil }
        } message: {
            let folder = deletingFolder
            let inside = Set([folder?.id ?? ""] + model.folders.descendants(of: folder?.id ?? ""))
            let count = model.notes.filter { !$0.trashed && inside.contains($0.folder) }.count
            Text("\"\(folder?.name ?? "")\", its subfolders and \(count == 1 ? "its note" : "their \(count) notes") move to the Trash, as in Samsung Notes. They can be restored from the Trash in Samsung Notes for 30 days.")
        }
        Divider()
            VStack(alignment: .leading, spacing: 6) {
                if !model.account.isEmpty {
                    Menu {
                        Button("Log out", role: .destructive) { model.signOut() }
                    } label: {
                        Text(model.account).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .disabled(model.busy).help("Account options for " + model.account)
                    .accessibilityLabel("Account: " + model.account)
                }
                Text("Version \(appVersion)").foregroundStyle(.secondary)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 200)
    }
    /// The note list's Sort menu, with the orders Samsung Notes offers; the choice is kept on this Mac for every folder.
    var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sort.key) {
                ForEach(NoteSort.Key.allCases) { key in Text(key.label).tag(key) }
            }.pickerStyle(.inline)
            Picker("Order", selection: $model.sort.reversed) {
                Text(model.sort.key == .name ? "A to Z" : "Newest First").tag(false)
                Text(model.sort.key == .name ? "Z to A" : "Oldest First").tag(true)
            }.pickerStyle(.inline)
            Divider()
            Toggle("Favorites at the Top", isOn: $model.sort.favoritesFirst)
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
        .help("Sort notes")
    }
    /// A folder's right-click menu, as Samsung Notes' long-press menu: new subfolder, rename, colour and delete.
    /// Built-in folders such as Math notes have none of these.
    @ViewBuilder func folderMenu(_ folder: FolderRecord) -> some View {
        if !folder.id.contains(":///") {
            Group {
                Button("New Subfolder…") { newFolderParent = folder.id; newFolderName = ""; creatingFolder = true }
                Button("Rename…") { folderNewName = folder.name; renamingFolder = folder }
                Menu("Change Folder Colour") { folderColourMenu(folder) }
                Divider()
                Button("Delete Folder…", role: .destructive) { deletingFolder = folder }
            }.disabled(model.busy || model.account.isEmpty)
        }
    }
    /// A folder's Colour menu: Samsung Notes' twelve folder colours with a swatch each, the current one ticked.
    /// Built-in folders such as Math notes keep Samsung's colour.
    @ViewBuilder func folderColourMenu(_ folder: FolderRecord) -> some View {
        if !folder.id.contains(":///") {
            Picker("Colour", selection: Binding(get: { folder.folderColor }, set: { colour in
                if colour != folder.folderColor { Task { await model.setFolderColor(folder.id, colour) } }
            })) {
                ForEach(FolderColor.allCases) { colour in
                    Label { Text(colour.name) } icon: { Image(nsImage: Self.swatch(colour.shown)) }.tag(colour)
                }
            }
            .pickerStyle(.inline).disabled(model.busy || model.account.isEmpty)
        }
    }
    /// A colour from a 0xRRGGBB value.
    static func shade(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
    /// A small round swatch for menus, which draw template images in one colour; grey (nil) uses the system grey.
    static func swatch(_ rgb: UInt32?) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            (rgb.map { NSColor(shade($0)) } ?? NSColor.systemGray).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
    /// The notes of the selected folder; click to preview, double-click to open fully.
    @ViewBuilder var notesListPane: some View {
        ScrollViewReader { proxy in
        List(model.visibleNotes, selection: $model.selection) { note in
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(note.locked ? "Locked note" : note.title).fontWeight(.medium).lineLimit(2)
                    if note.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favorite") }
                    if note.locked || note.encrypted { Image(systemName: "lock") } }
                Text(note.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let days = note.daysLeftInTrash() {
                    Text(days == 1 ? "Deleted in 1 day" : "Deleted in \(days) days").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(Date(timeIntervalSince1970: note.modified / 1000), style: .date).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 5).tag(note.id)
        }
        // The list's own double-click (and Return) action: a gesture on the rows would hold every single click back
        // until the double-click interval passed, so selecting a note would lag.
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let note = model.notes.first(where: { $0.id == ids.first }) {
                if note.trashed {
                    Button("Restore") { Task { await model.change(note: note.id, .restore) } }
                    Button("Delete Forever…", role: .destructive) { pendingDelete = note.id }
                } else {
                    Button(note.isFavorite ? "Remove from Favorites" : "Add to Favorites") { Task { await model.setFavorite(note.id, !note.isFavorite) } }
                    Button("Move to Trash") { Task { await model.change(note: note.id, .trash) } }
                }
                Divider()
                let blocked = BlockedNotes.contains(note.id)
                Button(blocked ? "Unblock from Claude" : "Block from Claude") {
                    do { try BlockedNotes.set(note.id, title: note.title, blocked: !blocked) }
                    catch { model.error = (blocked ? "The note could not be unblocked: " : "The note is blocked, but its copies on this Mac could not all be encrypted: ") + error.localizedDescription }
                }
            }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            model.selection = id; openNoteFully()
        }
        // Going back from a fully open note builds the list anew; bring that note back into view once its rows are laid out.
        .onAppear { if let id = model.selection { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } } }
        }
        .onDeleteCommand {
            guard let id = model.selection, let note = model.notes.first(where: { $0.id == id }) else { return }
            if note.trashed { pendingDelete = id } else { Task { await model.change(note: id, .trash) } }
        }
        .confirmationDialog("Delete this note forever?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Forever", role: .destructive) {
                if let id = pendingDelete { Task { await model.change(note: id, .deleteForever) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It is removed from Samsung Cloud and can't be restored here. Samsung Notes on your other devices keeps its own copy in its Trash until that Trash is emptied (after 30 days, or by you).")
        }
        .searchable(text: $model.search, prompt: "Search notes")
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    }
    /// Bold, italic, underline, strikethrough, colour, highlight, size and lists for the open note's text, with
    /// Samsung Notes' colours. Applies to the selection, or to what is typed next. Its three groups wrap onto more
    /// rows in a narrow window.
    var formatBar: some View {
        FlowLayout(spacing: 16, rowSpacing: 6) {
            HStack(spacing: 8) {
                Button { formatting.toggle("span/bold") } label: { Image(systemName: "bold") }.keyboardShortcut("b").help("Bold (⌘B)")
                Button { formatting.toggle("span/italic") } label: { Image(systemName: "italic") }.keyboardShortcut("i").help("Italic (⌘I)")
                Button { formatting.toggle("span/underline") } label: { Image(systemName: "underline") }.keyboardShortcut("u").help("Underline (⌘U)")
                Button { formatting.toggle("span/strikethrough") } label: { Image(systemName: "strikethrough") }.keyboardShortcut("x", modifiers: [.command, .shift]).help("Strikethrough (⇧⌘X)")
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Default") { formatting.setColor(nil) }
                    ForEach(Self.textColors, id: \.name) { color in Button(color.name) { formatting.setColor(color.argb) } }
                } label: { Image(systemName: "paintpalette") }.menuIndicator(.hidden).fixedSize().help("Text colour")
                Menu {
                    Button("None") { formatting.setHighlight(nil) }
                    ForEach(Self.highlights, id: \.name) { color in Button(color.name) { formatting.setHighlight(color.argb) } }
                } label: { Image(systemName: "highlighter") }.menuIndicator(.hidden).fixedSize().help("Highlight")
                Menu {
                    ForEach([("Small", 12.0), ("Normal", 16.0), ("Large", 20.0), ("Larger", 24.0), ("Huge", 32.0)], id: \.0) { name, size in
                        Button(name) { formatting.setSize(size) }
                    }
                } label: { Image(systemName: "textformat.size") }.menuIndicator(.hidden).fixedSize().help("Text size")
            }
            HStack(spacing: 8) {
                Button { formatting.setList(.dot) } label: { Image(systemName: "list.bullet") }.help("Bulleted list")
                Button { formatting.setList(.number) } label: { Image(systemName: "list.number") }.help("Numbered list")
                Button { formatting.setList(.checkbox) } label: { Image(systemName: "checklist") }.help("Checklist")
            }
        }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
    static let textColors: [(name: String, argb: UInt32)] = [("Red", 0xFFE5_3935), ("Orange", 0xFFFB_8C00), ("Green", 0xFF43_A047),
                                                             ("Blue", 0xFF1E_88E5), ("Purple", 0xFF8E_24AA), ("Grey", 0xFF75_7575)]
    static let highlights: [(name: String, argb: UInt32)] = [("Yellow", 0xFFFF_F59D), ("Green", 0xFFC5_E1A5), ("Blue", 0xFF90_CAF9), ("Pink", 0xFFF4_8FB1)]
    /// The open note (editable preview, or the whole window when opened fully), or the welcome view.
    @ViewBuilder var detailPane: some View {
        if let document = model.document {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Title", text: $model.title).font(.title2).textFieldStyle(.plain).padding()
                    .disabled(!model.editable || model.busy)
                Divider()
                if !document.drawingPages.isEmpty {
                    HStack {
                        Picker("View", selection: $showDrawing) { Text("Text").tag(false); Text("Drawing").tag(true) }.pickerStyle(.segmented).frame(width: 190)
                        Spacer()
                        Button("Open drawing PDF") { model.showDrawing() }
                    }.padding(10)
                }
                if showDrawing && !document.drawingPages.isEmpty { DrawingPreview(pages: document.drawingPages) }
                else if model.styledBody != nil, document.bodyObject != nil {
                    if model.editable { formatBar.disabled(model.busy); Divider() }
                    RichTextEditor(noteID: document.serverID, runs: Binding(get: { model.styledBody ?? [] }, set: { model.styledBody = $0 }), text: $model.body,
                                   editable: model.editable && !model.busy,
                                   defaults: document.body.isEmpty ? RichText.typingStyles : document.richBody?.commonStyles ?? RichText.typingStyles,
                                   controller: formatting)
                } else {
                    TextEditor(text: $model.body).font(.system(size: 15)).padding(10)
                        .disabled(!model.editable || model.busy || document.bodyObject == nil)
                }
                if !document.assets.filter({ !$0.isInternal }).isEmpty {
                    Divider()
                    ScrollView(.horizontal) { HStack {
                        Image(systemName: "paperclip")
                        ForEach(document.assets.filter { !$0.isInternal }) { asset in
                            Button(asset.fileName) { Task { await model.showAttachment(asset) } }.lineLimit(1)
                        }
                    }.padding(10) }
                }
                if let issue = document.textIssue { Text(issue).font(.caption).foregroundStyle(.secondary).padding(10) }
                if model.draftConflict {
                    HStack(alignment: .firstTextBaseline) {
                        Text("This local draft is based on an older cloud revision. Reload the note to archive the draft and open the current cloud copy.")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button("Reload Note") { Task { await model.open(document.serverID, force: true) } }.controlSize(.small).disabled(model.busy)
                    }.padding(10)
                }
                Divider()
                HStack {
                    Text(model.saveStatus).foregroundStyle(model.saveError != nil || model.draftConflict ? .orange : .secondary).lineLimit(1)
                    if model.saveError != nil { Button("Retry") { Task { await model.save() } }.controlSize(.small) }
                    Spacer()
                    if model.styledBody != nil { ViewThatFits { Text("Formatting kept · drawings and attachments retained"); Text("Formatting kept") }.foregroundStyle(.secondary) }
                    else { ViewThatFits { Text("Plain text editing · drawings and attachments retained"); Text("Plain text") }.foregroundStyle(.secondary) }
                }.font(.caption).padding(10)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "note.text").font(.system(size: 48)).foregroundStyle(.secondary)
                Text(model.account.isEmpty ? "Your Samsung notes, on Mac" : "Select a note").font(.title2)
                Text(model.account.isEmpty ? "Sign in with your Samsung account to access your notes directly from this Mac." : "Notes load directly from Samsung Cloud.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                if model.account.isEmpty {
                    Button("Sign in with Samsung…") { Task { await model.signIn() } }.buttonStyle(.borderedProminent).disabled(model.busy)
                    Button("Import Windows connection…") { importing = true }.buttonStyle(.link).disabled(model.busy)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    func openNoteFully() { guard model.document != nil || model.selection != nil else { return }; noteFullView = true }
    func showList() { noteFullView = false; columns = narrow ? .doubleColumn : .all }
    /// Hides the folder sidebar when the window gets narrow and shows it again when it widens; the sidebar button still works.
    func adapt(to width: CGFloat) {
        guard (width < Self.narrowWidth) != narrow else { return }
        narrow.toggle()
        if !noteFullView { columns = narrow ? .doubleColumn : .all }
    }
}

@main struct SamsungCloudNotesApp: App {
    init() {
        if CommandLine.arguments.dropFirst().first == "--cli" { CommandLineTool.run(Array(CommandLine.arguments.dropFirst(2))) }
        if CommandLine.arguments.contains("--session-stdin") {
            do { transientSession = try JSONDecoder().decode(AccountSession.self, from: FileHandle.standardInput.readDataToEndOfFile()) }
            catch { fputs("Invalid session input.\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--import-session") {
            do { try SessionStore.save(JSONDecoder().decode(AccountSession.self, from: FileHandle.standardInput.readDataToEndOfFile())); print("Session imported into Keychain."); exit(0) }
            catch { fputs("Session import failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try SelfTest.run(); print("Offline self-tests passed."); exit(0) }
            catch { fputs("Self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--verify-signout") {
            Task { @MainActor in
                do {
                    let model = NotesModel()
                    await model.connect()
                    guard !model.account.isEmpty, !model.notes.isEmpty else { throw NotesError.message("Connect before checking account sign-out.") }
                    let native = try NativeAuthStore.load()
                    let session = try SessionStore.load()
                    let count = model.notes.count
                    defer {
                        do { try NativeAuthStore.save(native); try SessionStore.save(session) }
                        catch { fputs("Could not restore the saved test connection: \(error.localizedDescription)\n", stderr) }
                    }
                    model.signOut()
                    guard model.account.isEmpty, model.notes.isEmpty, model.document == nil,
                          try NativeAuthStore.loadIfPresent() == nil else { throw NotesError.message("Sign-out did not clear the account and native credentials.") }
                    var missing = false
                    do { _ = try SessionStore.load() }
                    catch CredentialError.status(errSecItemNotFound) { missing = true }
                    guard missing else { throw NotesError.message("Sign-out retained its saved cloud session.") }
                    try NativeAuthStore.save(native); try SessionStore.save(session)
                    await model.connect()
                    guard model.notes.count == count, !model.account.isEmpty else { throw NotesError.message("Saved connection could not be restored after the sign-out check.") }
                    print("Account sign-out verified: both credential records removed and visible library cleared; original connection restored in memory and reconnected to \(count) records. Cache and drafts retained.")
                    exit(0)
                } catch { fputs("Account sign-out verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--verify-native") {
            Task { @MainActor in
                do {
                    var expired = try NativeAuthStore.load()
                    let scope = expired.cacheID
                    expired.accessExpires = .distantPast; expired.cloudExpires = .distantPast
                    let renewed = try await SamsungSignIn.shared.cloudSession(expired, force: true)
                    guard renewed.nativeID == scope, let expiry = renewed.expiresAt, expiry > Date().addingTimeInterval(120) else { throw NotesError.message("Native renewal did not retain the device identity or return a valid expiry.") }
                    let index = try await CloudClient(account: renewed).loadIndex()
                    try SessionStore.save(renewed)
                    var rejected = renewed
                    rejected.authorization = "Bearer synthetic-expired-credential-for-renewal-test"
                    let retried = try await CloudClient(account: rejected).loadIndex()
                    guard retried.notes.count == index.notes.count else { throw NotesError.message("Authentication rejection recovery changed the library.") }
                    print("Native Mac sign-in verified: \(index.notes.count) records; forced account/service renewal and rejected-token recovery succeeded; stable device identity retained. No Windows credentials supplied.")
                    exit(0)
                } catch { fputs("Native sign-in verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--verify-cache") {
            Task { @MainActor in
                do {
                    let first = NotesModel()
                    await first.connect()
                    guard !first.notes.isEmpty else { throw NotesError.message("No cloud index available for the cache check.") }
                    let offline = NotesModel()
                    await offline.connect(cacheOnly: true)
                    guard offline.document != nil, offline.notes.count == first.notes.count else { throw NotesError.message("Offline startup could not open the cached library.") }
                    let second = NotesModel()
                    await second.connect()
                    guard second.downloadedNotes == 0, second.notes.count == first.notes.count, second.document != nil else { throw NotesError.message("Warm startup downloaded unchanged documents or failed to restore notes.") }
                    print("Cache verified: \(second.notes.count) records restored offline; first refresh downloaded \(first.downloadedNotes) changed/missing documents; warm refresh downloaded zero unchanged documents.")
                    exit(0)
                } catch { fputs("Cache verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--verify-previews") {
            Task {
                do {
                    let client = CloudClient(account: try transientSession ?? SessionStore.load())
                    let index = try await client.loadIndex()
                    var pages = 0, strokes = 0, unsupported = 0, caches = 0
                    for note in index.notes where !note.locked && !note.encrypted && !note.trashed {
                        let doc = try await client.download(note.id)
                        caches += doc.assets.filter { $0.isInternal }.count
                        guard !doc.drawingPages.isEmpty else { continue }
                        let data = try DrawingPage.pdf(doc.drawingPages)
                        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), pdf.numberOfPages == doc.drawingPages.count else { throw NotesError.message("Drawing PDF page verification failed.") }
                        pages += doc.drawingPages.count
                        strokes += doc.drawingPages.reduce(0) { $0 + $1.strokes.count }
                        unsupported += doc.drawingPages.reduce(0) { $0 + $1.unsupported }
                    }
                    print("Cloud drawing verification: \(pages) pages, \(strokes) decoded strokes, \(unsupported) unsupported page objects, \(caches) internal resources hidden from attachments. PDF page counts verified.")
                    exit(0)
                } catch { fputs("Drawing verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--verify-cloud") {
            Task {
                do {
                    let client = CloudClient(account: try transientSession ?? SessionStore.load())
                    let index = try await client.loadIndex()
                    print("Cloud index: \(index.notes.filter { !$0.trashed }.count) normal notes, \(index.notes.filter { $0.trashed }.count) trashed notes, \(index.folders.count) folders.")
                    if let note = index.notes.first(where: { !$0.locked && !$0.encrypted }) {
                        let doc = try await client.download(note.id)
                        print("Cloud document downloaded: \(doc.original.count) bytes, \(doc.body.utf16.count) text units, \(doc.assets.count) attachments.")
                    }
                    exit(0)
                } catch { fputs("Cloud verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--test-save") {
            guard let position = CommandLine.arguments.firstIndex(of: "--test-save"), CommandLine.arguments.count > position + 1 else { exit(2) }
            let id = CommandLine.arguments[position + 1]
            Task {
                do {
                    let client = CloudClient(account: try transientSession ?? SessionStore.load())
                    let doc = try await client.download(id)
                    guard doc.body.contains("Samsung Notes Mac sync test v0.1.0") else { throw NotesError.message("This is not the isolated test note.") }
                    let newBody = "Samsung Notes Mac sync test v0.1.0\nEdited on macOS through Samsung Cloud.\nUnicode: café — 日本語 🚀.\n"
                    let fresh = try await client.save(doc, title: "Mac sync verification (\(appVersion))", body: newBody)
                    guard fresh.body == newBody else { throw NotesError.message("Mac edit readback mismatch.") }
                    let stale = try CloudDocument(serverID: id, data: doc.original)
                    var rejected = false
                    do { _ = try await client.save(stale, title: "Stale edit must be rejected", body: "Must never be written") }
                    catch { rejected = error.localizedDescription.contains("changed on another device") }
                    guard rejected else { throw NotesError.message("Stale revision was not rejected.") }
                    let afterConflict = try await client.download(id)
                    guard afterConflict.body == newBody else { throw NotesError.message("Conflict check modified the note.") }
                    print("Mac cloud edit and readback passed, including Unicode. Stale revision rejected without changing the cloud note.")
                    exit(0)
                } catch { fputs("Mac save test failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
        }
    }
    var body: some Scene {
        WindowGroup { NotesView() }.defaultSize(width: 1150, height: 760)
            .commands {
                CommandGroup(after: .appSettings) {
                    Button("Install Command Line Tool…") { CommandLineTool.installFromApp() }
                }
            }
        Settings { SettingsView() }
    }

}

/// Lays its children out left to right and starts a new row when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
