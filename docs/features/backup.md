# Backup

Export and import of Tinycast's own data as a single `.tinycast` file, plus the entry point for
importing a Raycast export. The feature lives in `Features/Backup/`.

A backup carries five independently selectable categories, ticked on export and again on import:
**Settings & Shortcuts**, **Clipboard History**, **Snippets**, **Notes** and **Launcher Learning**.

## Invariants

- **`SettingsBackup`'s mirror is hand-written, and reflection is never the fix.** `AppSettingsKey` owns
  every key `AppSettings` persists; `SettingsBackupCoverage` says which of them `SettingsData` carries,
  which are sourced from somewhere other than `UserDefaults`, and which are excluded **with a reason**.
  `settings-backup-test` fails when a key is none of those. Adding a setting means editing
  `SettingsBackupCoverage` in the same commit.
- **`snippetsEnabled` is excluded, and that is a security control.** It doubles as consent to keystroke
  listening, so an imported file must not be able to grant it. A `Mirror` or a macro is the wrong
  answer: neither can be read to check what is covered.
- **A flag that grants a capability is never carried by a backup**, whether it is excluded from
  `SettingsBackupCoverage` like `snippetsEnabled` or kept out of `AppSettings` entirely. Importing a
  config must not be able to grant something the user never granted. `FallbackStore` is the second
  case: its order and checkboxes live on their own `UserDefaults` keys precisely so an import cannot
  arm **Run Shell Command** in someone's launcher. This change adds *content*, never a capability.
- **No absolute path may enter a `.tinycast`.** A clip's `imagePath` names a file on the Mac that wrote
  it, so `BackupClipboardItem` carries a bundle-relative `imageName` instead. `backup-archive-test`
  asserts the produced file contains neither `/Users` nor `/Library` — the analogue of
  `settings-backup-test`'s `snippetsEnabled` check, and for the same reason: this file gets sent to
  people.
- **The file carries a format version and a reader accepts only its own.** That is a guard, not a
  migration: the comparison is `==`, so an older and a newer file fail identically and by the same
  statement. Writing it any other way is the first line of a backup-format migration, and there is none.
- **Every export is encrypted, and the passphrase never touches disk.** A `.tinycast` holds clipboard
  history and notes and gets sent around, so `BackupArchive.seal` takes a passphrase of at least
  `minimumPassphraseLength` (10) characters and has no unencrypted path. Only `open` still reads a
  plain LZFSE archive, so a backup written before encryption keeps importing.
- **Extraction admits only regular files and directories, within a budget.** A FIFO would block it
  forever and a tiny file can expand to fill the disk, so `ExtractionBudget` cancels on any other
  entry type, past two million entries, or past the space the volume can spare (64 GB at most).
- **Extensions, AI chat history, Keychain material and anything in `Caches` never travel.** An
  extension is third-party code and third-party data; chat history and API keys stay on the Mac that
  had them; a cache regenerates on its own.
- **`BackupCategory` names every category, and its `descriptor` switch is exhaustive.** A new case
  fails to build until it names a label, a symbol, a bundle subpath and a count noun — the same
  bargain `AppEntry.Kind` makes, and why the bundle layout is never spelled out twice.

## Layout

| File | Role |
| --- | --- |
| `Model/BackupCategory.swift` | The categories and the descriptor every one of them must name |
| `Model/BackupManifest.swift` | The table of contents, the format constant and its guard |
| `Model/BackupBundle.swift` | The payload directory's layout and part-by-part encode/decode |
| `Model/BackupArchive.swift` | Directory ⇄ `.tinycast`; the only file importing `AppleArchive` |
| `Model/BackupClipboardItem.swift` | The portable clip, with no path in it |
| `Model/SettingsBackup.swift` | The settings, fixed/per-item hotkey payloads, and their `Codable` shape |
| `Model/SettingsBackupCoverage.swift` | The coverage declaration the harness checks |
| `Model/RaycastImport.swift` | The importable categories, the `Result` and its per-category trim |
| `Model/RaycastImportError.swift` | The three failures an import reports |
| `Service/BackupStaging.swift` | One scratch tree, created on init and removed on discard |
| `Service/BackupComposer.swift` | Stores → staging; `plan` on main, `write` off it |
| `Service/BackupApplier.swift` | Staging → stores, returning a per-category summary |
| `Service/BackupActions.swift` | The effectful half: file pickers, the archive calls, dialogs, the settings-file switch |
| `Service/RaycastDecoder.swift` | Container recognition, decrypt and decode |
| `Service/RaycastImportReader.swift` | Raycast → Tinycast field mapping |
| `Service/Scrypt.swift`, `Platform/Compression/Zlib.swift` | The crypto and decompression primitives |
| `Settings/BackupCategorySelection.swift` | The category checkboxes, on both halves of the pane |
| `Settings/BackupSettingsView.swift` | The pane, which also holds the [settings file](settings-file.md) switch |

## Inside the file

```
manifest.json              format, app version, createdAt, per-category counts
settings.json              SettingsBackup, exactly as it encoded before
clipboard/items.jsonl      one clip per line
clipboard/images/<uuid>.png
snippets/<name>.md         copied verbatim
notes/<name>.md            copied verbatim
learning/{ranking,emoji,calculator}.json
```

A category the user didn't tick has no key in `counts` and no files in the archive, which is how the
import picker greys a row out instead of importing nothing and saying nothing.

**Clipboard history is JSONL, everything else is JSON.** A single JSON array of 200,000 clips has to be
built in memory to encode and again to decode; a line per clip is one small encode through an open
`FileHandle` on the way out and one mapped read on the way back. Splitting on `\n` is legal precisely
because a newline inside a clip is escaped as `\n` by the encoder and can never appear raw —
`backup-archive-test` asserts the line count equals the clip count for exactly that reason.

**Apple Encrypted Archive around it.** `seal` writes through
`ArchiveByteStream.encryptionStream` with the `hkdf_sha256_aesctr_hmac__scrypt__none` profile: scrypt
stretches the passphrase, then AES-CTR with an HMAC over every segment, with LZFSE applied inside the
encryption. The file starts `AEA1`, which is how `isEncrypted` labels a chosen file before a passphrase
is typed; a wrong passphrase makes `decryptionStream` refuse the header, reported as
`incorrectPassphrase`. AEA's scrypt costs a guess about 35 ms, so the passphrase is stretched first:
600,000 rounds of PBKDF2-HMAC-SHA256 over the NFC-normalised passphrase, salted with a fixed
`tinycast-backup-passphrase-v1:` prefix and 16 random bytes, and the hex result is AEA's password —
which also fits its 20–256-byte limit whatever was typed. The salt and round count ride in AEA's
authenticated `authData` (`TCBK`, a version byte, rounds, salt), readable before the passphrase is;
a file claiming fewer than 100,000 or more than ten million rounds is refused, so a hostile one can
neither weaken nor stall the derivation. The prefix and layout are part of the format.

**AppleArchive, LZFSE, and a deliberately narrow keyset.** `"TYP,PAT,DAT,MOD,MTM"` rather than
`.defaultForArchive`: no `UID`/`GID`, which would restore another Mac's numeric owner, and no `IDX`,
whose hardlink dedup would record a link to a blob outside the staged tree. `MTM` stays because the
note list sorts on modification date. LZFSE rather than LZMA because clipboard PNGs dominate the
payload and are already compressed.

**Extraction is filtered, not trusted.** `BackupArchive.open` passes an `ArchiveHeader.EntryFilter`
that returns `.skip` for any entry whose path is absolute or contains `..`, and then refuses an extract
holding a symbolic link — a link entry names no `..` at all, so the path filter passes it, and reading
through one would leave the tree the caller chose. Composing resolves a link for the same reason, so a
symlinked note travels as a file. `backup-archive-test` builds both hostile archives header-by-header
and asserts nothing escapes.

**Staging lives in `Caches`, not `temporaryDirectory`.** Export unseals each clipboard image into
it as a PNG — only a blob the history's key opens, so a row naming any other file is counted missing
and carries nothing out — and writes the clips' text as JSONL, so for the length of a run the staging tree is
plaintext, which is why each run's folder is created 0700; it is the archive that leaves the Mac
encrypted. Opening a file to import extracts only
its manifest (`open(…, only:)`), so the pane shows categories and counts without unpacking a
history; Import unpacks the whole file again, applies it and discards the tree before returning.
Leaving the Settings pane discards a tree the user opened but never imported; `BackupStaging` sweeps
anything a day old on the next run, and `AppCore.start` sweeps every tree older than the launch, since a
run killed mid-flight leaves its plaintext behind.

**The launcher commands open the pane.** Export Settings and Import Settings land on Settings →
Backup at their section rather than running headless: both need a passphrase, and the palette's
dialogs carry no secure field.

## Coverage, and why it is spelled out

`SettingsBackupCoverage` holds three tables:

- `mirrored` — each `SettingsData` field paired with the `AppSettings` key it carries.
- `externallySourced` — fields no `AppSettings` key stands behind, each saying what it reads instead.
  `launchAtLogin` comes from `LaunchAtLogin`, which owns the login item.
- `deliberatelyExcluded` — keys kept out on purpose, each with its reason as a string.

`settings-backup-test` asserts that every `AppSettingsKey` appears in exactly one table, that no field
claims a key twice, that every exclusion names a real key and carries a non-empty reason, and that each
capability-granting key — `snippetsEnabled`, `extensionsEnabled`, `calendarEnabled`,
`autoJoinMeetings`, `cameraPreview`, `quickActionsEnabled` — is named individually as excluded. The
duplication between `AppSettings` and this file is the point: it forces a decision about every new
setting rather than defaulting it into a backup.

## Importing

Applying an import writes through `AppSettings` like any other change, so feature switches reproject into
the launcher through the normal observation path. An import reports a summary of what it applied — it is
not silent, because a settings file that quietly changes hotkeys is hostile.

Per category:

- **Settings** merge field by field, and a file carrying custom commands or their shortcuts still hits
  `confirmExecutableImport` first. The clipboard's excluded apps are merged rather than replaced, a
  Raycast import's included: a file someone sends can add to what is kept out of history, never
  shrink it.
- **Clipboard** streams through `ClipboardStore.importStoredItems`, off the main actor and on its own
  connection: a restored history runs past the memory window and must never sit in memory or freeze the
  UI. A row is deduped on its text, or on the path its image takes; the staged `<name>.png` is
  sealed into `imagesDir` as `<name>.png.sealed`, the blob it was exported from, so importing one
  file twice lands on the same path and adds nothing, and the row only lands once its blob has. Importing clips opens the history for the
  write even with the feature off, as Clear History does, and reports a locked history as a problem.
- **Snippets** merge through `importSnippets`, deduped on name and body so importing the same file
  twice doesn't leave a second copy of everything. Importing snippets does not enable snippets.
- **Notes** land as new files through `NotesRepository.importNotes`, which suffixes a title that is
  already taken rather than overwriting it.
- **Learning** replaces. Merging two Macs' frecency tables produces a table describing neither.

An `id` never travels with a clip: `items.id` is `UNIQUE`, so a re-import minting fresh identities is
what keeps a second pass from silently failing its inserts. Same reasoning as `QuicklinkArchive.merge`.

The old flat `Tinycast-Settings-*.json` export is gone rather than deprecated, and nothing reads it.

Raycast import is documented separately in [raycast-import.md](raycast-import.md).
