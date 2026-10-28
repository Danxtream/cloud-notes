# Changelog

## 2.0.0 — 2026-10-28

Cloud Notes for Samsung Notes: this version continues Samsung Cloud Notes 1.1 by Clascheurduturfu under a new name and license. Source only; there are no downloads.

- **Name and license:** renamed Cloud Notes for Samsung Notes; Danxtream's changes are GPL-3.0-only, with the original project's MIT notice kept in NOTICE.md. The About window shows the license and credit.
- **Mac app:** create notes and nested folders; folder colours and a folder menu (new subfolder, rename, colour, delete); Trash with restore and delete for good; Favorites; sorting by date modified, date created or name; formatting (bold, italic, underline, strikethrough, colours, highlight, five sizes, lists, checklists) that Samsung Notes on a phone reads back; autosave; offline edits saved when the connection returns, with Samsung's keep-this, keep-other or keep-both choice on conflicts; blocking notes from Claude, with their local copies encrypted.
- **Saves reach phones:** saved notes stay readable by Samsung Notes and carry the sync time, so phones download the change.
- **`scnotes`:** `new`, `favorite`, `trash`, `restore`, `delete`, `mkdir`, `folder-color`, `rename-folder`, `trash-folder`, `list --sort`, and `show --markdown` / `edit --markdown` for formatting.
- **Removed:** the Windows connection helper and the Import Windows connection option.
- The iPhone/iPad and Android apps come from 1.1 and have not been updated or tested with these changes. As with earlier version changes, the Mac app re-registers as 2.0.0 at its next token renewal, keeping its installation and cache identity.

## 1.1.0 — 2026-10-21

Stable 1.1, published as Git tag **v1.1**, with downloads for all three platforms.

- Promotes 1.1.0-beta.1 unchanged apart from version metadata: the Android app, the iPhone/iPad app and the `scnotes` command line described below.
- Release downloads: universal Mac app (CLI included), Android APK and an unsigned iOS IPA for sideloading, with SHA-256 checksums.
- The Mac app re-registers as 1.1.0 at its next token renewal, keeping its installation and cache identity.
- Cloud saves from the new clients follow the Mac's verified save path but were not exercised against a live account before release; see [validation](docs/validation.md).

## 1.1.0-beta.1 — 2026-10-21

First beta of 1.1: Samsung Cloud Notes beyond the Mac app.

- **Android app** for any manufacturer (Android 8+): Kotlin/Jetpack Compose port of the protocol, native Samsung sign-in through a Custom Tab, Keystore-sealed credentials, library/folders/trash/search, typed-text editing with conflict checks, backups and drafts, drawing previews/PDF, attachments and zipped export. Samsung Notes is not required.
- **iPhone and iPad app** (iOS 16+) built from the same shared Swift core as the Mac app: native sign-in, Keychain storage, the same library and editing features, Quick Look attachments and drawing PDFs, share-sheet export and Windows import.
- **`scnotes` command line** inside the Mac app: `status`, `sync`, `list`, `folders`, `search`, `show`, `edit`, `export`, `drawing`, `login`, `logout`, with `--json` and `--offline`. Install it from the app menu.
- Shared Swift sources reorganized into `Sources/Shared`, `Sources/macOS` and `Sources/iOS`; an order-preserving portable XML tree replaces Foundation's macOS-only one on iOS, cross-checked in the self-test.
- Each device registers its own model and alias with Samsung (Mac identity unchanged).
- Offline checks for iOS and Android, and matching CI jobs.
- Version 1.1.0-beta.1; as with earlier version changes, the Mac app re-registers as 1.1.0 at its next token renewal, keeping its installation and cache identity.

See [validation](docs/validation.md#110-beta1--21-october-2026) for what this beta has and has not exercised.

## 1.0.0 — 2026-10-21

Stable packaging of the validated release candidate, published as Git tag **v1.0**.

- App display, source and bundle/build metadata now report 1.0.0.
- Universal macOS download with original icon, project/upstream notices and SHA-256 checksums.
- Native sign-in, editing, caching and account menu retain the release candidate's behavior.
- Private API, text-formatting, drawing and distribution limitations remain documented below and in the README.

## 1.0.0-rc.1 — 2026-10-21

First repository release candidate.

- Native Samsung browser login, independent Mac registration and automatic credential renewal.
- Native note/folder/trash browser, search and supported title/main-text editing.
- Revision-aware cache, drafts, archived drafts and pre-save backups.
- Approximate handwriting/PDF previews, decoded folder/attachment names and internal cache filtering.
- Account email menu with Log out; signed-out welcome with sign-in and optional Windows import.
- Numeric app-version registration migration preserving installation/cache identity.
- Original icon, local signing and a fixed signed Keychain helper.
- Optional Windows connection helper 0.1.3.
- Authentication/reverse-engineering documentation and upstream credits.

See [validation](docs/validation.md) for the tested scope. This historical entry describes the release candidate; builds are not notarized.
