# Observed Samsung Notes cloud protocol

Inspected on 2026-10-19 using the installed Windows Samsung Notes **4.3.831.0**. These are interoperability observations, not a Samsung-supported public API contract.

## Transport and account

The observed production base URL is `https://api.samsungcloud.com`. The active Windows client used an opaque bearer session. Its protected account credentials were not copied into source, documentation or application binaries.

Observed request headers include:

| Header | Observed value or purpose |
| --- | --- |
| `Authorization` | Opaque `Bearer …` session; secret |
| `x-sn-sdk-ver` | `5500` |
| `x-sn-app-ver` | `4000` |
| `X-SN-XML-VER` | `2` |
| `X-SN-Feature-ID` | Public client feature identifier `O4vARCbQ3G` |
| `x-sn-model-name` | Device display metadata |

Adding `X-SC-DVC-ID` or `X-SC-DID` to these bearer-authenticated calls was explicitly rejected by Samsung's gateway. Those headers are not a solution to creating an independent device identity.

## Index

- `GET /samsungnotes/v1/notes/changes?lastChangePoint=…`
- `GET /samsungnotes/v1/folder/changes?lastChangePoint=…`

Responses are XML. Note changes contain server/resource identifiers, revision/commit identifiers, timestamps and deletion/lock/encryption flags. Note titles are obtained from the documents, not the change list.

The initial cursor is base64-encoded JSON with `version: 0`, empty `encryptedGuid`, zero timestamps, string versions `"0"`, `purpose: "INITIAL"`, and `type: "NOTE"` or `"FOLDER"`. This initial form was present in the shipped sync library. Subsequent cursors are opaque values returned by Samsung. Continue until `hasNext` is false; do not assume one response includes the full library.

The Windows database initially contained 34 notes, including two in the trash. Direct cloud pagination returned the same 34 non-deleted records, plus historical deletions. One separately identified test note was then created for write validation.

## Document and attachments

- `POST /samsungnotes/v1/notes/{serverId}/compareForDownsync`
- Content type: `application/xml`
- Empty local comparison body: `<note ver="1"/>`

This returned a `CompareNoteView` containing `noteResource`, `downloadUrls`, `commitId` and device metadata. The resource includes the note tree, attributes/title, pages, floating objects, main body text, and content-file references.

Attachment download entries associate a content-file identifier with an HTTPS download URL. Observed URLs used a regional `*.samsungcloud.com` host. Download URLs are account data and must not appear in ordinary logs.

Folder names and content-file names use a single Base64 UTF-8 layer. Actual folder names ended in U+200B; 0.1.2 removes that invisible marker for display. A `0@page_0000000.spi` content file was a proprietary Samsung page cache, not a normal attachment. Internal cache resources remain exportable but are not opened in Archive Utility.

## Read-only drawing preview (0.1.2)

Page layers contain `object type="stroke"` elements with Base64 `strokeBinary` data, independently of the SPI cache. Observed records begin with three little-endian 32-bit words: `0xffffffff`, `4`, `4000`, followed by typed base and ink frames. The small Swift decoder bounds every frame and channel, reads saved XY/pressure channels and initial ARGB/pen-size fields, and leaves original XML untouched. Layout facts were checked directly against the account's cloud records and cross-referenced with [sdocx's format research](https://github.com/twangodev/sdocx/tree/main/docs/reverse-engineering); no upstream source is bundled.

This is an approximate stroke preview, not a complete Samsung canvas renderer. Advanced brush effects, erasers, rotations, floating-image composition and unsupported object types need further work. A real 105-stroke document rendered to an inspected PNG and a PDF with the expected page bounds. The complete active library produced five drawing pages and 772 supported strokes; generated PDF page counts matched.

## Typed text

The object's `text` field is base64-encoded UTF-8. Its decoded contents combine `<?a …?>` style markers with further base64-encoded UTF-8 text runs. Decoding only one base64 layer is insufficient. UTF-16 text length is used in the section metadata.

The client retains the original XML. When editing a supported text object, it replaces that object's styled text, updates its modification/hash fields and the corresponding tree entry, and preserves the remaining resource.

### Styled text

Checked against every text object of a 44-note account and notes formatted in Samsung Notes 4.4.45 on a phone:

- A marker holds tokens separated by one space: `'group/key'='value'` opens a style where the marker stands, a bare `'group/key'` closes it. A key is never opened while open, and every key is closed by the end. Positions are UTF-16 offsets. Markers are `<?a …?>` with standard Base64 runs between them and no whitespace, so the stream has one canonical form; the client re-encodes every observed note byte for byte.
- Span styles (`span/…`) have values `flag,property`, where the flag is Samsung's span expansion flag (1 or 3; 2 for links): `foregroundColor` and `backgroundColor` (signed ARGB integers; background 0 = none), `fontSize` (points, e.g. `16.0`), `bold`, `italic`, `underline`, `strikethrough` (`True`/`False`), `hyperText`, `fontName`, `timeStamp`.
- Paragraph styles (`paragraph/…`) are closed and reopened at every paragraph: `alignment` (0 = left), `parsingState` (`True`/`False`), and `bullet` = `type,number[,{levels}]` with types 0 none, 1 arrow, 2 checkbox (`2,true` = checked), 3 diamond, 4 number, 5 circled number, 6 lower-case letter, 7 roman numeral, 8 dot, 9 circle, 10 capital letter, 11 square, 12 white square. Samsung opens a paragraph's styles on the newline before it (the first paragraph's at offset 0), so that newline carries the next line's paragraph styles; a line's paragraph styles are the ones open on the newline before it.
- `sectionData/sectionData` opens with the text's UTF-16 length and closes at the end, followed by `<?a 'sectionData/sectionData'='0' 'sectionData/sectionData'?>`.

When it writes formatted text, the client follows the same pattern: the always-present styles (alignment, parsing state, size, colour) are filled in from the note's most common values, paragraph styles are closed and reopened on every newline with the next line's values, other styles are closed where they end or change, and span order data is removed as for plain text. The readback must give the same runs.

### Text Samsung devices can open

A cloud readback is not enough: Samsung Notes on a phone parses every downloaded note with its S Pen SDK and silently skips notes it cannot parse (its log shows `fail to createLocalNote` and `Spen SDK can't parse a xml note`). Checked against Samsung Notes 4.4.45 on a Galaxy S23+ with `adb logcat` (tags `SENL$SC/...`):

- Every style opened in a `<?a 'key'='value'?>` marker must be closed by a bare `'key'` before the text ends; an open paragraph style fails with "Wrong Annotater Type".
- A paragraph style must open at offset 0 or on the newline before its paragraph: Samsung Notes 4.4.48 finds each paragraph style's paragraph by that offset, and any other offset fails the parse (`DownSyncItem: parseXml` reports a `NullPointerException`). Every note written by Samsung follows this; earlier formatted saves from this client opened paragraph styles just after the newline, so notes with more than one paragraph could not be opened on the phone.
- An object's `timeStamp` is parsed as a 32-bit integer; real notes keep `0`.
- A `spanOrderDataList` must hold at least one `spanOrderData`; an empty list fails to parse. Span order data describes the replaced runs, so the client removes the whole list when it writes plain text.
- Each `noteTree` entry is matched to its element by id + time + hash: `t` must equal the element's `modifiedTime` and `h` its `hash` (the server rejects mismatches with 422 "can not find in tree/resource").
- `NoteResource.createdTime` is in microseconds and `syncModifiedTime` in milliseconds.

Versions before this fix wrote notes that the phone could not open; saving such a note again repairs it.

## Write

- `GET /samsungnotes/v1/notes/{serverId}/info` returns the current revision in an XML attribute.
- `POST /samsungnotes/v1/notes/{serverId}/update` accepts multipart form data with an `application/xml` part named `noteResource`.

The tested upload returned HTTP 201 and a `DefaultView` with resource/revision/timestamp information. A fresh download returned the edited text. The native Mac client also completed this write/readback flow, including accented, Japanese and emoji text.

No delete operation was used. Existing personal notes were not edited by the validation scripts; all writes targeted the separate test note.

## Folder write

Folder changes use `PATCH /samsungnotes/v1/folder` with `Content-Type: application/xml;Charset=utf-8` and a `FolderResource` that lists only the changed nodes. Samsung Notes 4.4.45 for Android uses the same request; no Samsung code is bundled.

```xml
<FolderResource>
  <syncModifiedTime>newest time in the account's tree, including this node</syncModifiedTime>
  <nodeList>
    <node id="new lowercase UUID" type="folder">
      <parentFolderNodeId>root, or the parent folder's id</parentFolderNodeId>
      <syncModifiedTime>current time, ms</syncModifiedTime>
      <createdTime>ms</createdTime><lastModifiedTime>ms</lastModifiedTime>
      <name>Base64 UTF-8 name</name><state>normal</state><trashedTime>0</trashedTime>
      <color>-1</color><order>number of existing siblings</order>
      <requestTime>ms</requestTime><requestDevice>{"model":"…","ver":"…"}</requestDevice>
    </node>
  </nodeList>
</FolderResource>
```

Samsung stores the node's `syncModifiedTime` as sent, and other devices download only nodes newer than their own change point. A first test that sent Samsung Notes' local default (1464416139847) produced a folder that full listings returned but the phone never received; stamping the node with the current time fixed it, and the phone then showed the folder. The app's local default is replaced before upload.

Samsung Notes treats 409 as a conflict, 403 with error 128409 as a client clock ahead of the server, and 500 with 128900 as an account that requires encrypted folder names. The client creates folders only: it reads the tree first (parent, duplicate names, sibling count, newest time) and reads it again afterwards to confirm the folder exists. Renaming, moving, trashing and note membership use the same node shape but are not implemented.

## Note create

Samsung Notes 4.4.45 for Android uploads a brand-new text note in two steps:

1. `PATCH /samsungnotes/v1/folder` with the note's tree node: `type="note"`, the note's UUID as `id`, `parentFolderNodeId` (`root` for no folder), Base64 title as `name` (Base64 of a space for an empty title) and `order` 999999. The server accepts the node before the note exists.
2. `POST /samsungnotes/v1/notes`, multipart with one `noteResource` part holding a `NoteResource` (`id`, `createdTime`, `syncModifiedTime`, `isLocked`, `isEncrypted`, `ownerId`, `xmlVer`, then `noteTree`, `attributes` with the title object, `pageList` and `bodyText`). The response is a `DefaultView` whose `resourceId` is the server id used by every other note request.

Notes with attachments also register files with `POST /samsungnotes/v2/binaries/createUploadURLs` and upload them first; this client creates text notes only. Rather than reproduce the full attribute and page structure, it builds new notes from a template: the simplest plain-text note already in the cache (one page, no attachments or drawings), or one chosen with `scnotes template`. Every id in the template is replaced consistently, its title, text and span order data are replaced or removed, rewritten elements get new SHA-256 hashes, and times are set to now. The template stays on the device.

## Favorites

Samsung Notes keeps a note's star on the note itself: `attributes/@isFavorite` (`true` or `false`) in the note resource, not in the folder tree. Starring is an ordinary note update (`POST /notes/{serverId}/update`) with that attribute changed and the title and text unchanged. Checked live: a note starred from the Mac showed its star in Samsung Notes on a Galaxy S23+, and favorites starred on the phone and on Windows were read correctly.

## Trash and delete

Samsung Notes keeps deleted notes in its Trash for 30 days, then deletes them for good on the device. Both steps change the note's tree node with `PATCH /folder`:

- **Move to Trash:** `state` `trashed`, `parentFolderNodeId` `root`, `trashedTime` now, and `restorePath` = Base64 of `uncategorized:///` plus the folder path the note was in (for example `uncategorized:///Dev/Repos`). For states other than `normal`, `requestDevice` also carries a Base64 `deviceName`.
- **Restore:** `state` `normal`, the parent folder found from `restorePath` (the top level if that folder is gone), `trashedTime` 0.
- **Delete for good:** `state` `deleted`, then `DELETE /samsungnotes/v1/notes/{serverId}?syncModifiedTime=<the note's last known server time>`. Without the parameter Samsung answers 400; a stale time gets 409 (the note changed elsewhere) and 404 means it is already gone.

Samsung Notes never erases a local note because the server deleted it: when a note's node arrives as `deleted`, the phone moves its own copy to its Trash (its log shows `SyncSDocxTrashDeletedLocalNote`) and keeps it there until its 30-day clean-up or until the Trash is emptied on the phone. A note deleted for good from this client therefore leaves Samsung Cloud at once but stays in the Trash of other devices for a while, as it would after a delete from another Samsung device.

This client deletes for good only notes that are already in the Trash. Each change is verified by reading the tree again. Checked live: a note moved to the Trash and restored from a Mac appeared in and left the Trash of Samsung Notes on a Galaxy S23+; a note created, trashed and deleted from a Mac was gone from Samsung Cloud afterwards, while the phone kept its copy in its Trash as described above.

"Math notes" (`math:///`) and "Screen off memo" (`screenOffMemo:///`) are built-in folders that Samsung Notes creates itself; the client does not create subfolders in them.

## Remaining interoperability work

- Samsung may change its private authentication and document APIs; native sign-in and renewal are described in [authentication](authentication.md).
- Actual Samsung-device rendering of the newly encoded text, separate from a cloud readback.
- Complete handwriting/page rendering and `.sdocx` import/export.
- Server-side atomic conflict guarantees.

The Windows application skipped downloading a change tagged with its own borrowed device identity during the initial Windows-session prototype. Native 0.2.0 sign-in uses a separate Mac installation identity. Cloud readback still does not by itself prove Samsung-device rendering.
