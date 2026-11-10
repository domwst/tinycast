# Clipboard history

## Invariants

- **`clipboardEnabled` ships on — the only feature switch that does.** Absence of the key therefore
  has to outrank a stored `false` in `AppSettings.init`, and off means fully off: the poller stops,
  the SQLite file closes, the launcher commands and their shortcuts go, and Tab skips the screen.
  `ClipboardCoordinator.applyEnabled()` is the single place that applies it.
- **↵, ⌘↵ and ⌃⌘↵ trade places around one setting, and
  `ClipboardDefaultAction.action(for:on:)` is the only place that says which chord runs what.**
  Paste owns ↵, Copy ⌘↵ and Paste as Plain Text ⌃⌘↵; `clipboardDefaultAction` moves one to ↵ and
  Paste takes the chord it left, so a Copy default keeps the ↵/⌘↵ swap it always had.
  `ClipboardCoordinator.activate(_:chord:)` runs it, and ⌘1…⌘0 on a pin and a double-click go
  through the same call, so no surface can drift from the setting; ⌥↵ pastes regardless, since
  keeping the window open is a paste-only idea. The ⌘K menu lists the three in chord order, which
  puts the default first with the ↵ chip.
- **Paste as Plain Text writes `ClipboardItem.plainText` and nothing else**: the text itself, or a
  file entry's path without its `public.file-url`. An image has none, so it gets no plain row, a
  plain-text default pastes it as it is, and ⌃⌘↵ on it falls back to ⌘↵ as on every other screen.
- **Clipboard writes stamp a private `internalType` marker** so the poller skips Tinycast's own writes.
  If the writer and the poller ever disagree, the app re-captures its own pastes in a loop.
- **Edit Entry rewrites a text entry in place and never adds one.** The id, pin and source app
  stay; saving then copies it as Copy to Clipboard does, marker included, so the poller does not
  record the edit a second time.
- **A paste lands only where it was aimed.** `Paster` remembers the pasteboard's `changeCount`
  after writing and drops the ⌘V if anything copied in the wait. A paste that activates an app waits
  up to half a second for that app to be frontmost, since ⌘V goes to whichever app has focus, and
  is dropped rather than sent to another one.
- **Paste Sequentially never promotes, and its walk is frozen at the first press.** `PasteSequence`
  keeps every entry's id, newest first, and resolves each against the live history, so a promotion
  cannot repeat or skip an entry and a deleted one is passed over rather than pasted.
- **`Model/ClipboardStore.swift` keeps to Foundation, CryptoKit and SQLite3**, plus its own
  `ClipboardCipher` and `ClipboardQuery` and `Platform/SealedFile` and `ImageDerivative`, so
  `clipboard-test` can compile it standalone. It uses `isolated deinit` for its SQLite teardown.
- **History never reaches the disk unsealed.** Clip text, file paths, source apps and recognized
  text are AES-GCM sealed per column, image blobs and their thumbnails are `SealedFile`s, and there
  is no full-text index, which would be a plaintext copy. The one exception is a copy another app is
  handed by path — a paste's file URL — made in `Caches/clipboard-exports/` only on request and
  removed once the clipboard holds something else. See [Encryption at rest](#encryption-at-rest).
- **The Model layer never builds a cipher.** `ClipboardStore` opens only with the one
  `ClipboardKeyStore.unlock` hands `ClipboardCoordinator`, read from the Keychain off-main; a harness
  passes its own random key. Nothing defaults to a key, because a default would be a real one.
- **An image capture keeps the generation from its pasteboard poll.** Clear History and store close
  retire it across conversion and file writing; a stale capture inserts nothing and leaves no blob.
- A database that cannot be opened is deleted and recreated, and so is one of another
  `schemaVersion` or sealed under another key, which its canary refuses. That is sound because a
  history is captured rather than authored — `QuicklinkStore` deliberately does the opposite. It is
  **not** a licence to treat the file as disposable: it lives in Application Support precisely
  because nothing else can put it back. A Keychain that answers with an error rather than "no such
  item" never gets this treatment: the store stays shut for the session and a HUD says so.
- **A link or an address is derived from the text, never persisted.** `ClipboardItem.Kind` holds
  only what capture can tell apart on the pasteboard — `text`, `image`, `file` — so improving the
  *classifier* stays a code change rather than a database migration plus a backfill, while a new
  kind needs a new pasteboard type to justify it. `textForm` is nil for anything but `.text`, which
  is what keeps a path shaped like `apple.com/report.pdf` out of the links.
- **A `.file` entry references the file where it lies and never copies it.** Its absolute path is
  the `text` column, so search finds it by name or by folder for free, and `imagePath`
  stays nil — which is what keeps `prune`, `deleteBlob` and `owns` from ever reaching a file
  Tinycast did not write. `kind` is a plain `TEXT` column, so the case cost no migration; an older
  build simply fails to decode the row.
- **A colour is parsed from the text on demand, never stored.** `ColorValue` is the single parser
  behind the clipboard's swatches and the launcher's colour card, so the two can never disagree
  about what counts as a colour or what it converts to.
- **Recognized text is search metadata and nothing else.** It lives in its own `item_text` table,
  never on `ClipboardItem` and never in the resident window, so no surface can paste it, copy it,
  or classify an entry by it. The one exception is Copy Text, which the reader invokes explicitly:
  it extracts fresh in the helper and puts the text on the pasteboard — the `item_text` table
  itself is still never copied from. What an entry *is* still comes from the content that was
  captured.
- **No recognition ever runs in the app process.** `ClipboardTextWorker` spawns one bundled
  `ClipboardTextHelper` per item and reaps it, which is the whole reason Vision's and PDFKit's
  allocations do not accumulate in Tinycast. The helper is handed a referenced file's path, or a
  sealed blob's plaintext over stdin, and answers with text.

## Poll-based capture

**A file URL is read before the text**, because that is the whole of the bug this ordering fixes:
Finder puts the file's *display name* on `public.utf8-plain-string` beside `public.file-url`, so a
text-first poller records `IMG_1234.png` as prose. The read sits after the `internalType` and
sensitive-type guards, which stay unconditional — a secret must never be recorded whatever shape it
arrives in. A bare screenshot carries no file URL and still falls through to the `.png`/`.tiff`
branch untouched.

**Rich text is the last resort.** A copy with no file URL, plain text or image, such as a web page's
HTML-only Clipboard API write, is converted through `NSAttributedString`, RTF before HTML, and
recorded as a plain text entry. It sits after the image branch because a browser's image copy
carries an `<img>` fragment beside the pixels. The HTML importer runs WebKit on the main actor, so
fragments over 256 KB are skipped to bound the stall.

`ClipboardManager.fileURLs(on:volatileRoots:)` takes both the pasteboard and the roots as
parameters, so `pasteboard-test` can drive an `NSPasteboard.withUniqueName()` and its own scratch
tree: a harness that touched `NSPasteboard.general` would land in the reader's own running Tinycast
as a genuine copy. `PasteboardFiles` reads each item's own `public.file-url`, so a copied `http` URL stays a link;
returns nil rather than an empty array, so the text branch runs; caps a batch at
`maxCapturedFiles`, so a Finder select-all cannot insert ten thousand rows on one tick; and
**rejects a file under a volatile root** (`/tmp`, `/var/folders`, `~/Library/Caches`), because an
app that stages a temp export beside better inline content must keep the inline content. Paths come
back reversed so the *first* file copied ends up leading the history. Durability checks stop after
32 accepted files, and decoding stops with them: the reader takes the cap and the durability test
together rather than filtering a list it has already decoded whole. Rejected paths do not consume
the cap, and even a rejected modern file URL suppresses the legacy filenames fallback. The uncapped
`PasteboardFiles.urls(on:)` that attachments use is the same reader with no limit and no test.

`ClipboardManager` runs a 0.5s `Timer` watching `NSPasteboard.general.changeCount`. To avoid
re-capturing Tinycast's own writes, every write stamps a private `internalType` marker on the
pasteboard and the poller skips anything carrying it.

A ⌘C Tinycast sends to read a selection can't carry that marker, since the other app writes it.
`pauseCapture()` and `resumeCapture()` bracket that borrow instead: the poller skips every tick in
between, and the restore's baseline keeps the copy from being recorded once it resumes.
`TextInjector` refuses a second borrow while one is in flight, so the pause is never nested.

`stop()` is the off switch: it drops the timer and the fast-user-switching observers, and clears the
`isCapturing` flag that `prepareForTinycastPasteboardMutation` reads — so a paste Tinycast performs
itself no longer drains the pasteboard into history either.

Existing clips survive being switched off, since a history is captured rather than authored and
nothing else can put it back. **Clear history stays live with the feature off** —
`ClipboardCoordinator.clearHistory()` reopens the file, clears the unpinned rows and closes it again — so a reader
who turns the feature off can still erase what it kept.

## Source attribution

The pasteboard records no source, so the poller asks three witnesses who wrote a copy, and **any one
of them being a disabled app drops it**. Each is widened to every `.app` its executable sits inside
(`ClipboardSource.enclosingAppBundles`), because the app picker only offers indexed apps: blocking
Passwords has to catch `Passwords.app/Contents/Library/LoginItems/PasswordsMenuBarExtra.app`, which
copies while Finder or anything else stays frontmost and marks nothing concealed.

1. **The writer.** `PasteboardOwnerMonitor` runs `/usr/bin/log stream --level debug --style ndjson`
   filtered to `pboard`'s own `Apple CFPasteboard general has new generation N … - pid: P` line. `N`
   is `NSPasteboard.general.changeCount`, so the writer is matched by generation rather than by time,
   and the last 64 are kept. The line arrives within a millisecond, so a poll that races it holds the
   generation for one tick; a drain before Tinycast writes never waits. Only lines whose
   `processImagePath` is `/usr/libexec/pboard` count, each marker must appear exactly once (a
   pasteboard or process named to look like a second record makes the line ambiguous and dropped),
   two owners claimed for one generation leave it unknown, and the writer's executable is resolved as
   its line arrives, before a short-lived helper can exit.
2. **The keyboard-focus owner**, from SkyLight's `SLPSGetTypingFocusProcess` through `dlsym`
   (`Platform/TypingFocus.swift`). It is a process other than the frontmost only when a panel took the
   keyboard without activating its app, which is exactly the menu-bar case.
3. **The frontmost app**, which was the only witness before and still blocks on its own.

Reading a promised type runs the writer's code, which could replace the board with a concealed
copy mid-read, or add a concealed marker to the same item without moving `changeCount`, so after the
content is read and before it is recorded both the generation and the markers are checked again. History records the writer's outermost app, so an Xcode helper reads as Xcode; a writer in no app
bundle, such as `pbcopy`, records the frontmost app as before. Every witness degrades to what
existed before it: a macOS without the SkyLight symbols, a user `log stream` refuses (it gives up
after three quick exits), a changed or ambiguous log line, or a process that kills the stream all
leave the frontmost app as the only vote, which nothing can override. The writer signal raises the
bar against an ordinary helper; it is not a boundary against a process already on the account. The message text is `pboard`'s debug
output, not API, so `clipboard-source-test` pins the parser to the observed line and checks the live
stream against a pasteboard of its own.

## Store

`ClipboardStore` is SQLite-backed: rows in `clipboard.sqlite3`, with image blobs as loose sealed
files, all under `~/Library/Application Support/<bundle-id>/`. The newest 1000 rows are mirrored in
the observable `items` window; the off-main scan in [Search](#search) reaches older rows.

**Application Support, not Caches.** `~/Library/Caches` is excluded from Time Machine and the system
may reclaim it at any time without telling the app, so a history kept there survives neither a restore
nor a full disk — while the retention setting offers **Forever** and a pin is an explicit act.

A database that won't open, or that `prepareSchema` refuses, is deleted and recreated (worst case the
store degrades to session-only in-memory history).

Image capture (TIFF→PNG re-encode, seal and blob write) runs off the main actor via detached tasks;
row inserts, resident search, and pruning stay on the main actor. A capture is
`<uuid>.png.sealed`. Copying an image puts its unsealed PNG on the pasteboard and promises a file URL
through `ClipboardImageFileProvider`: only a reader that asks for one, such as a terminal pasting the
path, gets an exported copy. AppKit reports the provider finished as soon as it hands the URL over,
long before the reader opens it, so the copy belongs to the pasteboard generation the image was
written at instead: every Paster write, the poller's next change of any kind (Tinycast's own marked
writes included), and stopping capture all retire it. A retired provider never writes again: it
answers only while the pasteboard still holds the generation `clearContents` returned for its own
write, and only while no discard has bumped `ClipboardExports.epoch` since it was attached, so a
paste asked for after capture stops can't leave a copy nothing would remove. AppKit also fulfils
every outstanding promise as the app quits, so once the quit is committed
`declineCopiesForTermination` stops minting copies and the clipboard keeps only the PNG; the launch
sweep takes anything a crash left. There is deliberately no
`.string`, which a rich text field would take over the image.

**Tiles and previews decode a copy, not the blob.** A PNG can't decode partially, so a 64px tile of a
6K screenshot cost its full bitmap. The first draw of an owned image unseals it, pipes it to
`ClipboardTextHelper thumbnail <edge>` and seals the PNG that comes back as the `ImageDerivative`
copy it needs, 256px for a row or 1080px for the preview, in `images/.thumbnails/` (excluded from
backup); later draws unseal and decode those. Without a readable copy, from a failed or timed-out
helper or a size past 1080px, the original is unsealed and decoded in the app as before. Copies are
made and deleted on one serial `ImageDerivative.queue`, so a copy's delete waits out the copy in
flight; the blob itself is still deleted at once. The helper's wait runs on that queue, off the
cooperative pool, with a 10 s deadline and the caller's cancellation, and its stdin is written apart
from the stdout read so a full pipe can't deadlock it. Every end of the helper pipes, here and in
`ClipboardTextWorker`, is close-on-exec, so an unrelated child another feature spawns meanwhile
(`PseudoTerminal` closes only its own descriptors) never inherits the plaintext. `load` sweeps copies whose blob is gone,
which a quit before the queue ran can leave. Copies are keyed by the blob's whole file name.

**A backup reads the whole table, not `items`.** `forEachStoredItem(inDatabaseAt:cipher:)` is
`nonisolated` and opens a second connection, because the resident window stops at 1000 rows while
the table is capped only by age — an export that read `items` would silently drop the rest of
someone's history, and walking an uncapped table is not main-actor work. That connection is
`SQLITE_OPEN_READWRITE`, not read-only: a read-only connection to a WAL database still has to create
its `-shm` file, and fails confusingly when it cannot. It reads in `rowid` order, oldest first, so a
streaming import rebuilds the same order it exported, and it answers how many rows would not open,
which the export counts as missing rather than dropping quietly.

**A restore streams back the same way.** `importStoredItems(inDatabaseAt:adoptingImagesInto:cipher:_:)`
is the one insert path a bulk import takes, `importEntries` included: it hashes the existing rows once
into a dedupe set rather than scanning the table per candidate, and seals a copy of each staged or
imported image into `imagesDir` as `<name>.sealed` (so `a.jpg` and `a.png` stay apart) only once
the row is known to be new. Decoding and sealing happen outside any transaction; each batch of 250
rows is then inserted under one short `BEGIN IMMEDIATE`, so a delete on the main connection waits
only on inserts, well inside its two-second busy timeout. It copies rather than moves, because a
Raycast import hands it Raycast's own files; an image whose source has gone is left out.

**A delete reports what happened.** `remove` and `clearAll` return false when SQLite did not finish
the delete — another connection held the lock past the timeout — and then leave the list, the
search results and the blobs untouched, since hiding a row that is still on disk would let the next
load bring it back. The coordinator says "Clipboard history is busy" instead.

**The load query is deliberately two indexed branches**, not one `pinned_at IS NOT NULL OR rowid >= ?`.
It fetches every pinned row plus the newest `memoryWindow` unpinned ones, keyed off the floor rowid
that `windowFloor` looks up. The planner cannot drive an `OR` from an index while preserving row
order, so the single-predicate form reads the whole table instead. The floor is 0 — meaning no floor,
load everything — while the history is shorter than the window.

`promote` updates the row's timestamp and rowid in one statement rather than deleting and
re-inserting it, because a delete would take the row's recognized text with it. The UUID, the sealed
values and the image blob are untouched.

Files under the store's own `imagesDir` are **owned**: pruned and deleted with their row. A retention
cut can strand hundreds of files, so those deletions run off the main actor to keep capture-time
pruning from hitching. `load` also deletes anything in `images/` or `.thumbnails/` that isn't a
`.sealed` file, and any `.partial` seal older than a minute: an older build or an interrupted
conversion is the only way plaintext could be there.

## Encryption at rest

**One root key per channel, in the login Keychain.** `ClipboardKeyStore` keeps 32 random bytes
under `<bundle-id>.clipboard-key`, so the legacy keychain's access list trusts only the app that
created it and any other process reading it gets the system prompt. `unlock` runs off-main, since a
Keychain read can wait on that prompt. It first finishes a swap a crash interrupted, then classifies
the file with `ClipboardStore.inspect` — absent, legacy, sealed, discardable, or **unreadable**: there
but not openable just now (permissions, a lock, an I/O error). An unreadable file, or a sealed one
whose canary can't be read, keeps the store shut with "couldn't be read from disk", because a read
that failed says nothing about the key and must never be grounds to replace it. Otherwise it decides:

- **Found, and a sealed store's canary opens under it:** the history opens with it.
- **Found with no store to vouch for it, or not found** (first launch, a reset Keychain, a deleted
  store): a new key is saved over the item *before* anything is sealed with it, and any history
  sealed under another key is deleted with its blobs, since nothing can ever open it again. A key
  is never adopted on its own word, because any process running as the user can create that item
  first; a garbled item counts as not found.
- **Any other error:** the store stays shut for the session and the coordinator shows
  "Clipboard history is locked"; nothing is deleted and nothing new is recorded.

A new key always goes into a freshly created item: the old one is deleted, the new one added with
`addSecret` (never an update, so an item another process planted in between is refused rather than
kept with the access list it chose), and the item read back must hold exactly the new key, or the
store stays locked. A conversion that fails without a
crash also keeps the store shut, with its own message, since opening would discard the plaintext
file it still has to seal; the next launch tries again.

`ClipboardCipher` derives two keys from the root key with HKDF-SHA256: one for column values and one
for blobs. A column value is AES-GCM with a random nonce and the field name plus row id as associated
data, so a sealed `text` can't be moved into another row or into `source_app`. `image_path` is sealed
to its row the same way, so pointing one row at another's blob makes the row unreadable rather than
showing the wrong image; pruning and Clear History unseal it with the row's id. `meta` holds a canary
sealed the same way; a file whose canary won't open under this key is refused and starts over, its
blobs with it. `kind`, `created_at` and `pinned_at` stay plain, because ordering, pruning and the two
load branches are SQL over them.

**`SealedFile` is the blob format**, for images and their thumbnails: `TCSF`, a version byte and a
16-byte random salt, then the plaintext in 64 KiB segments, each AES-GCM-sealed with its tag. The
salt derives a key for that one file (HKDF over the blob key), so no two files ever share a nonce;
a segment's nonce is its big-endian index and a final-segment flag, and the header and file name are
associated data, so a renamed, reordered, truncated or extended file fails to open, and a cut exactly
on a segment boundary fails on the flag. `plaintextSize` follows from the file size alone, which is
how the info pane states a size without unsealing. Writes go to a hidden `.partial` beside the target
and rename over it. `clipboard-cipher-test` holds the format to all of this.

**A plaintext history from before encryption is converted once.**
`ClipboardEncryptionMigration` runs inside `unlock`, even with the feature switched off, so an old
history never stays plaintext just because capture is off. It builds `clipboard.sqlite3.converting`
with a rollback journal, sealing each row in `rowid` order and copying each image to a `.sealed` blob,
then removes the old file, renames the new one into place, and deletes the old PNGs and thumbnails.
An image outside `images/` — an older release kept whatever path a `.rayconfig` named — is copied
only if `RaycastImagePolicy` admits it, and never touched; a row naming any other file, a folder, a
link or a file that is gone is dropped without reading it. An owned image that fails to seal stops the whole
conversion, so its only copy is never deleted. Every step can be repeated after a crash, and
leftover plaintext images keep it pending until a run removes them, capture on or off. A user who
skips the release that carries it loses that history instead: the store refuses the old
`user_version` and `load` deletes the unsealed files, so skipping it never leaves plaintext behind.

**Nothing a file names is trusted.** `isOwnedBlob` is the only test of ownership, and it wants a
direct `.sealed` child of `imagesDir` on the standardized path, so a row naming `images/../x` is
never pruned, deleted or cleared — every other image path an import hands over is sealed into a
copy. Reads follow the same rule: `imageData` hands out nothing for an image row that isn't an owned
blob, text recognition only ever unseals one, and a backup exports only a blob this key opens. `sealBlob` reads only a regular file by `lstat`, and a Raycast import only accepts what
`RaycastImagePolicy` does: a decodable image inside a `com.raycast*` Application Support folder,
with no `..` and no symlink, so a `.rayconfig` can't put `~/.ssh` into history. Every destructive
sweep — `open()`'s discard, `removeUnsealedFiles`, the thumbnail orphans, exports and backup
staging — checks with `lstat` that its folder is a real directory and never follows a link.

**What this does not cover, and says so.** Copies of the old plaintext in Time Machine backups and
APFS snapshots made before the conversion age out on their own schedule; FileVault is what protects
the disk. The live pasteboard is plaintext to every app, as it is for every clipboard manager. A
sealed value's length tells roughly how long a clip is. The key is in the legacy login keychain,
whose file is encrypted by the login password alone, so a copy of the disk or an unencrypted backup
is as safe as that password; the data-protection keychain would tie it to the Mac, but needs a
signing setup this app doesn't have. Anything able to approve a Keychain prompt as the user, or to
change the default keychain, can read or redirect the key, and a process already on the account
before the store first exists could plant both a key and a store it opens; app-level encryption
can't outlast an attacker who stays. Any process running as the user can also delete the store or
the Keychain item and so force a fresh key at the next launch: that costs the history, never
discloses it. A Keychain item another process created with an access list that refuses Tinycast
can't be replaced, so it locks the history (a denial, never a disclosure). A backup's staging tree
in `Caches` holds plaintext while an export or import runs; `AppCore.start` sweeps any a crash left.

## Search

A query is whitespace-separated terms, **all required, in any order**, each a case- and
diacritic-insensitive substring (`ClipboardQuery.matchesExactly`), so `token github` finds
"github token" and `cafe` finds "Café". Quotes are ordinary characters. With no full-text index, the
work is split by cost:

- **On the main actor, synchronously:** pins and the resident window, exact only. This is what
  answers on the keystroke, and the memo below keeps it one query deep.
- **Off it, in one cancellable scan** over a second connection: rows below the window, recognized
  text, and **loose** matches anywhere. A term of four or more letters or digits matches loosely
  within one edit of a word (two from eight characters, optimal string alignment, so a swap is one
  edit), and the last term, still being typed, may also match the start of a longer word: `pasword`
  and `passw` both find "password". Ideographic terms stay exact, since a "word" there is a
  sentence. The scan unseals as it goes, applies the type filter, and stops once exact matches alone
  fill the budget.

Resident rows matched by their own text come first and are never displaced; exact matches the scan
finds (older rows, and recognized text anywhere) fill the 200-row `searchLimit` newest first, and
loose ones take what is left. Pins sit outside the budget, so the scan reads them in a pass of their
own. The answer then returns to recency order — the window's own order, then older rows by rowid —
because the date headers assume it. Which rows are resident comes from `items` itself, never a
rowid cut-off: a removal or a pin leaves the window short until the next load. A scan runs only while the palette shows (`setSearchActive`), publishes through
`searchRevision` and `onSearchResultsChanged` so the selection follows its row, and leaves
`isSearching` true meanwhile, which the empty state reads as "Searching…" rather than "no results".
Queries under three characters stay resident, as they always have. Results are memoized one query
deep, with a second memo for the empty query, and both are invalidated whenever `items` changes.

## Image and PDF text search

**Search text in images and PDFs is off by default.** The per-machine switch is excluded from
settings backups. A cold disabled launch creates no OCR schema, indexer, search task or Vision request,
and loads no extracted strings. Existing derived data stays on disk when disabled and is reused on
reenabling; deletion and retention still remove it with its original item.

When both clipboard history and text search are enabled, `AppCore` creates its
`ClipboardTextIndexer`. It recognizes locally with Vision's `RecognizeTextRequest`, starting one
background-priority job after two seconds without input, even while the palette is open. A 250 ms
pause separates items; continued typing or mouse movement defers the next job. Existing and imported
history is backfilled, including rows beyond the resident window. Nothing recognizes on the capture
or search path. When only failed work is left the indexer sleeps until a retry is due — a new capture
wakes that wait — and an empty queue exits rather than polling.

Turning either switch off cancels the run in flight; the indexer is kept and reschedules itself once
that run winds down, which is why `applyClipboardTextSearch` can be called again at any time.

Recognition runs in a bundled `ClipboardTextHelper`, one item at a time, and Vision's and PDFKit's
state leaves with it. The parent accepts at most 32 KB from the helper's output pipe, propagates
cancellation, and terminates and reaps a helper that runs past 60 seconds. `ClipboardTextWorker`
does its blocking read and wait on its own `DispatchQueue`, never the cooperative pool. No helper
exists while text search is off or the queue is empty — a Copy Text trigger is the exception: the
helper is bundled either way, so an explicit extraction spawns one with the search switch off.

Images include owned sealed clipboard blobs, unsealed into the helper's stdin, and referenced image
files. Referenced PDFs use PDFKit's embedded
text page by page, with Vision OCR for pages without text. Mixed text-and-scan documents therefore
remain searchable; images embedded on a page that already has text are not separately OCR'd. All
processing stays on this Mac. Extracted text is search metadata, never the value pasted or
copied — Copy Text below is the deliberate exception, a copy the reader asks for.

The derived `item_text` table persists sealed metadata without adding extracted strings to
`ClipboardItem` or loading them into the resident history; an image with no text is stored as NULL,
which switching search back on retries. The [search](#search) scan reads it for All, Images and
Files; Text, Links, Emails and Colors never consult OCR. Type classification always uses original
content. Recognized text counts as an exact match when a term is a substring of it, and loose
matching applies to it as to the clip. Queries under three characters read it only for resident rows
and pins.

Each reader takes a 2 MiB SQLite cache budget and closes its connection when it finishes. A new
query or filter, palette dismissal, disabling, and any history mutation cancel work that is now
obsolete, and a request identity keeps a late answer from publishing. Publication follows the
selected item by UUID; pinning and promoting keep the matches already on screen while it refreshes.
Clearing or reloading rotates the extraction generation, and the insert selects its row rather than
naming it, so it cannot recreate a deleted entry. Backups stream the original fields and never load
OCR metadata.

Work is bounded: files up to 32 MB, the first 64 PDF pages, a 4,194,304-pixel bitmap budget with a
4096-pixel maximum edge, and 32 KB of UTF-8 text per item. An empty, unsupported or oversized input
is a completed attempt. Failed recognition, a locked or unreadable input and a helper failure go to
`item_text_failures` instead: up to three attempts 30 seconds apart, which never block another item.
Success and deletion clear that state. Enabling text search resets failures and earlier empty
attempts so they can be tried again, keeping recognized text that is not empty — so an empty input
may be reprocessed on a later launch, but nothing retries forever inside one session. Tall bitmaps
are recognized in full-width 2048-pixel strips overlapping by 256 pixels, with Vision's relative
minimum text-height cutoff disabled so it cannot discard small text on a tall screenshot or page.
Strips never split a line across columns, and each keeps only the lines centred in its half of an
overlap, so a line is read once and the text keeps its reading order. A referenced file is read once
when it is indexed; editing it later does not refresh the historical search text. Backups carry the
original content and references, and a restored entry is recognized again.

## Copy Text from an image

**Copy Text** extracts the text in the selected image entry and puts it on the pasteboard. One
coordinator entry point, `ClipboardCoordinator.copyImageText(_:)`, sits behind both surfaces: the
⌘K Actions-menu row and the **⇧⌘T** chord (which requires the expanded list, like the other row
chords, and closes an open menu). `ClipboardItem.offersTextExtraction` is the one eligibility
answer — a captured `.image` entry, or a `.file` entry whose kind is an image (a screenshot copied
in Finder) — and it is never a PDF, which stays a background-indexing capability.

The action closes the palette and shows a "Reading text…" progress pill, then stats the file off
the main actor, since a stat on an unmounted volume can stall: a vanished referenced file raises the
HUD every action on that row uses, and a pruned blob says "That image is no longer available." —
the palette is already down, so a HUD is the only thing that can speak. `ClipboardTextWorker` then
spawns the bundled helper: no Vision runs in the app process, nothing reads the `item_text` table,
and nothing depends on the text-search switch, whose helper is bundled either way. The extracted
text is written with `Paster.copyPlainText`, **unmarked**, so the copy enters history like Copy
Path does, and the pill is replaced by the outcome — **Copied text**, **No text found** when the
helper succeeded but recognized nothing, or **Couldn’t read the text** when it failed.

Only one extraction is in flight: a second trigger cancels the first, whose helper is terminated
and which reports nothing. A result never overwrites a newer copy — when the pasteboard's
`changeCount` moved while the helper ran, the text is dropped and the pill says **Clipboard
changed, text not copied**.

The bounds are the indexer's, stated precisely: the helper truncates its output at 32,000 UTF-8
bytes, so a text-dense scan can copy *partial* text under a success HUD, and an input over 32 MB
extracts as empty and lands in **No text found**. The source row is not promoted — a copy is not a
paste.

## Edit an entry

**Edit Entry** (⌘E, or its ⌘K row) opens a `.text` entry in a Tinycast dialog over the dimmed
palette. A file entry never offers it, because its text is a path and rewriting it would repoint
the row. `ClipboardEditField` is the dialog's accessory: a code-mode `FormTextArea`, since smart
quotes or autocorrect would corrupt a token, at a fixed height that scrolls rather than grows the
panel. ↵ starts a new line as in any editor, so ⌘↵ saves and Esc cancels —
`DialogAccessory.acceptsLineBreaks` is what hands ↵ to the field. An input method's ↵ always commits
its marked text, in every dialog.

`ClipboardStore.updateText(_:of:)` reseals the row's `text` under the same id, and nothing else
changes. `Paster.copy` then writes it marked and promotes it
unless pinned, and the palette stays up with the row selected and scrolled into view, so ⌘V pastes
the edit and so does ↵ on the row. A query or type filter that hides the edit is cleared; matching
ones stay. The palette preserves the row through its query and filter observers, including a pin
past the first row. An empty edit changes nothing. An entry deleted while open — by
retention, say — is not brought back: `updateText` answers nil and the text goes on the pasteboard
**unmarked**, entering history as a new copy rather than being lost. A row a scan found past the
resident window has no in-memory copy to replace, so the store drops its search memo instead.
Database write failures throw instead of taking the deleted-entry path: the HUD reports the failure,
and neither the clipboard nor the selection changes.
An edit is held to `ClipboardStore.maxTextLength`, the same 32,000 characters capture records, so a
longer one is refused with a HUD and nothing changes.

## Type filter

The clipboard header carries a `ClipboardFilterButton` at the trailing edge of the search field —
the only palette screen with a control up there. It toggles a `PopoverMenu` anchored `.topTrailing`
under the button, so the ⌘K Actions menu, the app menu and this one are the same view on the same
glass. **⌘P** toggles it; ↑/↓, ↵ and Esc come free from `RootPaletteView`'s one menu path, and the
menu opens highlighting the *active* filter rather than the first row, the way a pop-up button does.
A native, row-height search field above the rows filters their titles with the shared fuzzy matcher;
an empty result centres **No Results** in one row. Escape clears a non-empty query before closing.
The filter is not gated on the list having rows: an over-narrow filter empties it, and the button is
the way back out.

`ClipboardFilter` owns the seven cases and everything the UI needs from them — title, glyph, and the
`emptyMessage` that stops "Clipboard history is empty" from appearing over a history that only looks
empty. The cases are **exclusive**: a copied URL is a link, not a narrower kind of text, so *Text
Only* means prose, and *Colors Only* takes `#FF5733` out of it.

`ClipboardItem.textForm` derives `plain`/`color`/`link`/`email` from the text on demand — nil for an
image.
The classifier is guarded cheapest-first, because `rows` is rebuilt every render: anything over
2048 UTF-8 bytes is plain by definition (`utf8.count` is O(1), `count` walks graphemes), then
a colour, then anything holding whitespace, then a `scheme://` or `mailto:` prefix, an address
shape, and finally a bare domain. Colour runs **before** the whitespace reject, because
`rgb(255, 87, 51)` is one value that happens to be written with spaces in it — every later branch
is a single token by definition. That last step is the only one needing judgement — `report.pdf`
and `index.html` are
domain-shaped — so a bare domain must be lower case (which is what keeps `Safari.app` out) and end
in one of a compact set of TLDs people actually copy. It is a heuristic whose worst case files a row
under the wrong type, and `clipboard-test` pins the cases that matter.

`search(_:filter:)` filters **after** the pinned/rest split, so a matching pin still leads its block
in pin order, and the filter joins the search memo's key — keying on the query alone would serve
stale rows for a render or more, since the filter changes without the query moving. The scan applies
the filter as it reads, so the 200-row budget is spent on rows of the chosen type.

## Colours

A copied colour is drawn as the colour and can be copied back out in another notation. Two
surfaces read one parser: the clipboard history, and the launcher, where pasting a colour answers
with a card the way the calculator does.

`ColorValue` (`Model/`, Foundation-only) is that parser. It takes the CSS spellings people copy —
the four hex lengths, plus `rgb()`/`hsl()`/`oklch()` and their alpha forms in both the comma and
CSS4 space-and-slash syntax — and stores **sRGB components**, so every notation derives from one
source rather than a second parser that can drift from it. An extension's tints and grid swatches
read the same parser, which is how a colour picker's `oklch()` swatch draws as its colour.

**A colour is rejected rather than approximated**, because a wrong swatch filed under Colors Only
is worse than none. An HSL channel must carry its `%`, or `hsl(120, 100, 50)` clamps to white.
Arguments are counted, so `rgb(255,,87,51)` is malformed rather than three good ones with a hole;
each side of a `/` is counted separately, or `rgb(0 255 / 0.5)` reads an alpha as its blue channel.
`Double` also parses `nan`, `inf` and Swift literals CSS never writes, and every notation ends in
an `Int(_:)` that traps on a non-finite value — so the reject sits at the parse boundary.

`ColorFormat` offers four notations: hex, `rgba()`, `hsl()` and `oklch()`, plus the two spellings
named for their alpha, which `offered(for:)` drops from an opaque colour — six rows at most, four
for an opaque one. The digits themselves are `ColorDigits`, private to that file: writing a colour
is the format's business, not the value's. The rest of CSS Color 4 — the space-separated forms,
`hwb()`, `lab()`, `lch()`, `oklab()` — and the `NSColor`/`UIColor`/SwiftUI spellings were all built
and then removed: they
restate the same four answers, and a row you scroll past to reach the one you wanted costs more
than it gives. `oklch()` stays as the one perceptual space people write, and `hsl()` keeps one
decimal because whole degrees cost up to 5/255 on the way back. `clipboard-test` sweeps every
offered notation and re-parses it, bar `oklch()`: it states fewer digits than the channel the
sweep compares to.

`ColorSpaces.swift` holds Oklab and its polar form, both ways — matrices and cube roots, no tables.
Oklab is private to it: `oklch()` is the one thing it exists for. A neutral is stated with no hue at
all, since `atan2` over two rounding errors still names a direction.

The notations are a menu of their own under the launcher card, and **nowhere else** — a history
entry's ⌘K stays the actions it always was, since converting a colour is not something you reach
for while browsing what you copied. **There is no submenu** either, the palette's menu being one
level deep, so each row states its value through `PopoverMenuItem.detail`, never `shortcut`, which
renders one keycap per character. The rows carry `PopoverMenuIcon.blank`, a run of rows under one
repeated eyedropper saying nothing, and the menu keeps the standard `menuWidth`: every notation
fits it, and a menu that widened for its content would jump as rows changed.

`ColorSwatch` is the one place a colour is drawn — row thumbnail, preview and card alike — over a
checkerboard built only when there is alpha to show, so an opaque colour never pays for a `Canvas`
nothing can see. The preview shows the colour and the copied text and nothing else. Detection is
narrow by design: anything past 64 UTF-8 bytes is not a colour, and no named colour (`red`) is
recognised, since a bare English word is prose far more often than CSS — and **a colour is never
named**: `#D6D6D6` is a swatch and its digits, never *Silver*. `NSColorList` naming was built,
measured and removed; it knew only the 59 names macOS ships, so most colours read as nothing, and
CSS's own (`gainsboro`) are in no catalog at all. The card runs **after** the calculator, which
costs nothing — no colour notation is also an expression.

`ColorCard` is built from the calculator card's own parts — `LeadCardColumn` and
`.leadCard(selected:)` — so a lead card can't change height or hover with its kind. Its swatch is
**stretched to the value column rather than sized**, since no notation has a fixed height.

## Pinned entries

A row's ⌘K Actions menu carries **Pin Entry / Unpin Entry** (⌘., since ⌘P opens the type filter),
persisted as a `pinned_at` column on `items` —
a stamp rather than a flag, because the Pinned section is ordered by _when you pinned_, not by
recency.

Pins change five things:

- **Order.** `search` returns pinned rows first — for the empty query and for scan hits alike — under
  one "Pinned" section above the date buckets, in pin order with the oldest pin at the top, so a new
  pin joins the end of the section instead of displacing the ones already there. `items` itself stays
  in pure recency order; the display split is memoized next to the search memo and invalidated with
  it. Original text on pinned rows is matched exactly **in memory**, which holds because every
  pinned row is resident in `items`, however old (`load` fetches them all, and neither the window
  trim nor pruning drops one). The scan adds pins that match only loosely or by recognized text,
  without the unpinned result limit.
- **Unpinning re-recencies.** An unpinned row rejoins the history as its _newest_ entry (Raycast does
  the same) rather than dropping back into the date bucket it came from, which would scroll the list
  out from under the selection. It uses the same atomic timestamp and rowid update as `promote`.
- **Retention.** Pruning skips pinned rows (`AND pinned_at IS NULL`), so a pin outlives the retention
  window — and "Clear History" skips them on the same condition, so only `remove` drops a pin.
- **Selection.** Pinning lifts a row out of its date bucket, so `ClipboardCoordinator.togglePinnedClip` moves the
  palette selection to the row's new index in the _current_ results and bumps `palette.followToken`,
  which is what makes the list scroll the highlight back into view.
- **Landing.** A pin shapes the order, never the default selection. Every reset — opening the screen,
  clearing the query, changing the type filter — lands on the newest clip below the Pinned section
  (`ClipboardStore.landingIndex`), and the palette centres it so the pins stay in view above. A typed
  query lands on its first match instead, pinned or not: the pins are results then, not a shelf.

Pasting a pinned entry deliberately does **not** promote it: it holds its place in the Pinned
section, so `promote` skips pinned rows instead of rewriting the row for no visible change.

Paste and Keep Window Open (⌥↵) does not promote any entry. The rows hold still under the
selection, so ↓ then ⌥↵ pastes a run of entries in order. `Paster.write` therefore only writes the
pasteboard; `paste` and `copy` promote after it, and `pasteInPlace` does not.

The ten palette slots shared with launcher favorites address this visible Pinned block too. A slot
uses the current query and type filter, so its first entry is the first visible pin; a missing slot is
a no-op. They are fixed to the physical number row, with ⌘1…⌘9 then ⌘0 as their labels.

`load` reads every pinned row plus the newest 1000 unpinned ones as two indexed branches over a
partial index on `pinned_at` (`Tests/clipboard-test.swift` covers the shape). The single
`pinned_at IS NOT NULL OR rowid >= ?` form reads better but cannot be driven from an index while
holding row order, so it scans the whole table — ~12ms against ~1ms at 200k rows, on the main actor
at launch.

## Referenced files

A file copied in Finder is recorded as a reference, never as a copy: Tinycast writes nothing to
disk for it, and the row's path points at the original wherever it lies. That is the whole reason
`imagePath` stays nil for a `.file` row — `owns()` is the one ownership rule, and a path it never
sees can never be deleted by `deleteBlob` or a retention cut. `clipboard-test`'s
`referencedFilesOutliveTheirRows` is the case that pins it, across `remove`, a retention cut and
Clear History alike.

**Pasting writes two flavours.** `public.file-url` so Finder, Mail and anything file-taking receive
the *file*, and `.string` carrying the **path** — deliberately not Finder's own choice of the name,
because a text field or Terminal almost always wants a path, a name is recoverable from a path and
a path is not recoverable from a name. "A name arrived where a file was meant" is the bug being
fixed, so it must not be reintroduced on the way out.

**A vanished file is reported, never silently swallowed and never auto-deleted.** `Paster.write`
returns false, the coordinator raises a HUD, and the row survives — history is a record of what
happened, and the recorded path is still the answer to "where was it?". The preview says so in
place, and the Path row keeps showing where the file used to be.

`FilePreviewThumbnail` is the row tile and the preview still. `QLThumbnailGenerator` is the only
thing that renders a *content* thumbnail for any type — a video's poster frame, a PDF's first page
— and with `representationTypes: .all` it falls back to the type icon itself, so every file paints
something through one path. It copies `ImageThumbnail`'s shape exactly: two byte-bounded caches
split at 128px, cost measured as the real bitmap footprint, and `purgePreviews()` called from
`PaletteWindowController.hide()` beside the other two.

**The player's teardown is the part with a lifetime to get wrong.** `orderOut` leaves the SwiftUI
tree mounted, so `onDisappear` never fires on hide — which is exactly why `hide()` already has to
purge caches by hand. `PaletteState.isVisible` is therefore the second half of the player's
`.task(id:)` key, alongside the URL, so one mechanism covers both teardown triggers with no
`onChange` racing it. Teardown calls `replaceCurrentItem(with: nil)` and not merely `pause()`: a
paused `AVPlayer` still holds its asset reader and decoder open, which is how a 100 MB budget goes.
Nothing ever autoplays — arrow-keying a list of twenty videos must not start twenty decodes. The
player view is `KeyboardFocusRefusing`, so clicking its transport leaves the caret in the search
field; see [palette.md](palette.md#the-keyboard-belongs-to-the-search-field).

**`clipboardMediaHeight` is a cap, not a height.** As a fixed `frame(height:)` the player asked for
260 pt whatever the pane had: with the Information block's 175 pt beneath it the column wanted 435 pt
of a 359 pt content area, and the overflow pushed the bottom bar out and the panel taller. Every other
preview kind already shrinks — an image scales to fit, text scrolls — so the player does too, and only
its maximum is a token.

**A backup carries the path, never the bytes.** `BackupClipboardItem.file` exports `text` and no
blob, a file already gone at export time is counted missing, and a restore drops a row whose path
does not exist on this Mac — the same thing the Raycast import already does for an image path.
Carrying file bytes would make a backup unbounded and defeat the point of referencing in place.

## Dragging out

Every row is a drag source, so reaching another app costs one gesture instead of Reveal in Finder and
a second drag. The press and the session are `onRowClick`'s `drag:` in
`DesignSystem/Interaction/RowClick.swift`, shared with [File Search](file-search.md#dragging-out) and
the launcher's [application rows](launcher.md#dragging-an-application-out); `ClipDrag.swift` is only
what a clip hands over. `ClipboardItem.dragPayload` says in what flavour: the file URL
for an image or a referenced file, a URL and its text for a link, plain text for the rest. It is
derived and never persisted, like `textForm` beside it, and `textForm` stays the one answer to
whether an entry is a link, so the drag and the type filter cannot disagree.
`QuicklinkDestination.detect` builds the URL rather than a second parser.

**Copy, always. That is why the drag is AppKit and not `onDrag`.** `imagesDir` lives in Application
Support, on the boot volume, which is the same volume as almost every drop target. A file-URL drag
there defaults to a move, and a move carries the blob out of the history and strands its row. Only
an `NSDraggingSource` can answer `sourceOperationMaskFor`, and `RowPressView` answers `.copy` for
every context. SwiftUI's `onDrag` takes an `NSItemProvider` and nothing else. A `.file` row is
copy-only for the reverse reason: the path is the user's own file, and Tinycast must not move it.

**It claims mouse-down, like `WindowDragHandle` does, because the hosting view eats the click
first.** The overlay owns the whole press: select on the way down, activate on a double click, and
start the session once the pointer passes 4pt of slop. A press that stays inside the slop was a
click, which is why the press takes `select` and `activate` instead of sitting beside a tap gesture
that would never fire. It declines the right button in `hitTest`, the mirror of what
`RightClickCatcher` does with the left one — an overlay that answers every event would sit on top of
the actions catcher and silently swallow the menu.

**The payload resolves on mouse-down, not on every row render.**
`ClipboardCoordinator.dragPayload` stats the file first, so a vanished one raises the HUD rather
than handing another app a dead path, the same answer Reveal and Open give. That is one stat per
drag instead of one per row per frame.

**Previews are drawn, never snapshotted.** SwiftUI renders into layers, so `cacheDisplay` on the row
returns a transparent bitmap and the drag carries nothing the eye can follow. A file uses the row
tile, `cached` only and never `load`, because a decode on mouse-down stalls the frame the drag
begins on. A link or a copy gets a drawn text tile. The dragging frame is sized to that image and
centred on the cursor, since the row's own shape would stretch a thumbnail.

**A landed drop hides the palette**, the ending a paste has, through `PaletteCoordinator.dragLanded()`
— the one ending every draggable row shares. A cancelled
drag leaves it up and animates back to the row it came from, so a drag that achieved nothing says
so. The session outliving the panel is safe for the reason the player teardown above is delicate:
`orderOut` leaves the SwiftUI tree mounted, and the pasteboard holds the payload from the moment the
session begins.

## Paste Sequentially

A command, so it is bound in Settings ▸ Clipboard like any other. Each press pastes the next older
entry — text, image or file — into `PaletteCoordinator.targetApp` through `Paster.pasteInPlace`:
⌘V goes to that app's pid, and nothing is activated or promoted. An image or file gone from disk
writes nothing, so the same press moves on to the next entry.

**A press drains the poller before it writes**, through `prepareForTinycastPasteboardMutation`. A
copy made inside the 0.5s poll interval would otherwise be overwritten unrecorded, and the walk
would start one entry too old.

**What keeps a walk going is the pasteboard count its own write left.** Any other count means the
user copied since, and a pause of `PasteSequence.idleTimeout` (60s) since the last paste does the
same; either starts the walk over from the newest entry. Past the oldest entry a press shows
**Nothing left to paste** rather than wrapping. The pasteboard keeps the last entry pasted, as after
any other Tinycast paste.

**A press within `PasteSequence.settleInterval` (0.25s) of the last paste is dropped, not queued.**
`pasteInPlace` writes the pasteboard at once and posts ⌘V 50ms later, and the target reads the
pasteboard only when it handles that ⌘V. A press inside that gap would swap the pasteboard first:
one entry pasted twice, another skipped. A queue would replay a held shortcut as a burst.
