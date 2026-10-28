<p align="center">
  <img src="Assets/AppIcon.png" width="112" height="112" alt="Cloud Notes for Samsung Notes app icon">
</p>

<h1 align="center">Cloud Notes for Samsung Notes</h1>

<p align="center">
  An unofficial Mac app for the notes in your Samsung account.<br>
  Read, write and organise them; changes sync back to Samsung Notes on your phone.
</p>

<p align="center">
  <img src="docs/assets/badge-version.svg" alt="Version 2.0">
  <img src="docs/assets/badge-status.svg" alt="Experimental build">
  <img src="docs/assets/badge-platform.svg" alt="macOS, Apple Silicon and Intel">
  <a href="LICENSE"><img src="docs/assets/badge-license.svg" alt="GPL-3.0 license"></a>
</p>

<p align="center">
  <a href="#overview">Overview</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#command-line">Command line</a> ·
  <a href="#limitations">Limitations</a> ·
  <a href="https://danxtream.gumroad.com/coffee">Donate</a>
</p>

## Overview

Cloud Notes for Samsung Notes lets you use the notes in your Samsung account on a Mac. You sign in on Samsung's own sign-in page, and the app works with the same notes, folders and formatting as Samsung Notes on your phone or tablet, so changes made on the Mac appear there after it syncs.

It continues [Samsung Cloud Notes 1.1](https://github.com/Clascheurduturfu/samsung-cloud-notes) by Clascheurduturfu under a new name, with a reworked Mac app. It is an experimental build: it has been used with one Samsung account and Samsung Notes 4.4.48 on one phone, and offline self-tests cover the note format, folder changes and sync decisions. Keep a separate backup of notes you can't afford to lose.

Cloud Notes for Samsung Notes is an independent project. It is not affiliated with, endorsed by or supported by Samsung.

## Features

- **Editing:** bold, italic, underline, strikethrough, text colour, highlight, five text sizes, bulleted and numbered lists and checklists. Changes are saved about a second after you stop typing.
- **Notes and folders:** create notes, star them, move them to the Trash, restore or delete them. Create, rename, recolour and delete folders and subfolders in Samsung Notes' twelve folder colours.
- **Sorting and search:** sort by date modified, date created or name, with favorites at the top if you like; search titles and full text.
- **Offline use:** cached notes and drafts stay available without a connection, and edits made offline are saved when the connection returns. If a note was also changed on another device, you choose, as in Samsung Notes, to keep this Mac's version, the other version or both.
- **Local copies:** a backup before every save, plus drafts and earlier drafts.
- **Blocked notes:** in Settings, block notes from Claude and other tools that use the command line. They can't list, search or read those notes, and the Mac keeps its copies of them encrypted.
- **Command line:** `scnotes` for Terminal and scripts; see [Command line](#command-line).

## Works with Samsung Notes

The Mac app reads and writes the same notes as Samsung Notes, and changes appear on your phone or tablet the next time Samsung Notes syncs. Editing the text leaves a note's handwriting and attachments in place.

| In a note | On the Mac |
| --- | --- |
| Title and typed text | Read and edit |
| Formatting | Read and edit, including formatting added on the phone |
| Folders, subfolders and folder colours | Read and change |
| Favorites and Trash | Read and change |
| Handwriting and drawings | Approximate preview; not editable |
| Images and other attachments | Open and export |
| Locked notes | Not editable |

## Requirements

- **Mac:** macOS 13 or newer. The build is universal (Apple Silicon and Intel); it has been tested only on Apple Silicon with macOS 26.6.
- **Build tools:** Apple's Command Line Tools for Xcode. Full Xcode is not needed, and there are no third-party packages.
- **Samsung account:** one whose Samsung Notes sync to Samsung Cloud, set up in Samsung Notes on a phone or tablet. Tested with Samsung Notes 4.4.48.
- **Network:** a connection for sign-in and sync. Cached notes can be read offline.

## Installation

There are no downloads for this version; build it from source. Releases on the original project are its earlier 1.x versions, not this one.

1. Install Apple's Command Line Tools if you don't have them:

   ```sh
   xcode-select --install
   ```

2. Get the source and build the app:

   ```sh
   git clone https://github.com/Danxtream/cloud-notes.git
   cd cloud-notes
   bash scripts/build-macos.sh
   ```

   The script builds `dist/Cloud Notes for Samsung Notes.app` for both architectures, signs it and runs the offline self-tests. `BUILD_UNIVERSAL=0` builds for Apple Silicon only.

3. Quit any running copy, move the new app to Applications and open it.

Run the first build in a normal desktop session with your login Keychain unlocked. It creates a local code-signing identity there; keep it, because the app and its Keychain helper must be signed by the same identity to reach your saved sign-in, and later builds reuse it. The app is signed only on your Mac, not by a registered Apple developer, and is not notarized.

If the original project's app (Samsung Cloud Notes) is in Applications, move it elsewhere before your first build, or the build reuses its differently signed helper. Expect a Keychain prompt and a new sign-in, and keep the old app until the new one works. [Signing migration](docs/building.md#signing-migration) has the details.

If the build fails because your Swift compiler doesn't support the newest macOS SDK, point `SDKROOT` at one it does, for example:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/build-macos.sh
```

## Usage

1. Open **Cloud Notes for Samsung Notes** and choose **Sign in with Samsung…**. Sign-in and verification happen on Samsung's page in your browser; the app never sees your password.
2. Choose a folder in the sidebar and click a note to read it. Double-click a note, or press Return, to open it in the whole window.
3. Type to edit. Changes are saved to your Samsung account automatically, and the status bar shows when everything is saved or how many notes are waiting.

Right-click a folder for **New Subfolder…**, **Rename…**, **Change Folder Colour** and **Delete Folder…**, and right-click a note to add it to Favorites, move it to the Trash or block it from Claude. **Sort** in the toolbar changes the order of the list. If a note was changed on another device while this Mac had unsaved edits, it shows **Choose Version…**.

To sign out, click your email address at the bottom of the sidebar and choose **Log out**. This removes the saved connection; cached notes and drafts stay on the Mac.

## Command line

`scnotes` works with the same notes from Terminal and scripts. Choose **Cloud Notes for Samsung Notes → Install Command Line Tool…** to install it in `~/.local/bin` (add that folder to your `PATH` if it isn't there). It uses the app's sign-in and cache:

```sh
scnotes list --limit 10 --sort modified
scnotes search "shopping"
scnotes show "Shopping list" --markdown
scnotes new "Ideas" --folder "Projects" --body "First idea"
scnotes folder-color "Projects" blue
```

Add `--json` for machine-readable output, or `--offline` to use only the local cache. Blocked notes are refused. The [command line guide](docs/cli.md) lists every command.

## Limitations

- The app relies on Samsung's private, undocumented cloud service. Samsung can change or close it at any time, and the app may then stop working.
- It has been tested with one account, on one Mac and with Samsung Notes 4.4.48 on one phone. Other Samsung Notes versions may store notes differently.
- Only text edits wait for a connection. Creating notes, Favorites, the Trash and folder changes need to be online.
- Saves check for a newer version first and keep a backup, but Samsung offers no all-or-nothing save, so two devices saving at the same moment can still collide.
- Export writes a folder for this app, not a Samsung Notes `.sdocx` file.
- The iPhone/iPad and Android apps in this repository come from the original project and have not been updated or tested with this version's changes.
- There is no automatic updater. Rebuild from newer source to update.

## Security and privacy

You sign in on Samsung's own page in your browser; the app never handles your password. The resulting authorization is kept in your login Keychain through a small signed helper and renewed automatically. Signing in registers this Mac with Samsung as a device on your account.

The app connects only to Samsung's account and cloud servers. It has no telemetry and sends your notes nowhere else.

Notes, attachments, drafts and backups are stored as ordinary files in `~/Library/Application Support/SamsungCloudNotes/`; treat that folder as private, and use FileVault to encrypt your disk. Blocked notes are the exception: their local copies are encrypted with a key kept in your Keychain. Output from `scnotes` contains note content.

Cloud Notes for Samsung Notes has not received an independent security audit. [Authentication](docs/authentication.md) describes the sign-in and storage in more detail.

## Development

The note format, cloud requests and library model are in `Sources/Shared`; the Mac app and `scnotes` are in `Sources/macOS`. `bash scripts/check-macos.sh` compiles both architectures and runs the offline self-tests without touching your Keychain or Samsung account.

See the [build guide](docs/building.md) for signing and the source map, and the [notes protocol](docs/protocol.md) for the note format and cloud requests.

## Planned features (no timeline)

- Undo and Redo buttons in the note editor, as in Samsung Notes on a phone.

Plans may change, and no date is promised.

## Maintenance

This is a personal project developed with AI assistance and shared for others who find it useful. The software is provided as-is. I do not promise technical support, bug fixes, new features or ongoing maintenance. I update it at my discretion, when I consider it worthwhile; there is no release schedule. Donations do not create any entitlement to support or updates.

## License

Cloud Notes for Samsung Notes is free software under the [GNU General Public License version 3](LICENSE) (GPL-3.0-only). You may use, share and change it. If you share it, changed or not, you must make its source available under the same license and keep its notices, including the author credit in the About window; [NOTICE.md](NOTICE.md) has the exact term.

It is based on [Samsung Cloud Notes](https://github.com/Clascheurduturfu/samsung-cloud-notes) by Clascheurduturfu, whose code was published under the MIT license. That license and its copyright notice are kept in [NOTICE.md](NOTICE.md) and still apply to the original code. The app icon is the original project's own artwork.

Adapted code and other components keep their own licenses; see the [third-party notices](docs/THIRD_PARTY_NOTICES.md).

- [samsung-re-health](https://github.com/charlesbel/samsung-re-health) by Charles Bel (MIT) informed the sign-in code in `Sources/Shared/Authentication.swift`. Its [license](docs/third-party/samsung-re-health-LICENSE.txt) is included in every build.
- [sdocx](https://github.com/twangodev/sdocx) by twangodev: its published format research helped read handwriting data. No sdocx code is included.
- [Inkport](https://github.com/Mhemd139/Samsung_Notes) by Mhemd139 was a reference for viewing Samsung Notes files. No Inkport code is included.

Samsung, Samsung Notes and Samsung Cloud are trademarks of Samsung Electronics Co., Ltd., used here only to say what the app works with. Cloud Notes for Samsung Notes is independently developed and is not affiliated with, endorsed by or supported by Samsung. It contains no Samsung software, code or artwork, and you need your own Samsung account to use it.

## Donate

If you find Cloud Notes for Samsung Notes useful and would like to support my work, please consider [making a donation](https://danxtream.gumroad.com/coffee).
