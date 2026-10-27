# Command line (`scnotes`)

New in **1.1**. `scnotes` gives terminal and script access to the same library, cache and drafts as the Mac app.

## How it works

The command line runs inside the signed app executable (`SamsungCloudNotes --cli …`). That matters for credentials: the Keychain helper only answers its own signed app, so a separate binary could not read the saved sign-in without weakening that check. `scnotes` is a two-line shell wrapper that calls the app executable.

- It reuses the Mac app's native sign-in, automatic renewal and Keychain helper. Sign in once in the app.
- It shares the app's revision-aware cache under `~/Library/Application Support/SamsungCloudNotes/`. Unchanged notes are never downloaded twice.
- Without `--offline`, read commands refresh the index from Samsung Cloud and fall back to the cache, with a warning on stderr, when offline.

## Install

In the app: **Samsung Cloud Notes → Install Command Line Tool…**. Or from a terminal:

```sh
"/Applications/Samsung Cloud Notes.app/Contents/MacOS/SamsungCloudNotes" --cli install            # ~/.local/bin/scnotes
"/Applications/Samsung Cloud Notes.app/Contents/MacOS/SamsungCloudNotes" --cli install /usr/local/bin
```

If the directory is not on your `PATH`, the installer prints the line to add to `~/.zshrc`. Reinstall after moving the app.

## Commands

| Command | Purpose |
| --- | --- |
| `scnotes status` | Account, connection type, cache size, last sync, data directory |
| `scnotes sync` | Refresh the index and download changed or missing documents |
| `scnotes list [--folder NAME\|PATH] [--trash] [--limit N]` | Notes, newest first: ID, date, title, folder path |
| `scnotes folders` | Folder IDs, paths and colours; subfolders appear as `Parent/Child`. Built-in folders such as Math notes are listed only while they hold notes, as on the phone |
| `scnotes search QUERY` | Case-insensitive search of titles and full typed text |
| `scnotes show NOTE [--markdown \| --xml]` | Title, text, attachment names and drawing page count; `--markdown` shows the text's formatting as Markdown-style text (see below), `--xml` prints the original cloud document |
| `scnotes edit NOTE [--title TEXT] [--body TEXT \| --body-file PATH\|-] [--markdown]` | Replace the title and/or typed text and save to Samsung Cloud; with `--markdown` the text is Markdown-style and formatting is kept |
| `scnotes new TITLE [--folder PATH] [--body TEXT \| --body-file PATH\|-]` | Create a text note in Samsung Cloud, built from the template |
| `scnotes template NOTE` | Copy new notes' structure from NOTE instead of the automatically chosen note (kept only on this Mac) |
| `scnotes favorite NOTE` / `unfavorite NOTE` | Star or unstar a note (Favorites in Samsung Notes); its text is unchanged |
| `scnotes trash NOTE` | Move a note to the Trash; Samsung Notes deletes it for good after 30 days |
| `scnotes restore NOTE` | Bring a note back from the Trash to the folder it was in |
| `scnotes delete NOTE` | Delete a note that is already in the Trash from Samsung Cloud for good; other devices keep their copy in their own Trash until it is emptied |
| `scnotes mkdir PATH` | Create a folder in Samsung Cloud; `Dev/New ideas` creates *New ideas* inside *Dev* |
| `scnotes folder-color PATH COLOR` | Give a folder one of Samsung Notes' twelve colours: grey, red, orange, yellow, light-green, green, light-blue, blue, violet, light-purple, pink, light-brown |
| `scnotes rename-folder PATH NAME` | Rename a folder |
| `scnotes trash-folder PATH` | Move a folder, its subfolders and their notes to the Trash, as deleting a folder in Samsung Notes does |
| `scnotes export NOTE DIRECTORY` | Write `NOTE.samsungnote/` with `document.xml`, `text.txt` and attachments |
| `scnotes drawing NOTE OUTPUT.pdf` | Write the approximate handwriting preview |
| `scnotes login` / `logout` | Open the app to sign in / remove the saved connection (cache and drafts remain) |
| `scnotes install [DIRECTORY]` | Install or move the wrapper |

`NOTE` is a note ID, a unique ID prefix of at least four characters, or an exact title (case- and accent-insensitive). Ambiguous matches list the candidates instead of guessing.

`--json` gives machine-readable output for `status`, `list`, `folders`, `search` and `show`. `--offline` never contacts Samsung. Exit codes: `0` success, `1` failure, `2` usage error.

```sh
scnotes list --folder "Math notes" --json | jq -r '.[].title'
scnotes show 1792424464 --json | jq '{title, editable, attachments}'
printf 'Milk\nEggs\n' | scnotes edit "Shopping list" --body-file -
```

`show --markdown` writes formatting as `**bold**`, `*italic*`, `~~strikethrough~~` and `<u>underline</u>`; lists as `- ` (bullets), `2. ` (numbers), `- [ ] ` / `- [x] ` (checkboxes) or the note's own label (`c. `, `iv. `, `③ `); and colour, size and highlight as `{color=#E51C23 size=20 highlight=#FFF59D}text{/}`. Samsung's default text colours and the note's most common size are left out. Literal `*`, `~`, `{`, `}` and `\` are escaped with a backslash. With `--json`, the same text is in the `markdown` field.

`edit --markdown` takes the same form: lines left exactly as `show --markdown` printed them keep their formatting byte for byte, and changed or new lines get the markup they carry on the note's usual size and colour. Without `--markdown`, the text is saved plain.

## Editing safely

`edit` follows the app's save path exactly: it downloads the current revision, refuses locked/encrypted notes and unsupported text, stores a pre-save backup under `Backups/`, uploads, then downloads again and verifies the title and text. If the note changed elsewhere in between, the save is refused.

If the app holds an unsaved draft for the same note, `edit` stops rather than overwrite it. Save or reload the note in the app, or pass `--discard-draft`; the draft is archived under `DraftHistory/` either way.

The same limits as the app apply: plain-text editing replaces formatting in the main text object (`--markdown` and the app's editor keep it), drawings and attachments are retained, and notes are deleted the way Samsung Notes does it: first to the Trash (`trash`), then for good from the Trash only (`delete`). `new` creates plain-text notes only. Their page structure is copied from the simplest plain-text note in the cache (one page, no attachments or drawings); its title, text and span data are never reused. `mkdir` creates folders only; it does not rename, move or delete them.

## Diagnostics

The developer flags documented in [building](building.md) (`--self-test`, `--verify-*`, `--test-save`) are separate from `--cli` and unchanged.
