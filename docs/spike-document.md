# Spike: document layer, packaging, external-change reload

Everything below was measured on this machine (macOS 27.0.1 / 26A434, Apple M5 Pro, Swift 6.4 with Command Line Tools only,
language mode 5, deployment target 14, **release builds**), with real child-process writers, a real `NSDocumentController`,
and (apart from the exceptions below) without any window or alert reaching the screen. Numbers are medians; anything surprising is called out.
Exceptions, for honesty: (1) one early probe run ordered a 300x228 titled window front from a `.prohibited` process for well under a second (that is how I learned it is *listed on-screen*, section 7; windows are never ordered front since);
(2) the ~8 Launch Services launches of section 1.3 (`open -g -j`) showed a Dock icon for ~1.5 s each, windows hidden.
All code referenced here compiles together as one SwiftPM target named `Scribe` (module `Scribe`) and passes
`Scribe --selftest all` (18 scenarios, 485 checks, ~95 s; three consecutive full runs on the final code all passed).

Files: `docs/spike-document-code/*.swift` (drop-in), `Scripts/build-app.sh`, `Resources/{Info.plist,make-icon.swift,AppIcon.icns}`.

---

## 0. Executive summary

| Question | Answer |
|---|---|
| Does `NSDocument` reload a clean document when the file changes? | **No, not for uncoordinated writers** (shell, vim, VS Code, git, Python `os.replace`, build tools): it only calls `presentedItemDidChange` 0.5-1.1 s later on a background queue and does nothing else. It **does** revert by itself (~0.5 s) after a *file-coordinated* write (iCloud/File Provider style clients, `NSFileCoordinator`). |
| What do we do? | `ExternalChangeMonitor` (kqueue on the file **and** its directory) + NSFilePresenter echo + app-activation/window-key + a synchronous check in front of every save, all funnelled into one idempotent `checkForExternalChange`. Typical latency **50 ms**, one `stat(2)` when nothing changed, zero idle cost. |
| Dirty document + external change? | Line-based **3-way merge** (base = text at last sync, captured at the first keystroke); success = one *undoable* edit + a self-hiding info banner. Overlapping edits = non-modal banner `[Reload from Disk] [Keep My Version]`, autosave held back (silently, `NSUserCancelledError`), explicit save/close show *our* sheet. NSDocument's own "changed by another application" sheet never appears. |
| Undo after reload? | Clean reload: **clear** the undo stack (stale entries can corrupt text), not dirty. Dirty merge / "Reload from Disk": **one undoable edit** (Undo brings typed work back). |
| Reload without flicker? | UTF-16 prefix/suffix + line-level Myers diff -> a few `replaceCharacters` in one `beginEditing/endEditing`, selection mapped through the edits, scroll position re-anchored on the first visible line (TextKit 1 and 2). 1 MB: 0.4-1.4 ms, 10 MB: 3-14 ms. |
| Fast read/write? | Plain `read(2)` (not mmap: SIGBUS), `NSString(bytes:encoding:)` for UTF-8 (10 MB ASCII 0.5 ms, 10 MB mixed 15 ms), chunked `getBytes` for writing (10 MB: 6-8 ms). Open of 10 MB through `NSDocumentController` incl. window + text view + first laid-out screen: **13 ms (ASCII) / 29 ms (non-ASCII)**. |
| Bundling without Xcode | `Scripts/build-app.sh` (works from any cwd, ~5 s incremental), `Info.plist` with module-qualified `Scribe.MarkdownDocument`, generated icon, ad-hoc signature, self-verification. Launch Services black-box test passed (`open -a`, restoration, 9 extensions). **One real trap:** `.mkd` (and any extension the system does not declare) needs an *exported* UTI of our own; imported declarations do not extend system types. |
| Autosave in place? | **ON**, `autosavingDelay = 3` (stock default is 15.0 s): dirty windows live seconds, so external changes nearly always meet a clean document. The policy also works with it OFF (scenario `autosave-off`). |

---

## 1. Bundling without Xcode

### 1.1 `Scripts/build-app.sh`

```
Scripts/build-app.sh                  # release -> <repo>/build/Scribe.app
Scripts/build-app.sh --debug
Scripts/build-app.sh --out /dir       # -> /dir/Scribe.app   (a path ending in .app is used as the bundle itself)
   extra: --scratch-path <dir> --package-path <dir> --product <name> --info-plist <file> --no-sign
```

`set -euo pipefail`, resolves its own location (works from any cwd), steps: `swift build -c <cfg> --product Scribe` ->
`--show-bin-path` -> `Contents/{MacOS,Resources,Info.plist,PkgInfo}` -> icon -> `codesign --force --deep --sign -` ->
`plutil -lint`, `codesign --verify --deep --strict`, and a check that **every `NSDocumentClass` exists in the binary**
(`Module.Class` -> mangled `_TtC6Scribe16MarkdownDocument`) because a typo there only shows at runtime.
Verified: release + debug, `--out` as dir and as `.app`, bad arguments, `--help`, building another package with its own scratch path.

* Pitfall in my own first version: `strings | grep -q` under `pipefail` is flaky (SIGPIPE); the check uses `grep -aqF` on the binary.
* The icon is `Resources/make-icon.swift` (CoreGraphics + CoreText, no assets, indigo gradient, heavy rounded "M" + the Markdown down arrow, every size
  rendered natively). Output is **bit-identical across runs** (same `.icns` SHA-1 twice). `AppIcon.icns` is committed; the script regenerates it only if
  missing or older than the generator (2.3 s via the `swift` interpreter).
* Ad-hoc signing changes the code identity with every build, so **TCC grants (Documents/Desktop/Downloads) are re-asked after each rebuild**; a stable self-signed
  identity would avoid that. The bundle id `local.scribe.Scribe` is a placeholder (commented in the plist): it keys UserDefaults, recents, restoration, TCC.

### 1.2 Info.plist and UTIs on this macOS

| extension | `UTType(filenameExtension:)` / file content type |
|---|---|
| md, markdown | `net.daringfireball.markdown` - **declared by the system** (exts md, markdown; mime text/markdown; conforms to `public.plain-text`) |
| mdown mkdn mdwn mdtxt mdtext | `com.soulmen.ulysses3.markdown` - only because **Ulysses is installed here**; it conforms to `net.daringfireball.markdown` |
| mkd | **dynamic** `dyn.ah62d4rv4ge80445e` - nobody declares it |
| txt, text | `public.plain-text` |

There is also a *different* system type `public.markdown` (ext md/markdown, no supertypes) that does not conform to anything; files get `net.daringfireball.markdown`.

**Measured: an imported declaration does not add extension tags to a type the system already exports.** With the originally requested plist (imported
`net.daringfireball.markdown` with 8 extensions) `.mkd` stayed `dyn.*`, NSDocumentController found no document type, and a launch with that file
**hung on an error alert that was invisible** (app launched with `open -j`). Fix, now in `Resources/Info.plist`: an **exported** type
`local.scribe.Scribe.markdown-extensions` (conforms to `net.daringfireball.markdown`, tags mkd mdown mkdn mdwn mdtxt mdtext) that is also listed in the
Markdown document type. With Ulysses present it keeps its extensions (no side effect on `.mdown`), without Ulysses ours win. **Change that identifier together
with `CFBundleIdentifier`.** The imported declaration is kept for older systems.

Document types: Markdown (Editor, rank Default) and `public.plain-text` (Editor, rank **Alternate**), both `NSDocumentClass = Scribe.MarkdownDocument`
(module-qualified: confirmed resolving; `NSDocumentController.documentClassNames == ["Scribe.MarkdownDocument"]`).
`LSMinimumSystemVersion 14.0`, `NSHighResolutionCapable`, `LSApplicationCategoryType public.app-category.productivity`,
`NSPrincipalClass NSApplication`, `NSSupportsAutomaticTermination`/`SuddenTermination` true (NSDocument switches them off while edits are unsaved),
no usage-description keys, no entitlements, no ubiquity keys.
`NSDocumentController.defaultType = net.daringfireball.markdown`, `writableTypes = [markdown, plain-text]`.

### 1.3 Verification with real Launch Services (and how it was kept safe)

A copy of the bundle with another bundle id and **both ranks `Alternate`** (`make-ls-variant.sh`, so it can never become a default handler) was registered
(`lsregister -f`), then launched through Launch Services with `open -g -j -a <app> file ... --args -ScribeReport out.json` (`-g` no foreground, `-j` hidden;
the app writes a JSON description of its documents/windows ~1 s after launch and quits - `AppDelegate.writeReport`):

* `open -a Scribe file.md` -> 1 document of class `Scribe.MarkdownDocument`, type `net.daringfireball.markdown`, 1 window, no untitled document, file in the recents.
  (Dock-icon drop uses the same `odoc` Apple event.)
* launch **without** file, clean state (`-ApplePersistenceIgnoreState YES`) -> exactly **one** `Untitled` document, **no Open panel** (no extra window).
* launch without file after a previous run -> the previous document window is **restored** (state restoration works with `NSQuitAlwaysKeepsWindows`).
* `.md .markdown .mdown .mkd .mkdn .mdwn .mdtxt .mdtext .txt` in one `open` -> 9 documents, all `Scribe.MarkdownDocument`.
* `lsregister -dump` shows `claimed UTIs: net.daringfireball.markdown, <exported>, public.plain-text` and the exported type with its six tags.
* The Save panel (captured, never shown) offers **`Untitled.md`**, `allowedContentTypes = [net.daringfireball.markdown, public.plain-text]`, no format popup,
  `allowsOtherFileTypes = true`; a typed name without extension became `.md` (observed with the captured panel; AppKit appends the preferred extension of the first allowed type).

Recipe (all paths in a scratch dir, never in the project):

```sh
cp -R build/Scribe.app $T/ScribeLS.app && P=$T/ScribeLS.app/Contents/Info.plist
sed -i '' 's/local\.scribe\.Scribe\.markdown-extensions/local.scribe.spiketest.markdown-extensions/g' $P
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.scribe.spiketest" $P
/usr/libexec/PlistBuddy -c "Set :CFBundleDocumentTypes:0:LSHandlerRank Alternate" $P     # and :1
codesign --force --deep --sign - $T/ScribeLS.app
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -f $T/ScribeLS.app                                  # (launching registers it anyway)
open -g -j -a $T/ScribeLS.app f.md --args -ApplePersistenceIgnoreState YES -ScribeReport $T/report.json
$LSR -dump > dump.txt                                    # entry for the bundle id: "claimed UTIs", exported type + tags
$LSR -u $T/ScribeLS.app                                  # ALWAYS, afterwards
```

**Hygiene (a surprise):** Launch Services registers *every* bundle that is launched, even by executing the binary inside it directly. After my runs it knew six
scratch bundles. All were `lsregister -u`'d afterwards; the final check showed 0 entries under the scratch dir, `.mkd` dynamic again, and
`NSWorkspace.urlForApplication(toOpen: markdown/plain-text)` identical to the snapshot taken before the experiments (the default handlers were never touched).
The self-test runner therefore runs from the Alternate-rank variant.

---

## 2. External change of a CLEAN document

### 2.1 What `NSDocument` does by itself (stock probe, `experiments/`)

Subclass that only logs. Same results with `autosavesInPlace` true/false and when opened through a symlinked folder (written through the real path in
round 2). Two rounds per writer (round 2 proves the presenter survives replacement).

| external writer | `read(from:)` / revert? | `presentedItemDidChange` | notes |
|---|---|---|---|
| a `echo >> f` | **no** | once, **0.74 s / 1.05 s** (round 1 / 2) after the writer exited | background queue (not main); then `checkAutosavingSafety` on main -> OK |
| b `cat > f` (truncate+rewrite) | no | 0.75 / 1.07 s | |
| c atomic replace (tmp + mv) | no | 0.74 / 1.07 s | still delivered in round 2 |
| d delete, recreate (50 ms / immediately) | no | 0.69 / 1.0 s, 0.72 / 1.06 s | **one** change event, no deletion callback |
| e rename away, edit, rename back | no | 0.53 / 0.85 s | |
| f same size, same mtime (`touch -r`) | no | 0.68 / 1.06 s | the file-coordination daemon sees it |
| g 20 writes in 1 s | no | 2 events during the burst | |
| h 10 MB atomic replace | no | 0.71 / 1.06 s | |
| `fileModificationDate`, title, `fileURL` | **never updated** | | no sheet/alert in any scenario |
| `rm f` (permanent) | - | **no callback at all** | doc stays open, `fileURL` unchanged |
| `mv f elsewhere/` or rename in place | - | `presentedItemDidMove` after 0.75-1.07 s | NSDocument updates `fileURL` itself (note: `/private/tmp/x` becomes `/tmp/x`) |
| **coordinated** write (`NSFileCoordinator`, `.forReplacing`) | **yes**: `presentedItemDidChange` -> `revert(toContentsOf:)` -> `read(from:)` -> `updateChangeCount(.changeCleared)` | ~0.5 s | what iCloud / File Provider clients cause |

Posting `NSApplication.didBecomeActiveNotification` / `NSWindow.didBecomeKeyNotification` by hand did not make NSDocument reload either. I could not
activate the app for real (no focus stealing allowed), so the stock *activation* behaviour in a real GUI session is unverified.
Conclusion: **an editor that must show agent/tool edits has to do its own watching**; NSDocument's presenter is a 1-second-late safety net (and the only
trigger for coordinated writes).

### 2.2 The supplement (what ships in the drop-in code)

```
ExternalChangeMonitor ──┐  kqueue: file fd (write/extend/attrib/delete/rename/link/revoke) + parent-directory fd (entries changed)
NSFilePresenter echo  ──┤  presentedItemDidChange/Move/Gain/Deletion  -> main-thread hop (1 s late, catches coordinated writers)
activation / key      ──┼─►  checkForExternalChange(reason)   [main, idempotent]
save gate             ──┤  every save/autosave first calls the same logic synchronously
poll (non-local FS)   ──┘  2 s stat poll, only on SMB/NFS/AFP/WebDAV/FUSE (kqueue sees only local changes)

stat(path)  == last signature (dev, inode, size, mtime, **ctime**)  -> done (1 syscall)
signature differs -> background: read(2) + FastHash64 (26 GB/s) [+ decode only if the hash differs]
   hash == last hash  -> touch/chmod/identical rewrite/xattr churn: refresh signature, no reload
   hash differs       -> main: clean ? silent reload : merge-or-conflict
```

Details that matter:

* **ctime is in the signature.** The nasty writer that rewrites in place with the same size and restores mtime (`touch -r`, `rsync -t`, `cp -p`) cannot restore ctime.
  Case f is detected (also with the kqueue monitor stopped, via activation).
* **The file descriptor is re-bound after every burst** if the path now names another inode (atomic replace leaves the old fd on an unlinked inode - the classic
  "watcher dies after the first reload"). Ten consecutive atomic replacements: 10/10 detected, 10 rebinds. The *directory* fd is what notices replacements/delete+recreate/rename-back.
* **Burst handling**: a callback `settleDelay` = 50 ms after an event (never later than `maxDelay` = 0.4 s after the burst's first event); once two callbacks happened within the last
  second, further ones are never closer than `minInterval` = 0.3 s. Before the throttle, 20 writes in 1 s gave 19 reloads; now 5-7 (final text always equal to the file); a single change
  (also right after another single one, e.g. the xattr write of `open`) is still answered after 50 ms. A truncate+rewrite writer is not
  read half-written: `DiskReader` retries while the fstat signature changes under the read.
* **No duplicate reloads**: the presenter echo ~1 s later, the open-time xattr write (`com.apple.lastuseddate#PS` bumps ctime on every open: exactly one hash-only re-check
  per open), our own autosaves, `touch` - all end in "signature differs, hash equal" or "signature equal". Verified: every writer case ends with exactly one reload.
* `read(2)` into malloc, not mmap: a mapped file that another process truncates kills the reader with **SIGBUS** (demonstrated in a child process, exit status 10);
  mmap saves 0.25 ms per 10 MB. Not worth a crash when a build tool does `> file`.
* Idle cost: the document is just two kqueue descriptors; `reload-triggers` asserts zero checks in 1.5 s idle and `isPolling == false` on APFS.

### 2.3 Results (real writers, clean document, release build)

Latency = writer process exited -> text replaced in the editor. "Round 2" repeats on the same document.

| writer | reloads | latency (idle >= 0.3 s since the last event) | text == file | dirty | alert |
|---|---|---|---|---|---|
| a append in place | 1 (x2 rounds) | **51-52 ms** | yes | no | none |
| b truncate + rewrite | 1 | 51 ms | yes | no | none |
| c atomic replace | 1 | 51 ms | yes | no | none |
| d1 delete, 50 ms, recreate | 1 | 50-53 ms | yes | no | none |
| d2 delete + immediate recreate | 1 | 51 ms | yes | no | none |
| e rename away, edit, rename back | 1 | 50 ms | yes | no | none |
| f same size + same mtime | 1 | 50 ms | yes | no | none |
| g 20 writes / 1 s | **5-7** | first after ~50 ms, then every 0.3 s | yes | no | none |
| h1 10 MB atomic replace, one changed line | 1 | **67-73 ms** (50 settle + ~3 read/hash + 5-16 diff/apply) | yes | no | none |
| h2 10 MB replaced by completely different text | 1 | **100-105 ms** (diff bails out after 40-46 ms, one 27.8 M-unit replacement) | yes | no | none |
| presenter only (monitor stopped) | 1 | **0.90-1.07 s** | yes | no | none |
| activation only (monitor stopped) | 1 | **2 ms after the notification** | yes | no | none |
| coordinated `NSFileCoordinator` write | 1 by us **and** NSDocument's own `revert(toContentsOf:)` (our override, no-op diff) | | yes | no | none |
| symlinked folder, written via real path and via link | picked up | | | | |

Over 3 full runs (42 single-write samples, writers a-f x 2 rounds): **median 51 ms, 88 % <= 55 ms, worst 299 ms**; the outliers (140-143 ms for e, 297-299 ms for d1, always the *first*
writer right after `open`) happen when two callbacks (the xattr events NSDocument produces at open) were already inside the last second and the burst throttle (`minInterval` = 0.3 s)
applied. `burstThreshold`/`minInterval` are the knobs. Burst g: 5, 7, 6, 5, 5, 6 reloads in six rounds.

**File Provider / OneDrive / iCloud sync clients (reasoning, not tested - forbidden to touch `~/Library/CloudStorage`):** they write into materialized files on APFS
(kqueue sees those writes) or replace files atomically (directory events), usually **under file coordination**, which makes NSDocument revert by itself after ~0.5 s
(`revert(toContentsOf:)` is overridden to run the same minimal-diff path, and our own check has usually reloaded already, so the revert is a no-op).
Placeholder (dataless) files are materialized by the *first read*: a read of a placeholder blocks until the download finished (put no read on the main thread: our
read runs on a background queue, but `read(from:)` at open is synchronous - NSDocument's own contract; `canConcurrentlyReadDocuments` is the knob). Events can be delayed or
batched; therefore the presenter echo, activation check and (for non-local mounts) the poll exist. Writes that go through a *rename into place while dataless* can
look like delete+create (handled).

---

## 3. DIRTY document: conflict policy

### 3.1 What NSDocument does (probe)

| situation | stock behaviour |
|---|---|
| autosavesInPlace ON, edit, no external change | first autosave **15.0 s** after the first edit (`autosavingDelay` default 0 = system default) |
| ON, external append, then autosave (timer) or ⌘S | `save(to:)` fails *before* writing with **NSCocoaError 67000** and a sheet: "The document “x” could not be autosaved/saved. The file has been changed by another application." buttons **Save Anyway / Revert / Save As…** (info text: the other app's version is kept as a *Version*). Save Anyway writes mine; Revert -> `revert(toContentsOf:)` loads the disk version. It never loses data silently, but it is a **modal sheet at an arbitrary moment** (an autosave) |
| OFF, ⌘S | sheet "This document’s file has been changed by another application since you opened or saved it." / "…will be lost if you save. Save anyway?" **[Don’t Save] [Save]** - raised in `save(withDelegate:)`, before `save(to:)` |
| OFF, timer autosave | writes a draft "(Autosaved)" copy elsewhere (`autosaveElsewhere`), never the real file |
| `checkAutosavingSafety` | only an advisory call after `presentedItemDidChange`; the 67000 check is inside `save(to:)` |
| file deleted (`rm`) while dirty | nothing happens; ⌘S -> alert "The location of the document cannot be determined." |
| Save As… in an autosave-in-place doc | observed: an `autosaveInPlace` save of the original is attempted first (when it is cancelled the whole Save As silently does nothing) |

### 3.2 The policy (implemented; every transition below has a self-test scenario)

State `ExternalSyncState`: `inSync`, `conflict`, `unreadable`, `deletedOnDisk`.

| event | clean | dirty |
|---|---|---|
| content changed on disk | silent reload (minimal diff, selection+scroll kept, undo cleared, `updateChangeCount(.changeCleared)`, NSDocument's `fileModificationDate` synced) | **3-way merge** `Diff3.merge(base, mine, theirs)`: success -> applied as **one undoable edit** on top of the undo history, info banner "Merged changes…" (self-hides after 8 s, `mergeBannerSeconds`), base := disk text, still dirty; autosave then writes both changes |
| ... but base unknown or hunks overlap/touch | - | **banner**: "“x” was changed on disk, and you have unsaved changes." `[Reload from Disk] [Keep My Version]`; state `conflict`; the typed text stays; **autosave is held back** (`completionHandler(CocoaError(.userCancelled))`: no alert, no write, no retry storm - asserted) |
| disk reverts to the last known content during a conflict | - | conflict clears itself |
| second disk version during a conflict | - | offered version updated (Reload loads the latest) |
| file becomes unreadable (binary, > 200 MB) | state `unreadable`, banner `[Keep My Version]`, text kept, saves held back | same |
| file deleted/moved away | 1.6 s grace (a move is reported by the presenter within ~1.1 s, then `fileURL` changes; atomic writers need a moment), then banner "deleted or moved. Your text is still open." `[Save Again…]`, document marked edited so close asks, autosave held back (**must not resurrect a deliberately deleted file**) | same, typed text kept |
| file reappears | normal comparison: silent reload if nothing was typed, else merge/conflict | |

Writes, close, and menu commands (all through our gate, which first runs the same synchronous check, so even an autosave that races ahead of every watcher is safe - scenario `save-gate`):

* **Autosave** while `conflict`/`unreadable`/`deleted`: silently cancelled. No race window: the gate calls `checkForExternalChange` synchronously first; a non-overlapping change is merged and the autosave proceeds.
* **⌘S** while `conflict`: *our* sheet **[Overwrite File] [Reload from Disk] [Cancel]** (Cancel leaves everything untouched; Reload is undoable; Overwrite acknowledges the disk version and writes). Pre-empts NSDocument's own sheet in both autosave modes by overriding `save(withDelegate:didSave:contextInfo:)` **and** `save(to:ofType:for:completionHandler:)`.
* **Close** with an unresolved state: sheet **[Overwrite File | Save Again] [Discard My Changes] [Cancel]**. Without it the held-back autosave makes the close fail *silently* (window cannot be closed, nothing says why) - found and fixed.
* **Save As…** in those states: our own panel + `save(to:for:.saveAsOperation)`, which re-homes the document (the other tool's file stays untouched).
* **⌘S on a deleted file**: Save panel (starts in the old folder).
* **File > Reload from Disk (⌥⌘R)** (`scribeReloadFromDisk:`): manual counterpart, confirmation if there are edits, undoable. The stock "Revert To > Last Opened Version" (Versions) does nothing useful in a document that was never saved (recorded).
* NSDocument-initiated `revert(toContentsOf:ofType:)` (Revert, coordinated writers) is overridden and **does not call super** (super would replace the whole text and lose selection/scroll).
* `fileModificationDate` is set from the file system after every silent reload/merge/touch so NSDocument's own 67000/“Save anyway?” check never fires spuriously
  (asserted: after reload, after `touch`, after merge, followed by typing + autosave: no alert).
* Draft autosaves (`autosaveElsewhere`) and copies (`saveTo`) never update `lastDisk` (found in review: they would have been mistaken for an external change afterwards).

`baseSnapshot` costs nothing until used: `NSString.copy()` of the live string is lazy (0.0 ms), and the first edit of a 10 MB document is not slower with it (426 ms either way, see 6.).

---

## 4. Reload UX

* **Selection**: each range is mapped through the edit list (`TextDiff.map`): unchanged text -> same characters; inside a replaced region -> same relative offset clamped to the replacement; at an insertion point -> stays in front.
  Verified: change above (+50 lines) -> selection moved by exactly the inserted length and still covers `'3003'`; change below -> untouched; change over the caret -> clamped into the rewritten line.
* **Scroll**: `ViewportAnchor` remembers the first visible character and how far its line is scrolled out; after the edits the same line is placed at the same offset
  (`scrollAdjusted`). Skipped when all edits are after the anchor. Above-viewport insert of 50 lines: offset 42023 -> 42163 pt, same top line text. 10 MB document with the viewport in the middle and
  51 lines inserted above: apply + selection + anchor restore **7.3 ms**. TextKit 1 uses `glyphIndex(for:)/lineFragmentRect`; TextKit 2 `textLayoutFragment(for:)` - **measured:** after an
  edit TextKit 2 only repositions fragments below the edit when the *whole* document range is laid out (a partial `ensureLayout(start...anchor)` leaves stale y), so the TK2
  path lays out everything and is limited to `tk2FullLayoutLimit` = 1 M units. DESIGN.md's TextKit 1 + non-contiguous layout choice is the right one for 10 MB.
* **No flicker**: no `string =`; only the changed hunks are replaced inside one `beginEditing/endEditing`; attribute-only restyle is the highlighter's business (`didProcessEditing`).
* **Undo** - decision: clean reload **clears** the undo manager (`removeAllActions`; entries hold ranges/strings of the old text and would corrupt the new one - verified: Undo after reload is a no-op,
  typing then Undo returns exactly to the reloaded text); dirty merge/"Reload from Disk" register **one undoable edit** via `shouldChangeText(inRanges:replacementStrings:)` wrapped in an explicit undo group.
  Why the explicit group: an undo group opened outside an event (`groupsByEvent`) stays open until the *next* event, so the user's next keystroke would be merged into the same Undo step.
* **Dirty flag**: silent reload runs with undo registration disabled and then `updateChangeCount(.changeCleared)`; the document never flashes dirty.
* **Cost** of `applyExternalText` (diff + replace + selection + scroll), release:

| text | one line changed in the middle | at the top | 3 distant lines | append | everything different |
|---|---|---|---|---|---|
| 1 MB | 0.76 ms (diff 0.6) | 1.3 ms | 1.4 ms (3 edits) | 0.4 ms | - |
| 10 MB | 5.3 ms (diff 5.1) | 5.9 ms | 13.5 ms (3 edits) | 3.1 ms | 35-49 ms (diff 33-46) |

  The diff floor is the prefix scan: 2.0 GB/s on an 8-bit-backed string (10 MB: 4.8 ms), 16 GB/s on a UTF-16-backed one. The line diff only runs if the changed middle is
  >= 4096 units, bails out after edit distance 1500 or 128 hunks, never splits a surrogate pair, and compares lines by hash *and* content (a hash collision cannot corrupt text). 3000 fuzzed edit lists + 500 fuzzed merges pass.

---

## 5. Reading and writing

**Encoding detection** (`TextCodec`): BOM first (UTF-8 EF BB BF, UTF-32 LE/BE, UTF-16 LE/BE); BOM-less UTF-16 by NUL parity heuristic; **NUL byte in the first 64 KB otherwise = binary -> refuse**
(`ScribeError.binaryFile`); UTF-8 strict via `NSString(bytes:length:encoding:)` (invalid -> nil, verified: overlong, surrogates); else **Windows-1252** (CF rejects its 5 undefined bytes), else **Mac OS Roman** (accepts all).
Detected encoding, BOM and **line-ending style** are remembered and written back: pure CRLF (or CR) files are normalised to LF in memory (editor and lexer only ever see `\n`) and expanded on save; **mixed endings are kept literally**
(`LineEnding.mixed`). Stray CRs from pasted CRLF text in a normalised document are folded, not doubled. A character that the legacy encoding cannot hold (emoji typed into a 1252 file): the document switches to UTF-8 instead
of failing or losing text. Verified through the real document: 7 format cases (CRLF, CRLF + inserted newline, BOM, UTF-16 LE+BOM, 1252, mixed, no trailing newline) - after edit + autosave **the bytes equal the original with only the edit applied**;
64 codec checks incl. byte-identical round trips for every format; an external tool switching the file to UTF-16 is followed (format updated).

**Refusals**: binary -> error "This file does not look like a text file." (NSDocument wraps errors as "could not be opened" and shows the *failure reason* as second line, so `ScribeError.failureReason` is set); **> 200 MB refused in 1 ms**
(`fstat` before reading, sparse test file); empty file and BOM-only file open; non-UTF-8 opens as 1252; missing file -> error, no crash. `isEntireFileLoaded = true` (we load everything or refuse; return false only for a future partial-load mode - then NSDocument refuses in-place saves).

**Timings** (release, page-cache-warm file; median):

| | 1 MB ASCII | 10 MB ASCII | 1 MB mixed* | 10 MB mixed* | 10 MB ASCII CRLF |
|---|---|---|---|---|---|
| `read(2)` whole file | 0.04 ms | 0.36 ms | 0.03 | 0.31 | 0.32 |
| `Data(contentsOf:, .alwaysMapped)` (touch all pages) | 0.02 | 0.02 | 0.01 | 0.02 | 0.02 |
| `FastHash64` | 0.04 (25 GB/s) | 0.38 | 0.04 | 0.35 | 0.36 |
| decode UTF-8 -> NSString (+ line-ending scan) | 0.04 | 0.50 | 1.51 | **15.3** | 7.2 |
| `NSTextStorage` holds the string | 0.02 | 0.22 | 0.03 | 0.35 | 0.22 |
| **whole `read(from:)`** (read+decode+hash) | **0.11** | **1.08** | 1.55 | **16.2** | 7.9 |
| encode back (live `NSTextStorage.string`) | 0.84 | 7.6 | 0.58 | 5.9 | 10.2 |

\* mixed = German/CJK/emoji markdown. The winner for decoding is `NSString(bytes:length:encoding:)` (Swift `String(decoding:)` validates in 3 ms but bridging to a UTF-16 NSString afterwards costs 27 ms).
**Encoding found a trap:** `NSString.range(of: "\r")` on a 10 MB text-storage string costs 37-49 ms and `data(using:)` 14-18 ms; chunked `getBytes` (1 M units) is 2.4x faster and the CR check now runs on the *bytes* (memchr): 10 MB save went from 54-61 ms to **6-8 ms**.

**End to end through `NSDocumentController.openDocument`** (document + window controller + TextKit 1 stack + text loaded + first screen laid out, unstyled): 1 MB 12-16 ms, 10 MB ASCII **13 ms**, 10 MB mixed **29 ms**
(the very first window of a process costs ~40 ms of AppKit warm-up). `canConcurrentlyReadDocuments`: with it on, the main-thread stall during a 10 MB mixed open drops **19.5 ms -> 1.7 ms**, total wall time unchanged; for ASCII there is nothing to gain
(2-4 ms). Left **off** (simplicity; the stall is about one frame); `MarkdownDocument.concurrentReading` flips it (the read path touches no AppKit state).
Typing latency in the bare text view (no styling): 0.8-0.9 ms per keystroke at 200 KB and 10 MB. **Caveat for the editor lead:** the *first* `insertText` in the middle of a never-visited 10 MB TextKit 1 document costs ~430 ms
(it lays out everything above the caret to scroll it into view; independent of our hooks; the same insert near the top is 0.7 ms) - jumping to a far offset is expensive, edits near what was laid out are not.

**New untitled document**: type `net.daringfireball.markdown`, `displayName` "Untitled" ("Untitled 2" for the next), `fileNameExtension` "md", first Save panel proposes `Untitled.md` (see 1.3); saving writes UTF-8/LF, arms the watcher, a later external change is reloaded.
`NSDocumentController.autosavingDelay = 3` (set in `AppDelegate`).

---

## 6. App lifecycle and menus

| topic | result / decision |
|---|---|
| launch without documents | **one untitled document, no Open panel**: `applicationShouldOpenUntitledFile -> true` (verified by black-box launch). With a file argument (Finder/`open`) no untitled document is created. |
| relaunch | NSDocument restores the previous windows (verified); `applicationSupportsSecureRestorableState -> true`; `NSQuitAlwaysKeepsWindows` registered true. |
| Dock click with no windows | `applicationShouldHandleReopen(hasVisibleWindows:) -> !flag` -> new untitled document |
| last window closed | app keeps running (`applicationShouldTerminateAfterLastWindowClosed -> false`); `NSSupportsAutomaticTermination` lets the system reclaim it |
| file dropped on Dock icon / Finder open | `odoc` Apple event -> NSDocumentController -> document class. **Do not implement `application(_:openFile:)`/`open:`** (bypasses document class and recents). |
| Open Recent | `NSDocumentController` keeps the list (newest first, max 10, Clear Menu empties it; a black-box launch with a file reported it in `recentDocumentURLs`); the submenu *items* are filled by AppKit when the menu is shown (headless it only contains "Clear Menu"). **Install the menu in `applicationWillFinishLaunching` WITHOUT your own "Open Recent" item - AppKit adds one during launch; with yours there are two** (measured; a menu installed after launch needs its own). |
| quit with dirty untitled docs | autosave in place keeps drafts (`Unsaved Scribe Document.md`); the headless `reviewUnsavedDocuments` returned `didReviewAll=false` without any alert - **unverified in a visible session, check manually** |
| tabbing | `tabbingMode = .automatic` (follow the system "Prefer tabs" setting) + shared `tabbingIdentifier`; `allowsAutomaticWindowTabbing = true`. ⌘N is a new window by default, a tab if the user prefers tabs; `.preferred` would force tabs on everyone. |
| full screen | `collectionBehavior.insert(.fullScreenPrimary)`; AppKit rewrites a `toggleFullScreen:` item into the visible "Enter Full Screen" (fn-F) and keeps ours ⌃⌘F hidden - **if you add none, AppKit adds none** |

`MainMenu.swift` builds the whole menu in code (no nib), every item has `target = nil`; routing and validation checked for **all items** against the real responder chain
(`NSTextView > NSClipView > NSScrollView > NSStackView > EditorViewController > NSWindow > EditorWindowController > [MarkdownDocument] > NSApplication > delegate > NSDocumentController`):
Save/Save As/Duplicate/Rename/Move/Print -> `MarkdownDocument`; New/Open/Clear Menu -> `NSDocumentController`; Cut/Copy/Paste/Find/Spelling/Substitutions/Transformations -> `NSTextView` (Paste/Paste and Match Style disabled in the headless run (pasteboard dependent),
Redo disabled, Undo title "Undo Typing"); Bigger/Smaller/Actual Size/Wrap Lines/Show Invisibles -> `EditorViewController` (custom selectors, checkmarks follow state); tab items -> `NSWindow`. Find uses `performTextFinderAction:` with
the `NSTextFinder.Action` raw values as tags. Substitutions and spell checking are **off** (asserted on the text view and in the menu state). Menu additions by AppKit (not ours): "Close All", "Revert To" (Versions) + "Share"
in File, AutoFill / Start Dictation / Emoji & Symbols in Edit. `File > Reload from Disk` is ours. Not done: Export as PDF (could use `NSPrintOperation.pdfOperation`), Help is only the standard `showHelp:` item.

---

## 7. Self-test pattern (`Scribe --selftest <name|a,b|all|list>`)

* From the **assembled bundle only** (document types come from Info.plist): `build/Scribe.app/Contents/MacOS/Scribe --selftest all [--workdir=DIR] [--timeout=SEC] [--trace]`. Exit 0/1/2, readable `ok/FAIL/note` lines, a final `SELFTEST RESULT`.
* `NSApp.setActivationPolicy(.prohibited)`; documents are opened with `display: false` and only `makeWindowControllers()` is called - **never ordered front**: a window that is ordered front *is* listed on-screen by `CGWindowListCopyWindowInfo`
  even for a `.prohibited` app (verified), a never-ordered one is not.
* `SelfTestUITrap`: swizzles `NSAlert` (`runModal`, sheet, legacy sheet) and `NSSavePanel` (`runModal`, sheet, `begin`, `url`) so flows that would show UI are recorded and answered by a chooser closure.
  Nothing can block on an invisible modal (**a modal alert in a hidden/prohibited app hangs forever and nobody sees it** - this is what the unprotected launch with a bad type did). Panel URLs outside the scenario work dir are refused (`allowedRoot`):
  confirming a panel that NSDocument itself owns turned out to be unreliable (once in four runs it used `~/Documents/Untitled` instead of the faked URL: one 2-byte stray file was created and moved out; tests now cancel NSDocument's panels and drive `save(to:)`).
* Real external writers are `/bin/sh` child processes (`t.sh`), documents/files are real, latency is measured from the writer's exit.
* Headless specifics: no events, so `groupsByEvent` undo groups never close (tests set `groupsByEvent = false` and group explicitly); `NSTextView` registers typing undo lazily (`breakUndoCoalescing()` flushes it).
* **Argument parsing trap**: AppKit treats a loose non-dash argument (`--selftest all`) as a *file to open* and shows an error alert; `main.swift` registers `NSTreatUnknownArgumentsAsOpen = NO` when `--selftest` is present.
* Scenarios: `codec`, `diff` (fuzz), `reload-clean` (writer matrix, 2 rounds, 10 MB), `reload-ux`, `reload-tk2`, `reload-triggers`, `dirty-merge`, `dirty-conflict`, `save-gate`, `autosave-off`, `deleted-moved`, `new-untitled`, `formats`, `refusals`, `lifecycle`, `menu`, `bench`, `open-perf`.
  The scenarios use the reference `EditorViewController` through a small surface (`textView`, `scrollView`, banner introspection `bannerVisible/bannerText/bannerButtonTitles/pressBannerButton`, `fontSize`, the `scribe*` actions); keep these names (or adapt) when the real editor replaces it.

---

## 8. Recommended design and code map (copy `docs/spike-document-code/*.swift` into `Sources/Scribe/`, replacing the placeholder `main.swift`)

| file | role |
|---|---|
| `DocumentText.swift` | `TextCodec` decode/encode, `TextFormat` (encoding, BOM, line ending), `ScribeError` |
| `DiskFile.swift` | `FileSignature` (dev, ino, size, mtime, ctime), `FastHash`, `DiskReader.readFile` (read(2), retry while changing), `DiskState` |
| `TextDiff.swift` | `TextDiff.edits/map`, `Diff3.merge` (Foundation only) |
| `ExternalChangeMonitor.swift` | kqueue file+directory watcher with coalescing, throttle, re-binding, poll for non-local FS (Foundation only) |
| `EditorHost.swift` | the coupling: `protocol EditorHost`, `TextViewEditorHost` (default impl of load/apply/currentText), `ViewportAnchor`, `TextDiff.apply` |
| `MarkdownDocument.swift` | NSDocument subclass: read/data, save gate, presenter hooks, close/Save As/Save sheets |
| `MarkdownDocument+ExternalChanges.swift` | the policy: check, silent reload, merge, conflict, deleted, `revert(toContentsOf:)` override |
| `EditorWindowController.swift` | **reference** window controller/view controller/banner (TextKit 1) - replace with Scribe's real editor |
| `AppDelegate.swift`, `MainMenu.swift`, `main.swift` | lifecycle, menu, entry point (`--selftest`) |
| `SelfTest*.swift` | runner, UI trap, 18 scenarios |
| `experiments/` | the stock-NSDocument probe (as `.txt`, not compiled - copy only `*.swift`), to re-run the section 2.1/3.1 observations |

**Contract with the editor** (`protocol EditorHost`): `currentText: NSString`, `isComposingText`, `loadInitialText(_:)`, `applyExternalText(_:mode:)` (`.silent` = clear undo / `.undoable`), `showBanner(_:)`, `hideBanner()`;
plus one call from the editor to the document **before every user edit**: `document.editorWillChangeText()` (from `textView(_:shouldChangeTextIn:replacementString:)`) - captures the merge base lazily. A TextKit 1 NSTextView editor conforms to
`TextViewEditorHost` and only supplies `textView` and the banner. The document's undo manager must be the text view's (`undoManager(for:)` or window delegate).

Fit with the TextKit spike (`docs/spike-textkit-code`): its `ScribeEditorFactory` (TextKit 1, non-contiguous layout) is the text view this layer was written for (the reference `EditorViewController` uses the same stack);
conform the real view controller to `TextViewEditorHost`. The silent/undoable apply calls `replaceCharacters` on the text storage inside one `beginEditing/endEditing`, i.e. the styler sees ordinary
`didProcessEditing` edits (no `string =`), and `isComposingText` (`hasMarkedText()`) is the IME guard that postpones a reload by 0.3 s. No top-level type name of the two spikes collides.

Integration checklist: (1) copy files, (2) `Resources/Info.plist` (change both bundle-id-derived identifiers), (3) `Scripts/build-app.sh`, (4) `Scribe --selftest all` from the bundle, (5) call `editorWillChangeText()`, (6) install the menu in
`applicationWillFinishLaunching` without Open Recent, (7) decide `MarkdownDocument.autosavesInPlaceEnabled` (default true) and `NSDocumentController.autosavingDelay` (3 s), (8) keep `canConcurrentlyReadDocuments` off unless 10 MB+ non-ASCII files matter.

---

## 9. Pitfalls and surprises (collected)

1. `NSDocument` does **not** auto-reload on uncoordinated writes; its only signal is a ~1 s late background-queue callback. `rm` produces **no** callback.
2. After an atomic replace a kqueue/DispatchSource on the file is dead (unlinked inode): watch the **directory** too and re-bind.
3. `ctime` in the signature is the only stat-level defence against `touch -r`; open itself bumps ctime (xattr) -> one hash-only re-check per open.
4. NSDocument's stock conflict UI is a modal sheet at autosave time (67000) or at ⌘S; both must be pre-empted *before* `save(to:)`/`save(withDelegate:)`, and `fileModificationDate` must be kept in sync after every silent reload.
5. Holding back autosave makes **close fail silently** and **Save As… fail silently** unless those flows are taken over.
6. `save(_:)` on a deleted file -> "The location of the document cannot be determined".
7. Imported UTIs do not extend a system-declared type: `.mkd` needs an exported type; a launch with an unopenable type blocks on an **invisible** alert when the app is hidden.
8. AppKit post-processes the menu bar: duplicates "Open Recent" if you add one before launch finished, rewrites Full Screen, adds Close All / Revert To / Share / AutoFill / Dictation / Emoji.
9. Launch Services registers every launched bundle (even when exec'd directly); unregister test bundles, test with Alternate rank.
10. AppKit parses loose CLI arguments as files to open; set `NSTreatUnknownArgumentsAsOpen = NO` for `--selftest`.
11. `.prohibited` windows ordered front are on-screen; alerts in a prohibited/hidden app block invisibly - trap them.
12. `mmap` + truncate by another process = SIGBUS. `NSString.range(of:)` / `data(using:)` on a 10 MB `NSTextStorage` string are 37-49 / 14-18 ms; chunked `getBytes` and a byte-level `memchr` are 5-10x faster.
13. First `insertText` into an un-laid-out middle of a 10 MB TextKit 1 document: ~430 ms (layout above the caret); TextKit 2 partial `ensureLayout` does not reposition fragments after an edit.
14. Undo groups opened outside an event stay open until the next event: wrap programmatic undoable edits in an explicit group; `NSTextView` registers typing undo lazily.
15. NSDocument error wrapping: put the human message in `failureReason`, not only `errorDescription`.
16. Autosave in place: stock delay 15 s; each autosave is a *safe save* (temp file `name.sb-xxxxxxxx-xxxxxx` in the same folder, then rename: other tools' watchers see create+rename, our monitor sees a new inode and re-binds); `Versions` store grows with explicit saves.
17. `fileURL` forms change (`/private/tmp/...` -> `/tmp/...`) after NSDocument handles a move: compare standardized paths.

## 10. Open risks / not verified

* **Real GUI sessions**: sheets on visible windows, banner appearance, Open Recent contents in the real menu, quit with dirty untitled documents, window restoration of *dirty* docs, drag to Dock icon (same Apple event, black-box tested only with `open -a`), Finder double-click default-handler behaviour (rank Default for Markdown is the lead's decision; I never changed a default handler).
* Stock NSDocument behaviour on real app activation (could not activate without stealing focus).
* File Provider / OneDrive / network volumes (reasoned only; the 2 s poll for non-local mounts is untested).
* TextKit 2 was exercised only in a never-shown window; the real editor decides TK1/TK2.
* Selection/scroll preservation is tested on the reference text view; a real highlighter (restyling after `replaceCharacters`) must not move the selection.
* `canConcurrentlyReadDocuments = true` was only measured, not hardened.
* Ad-hoc signature = TCC prompts return after each rebuild; opening files under `~/Documents` from a restored window may prompt once per signature.
* Merge conflicts are conservative (touching hunks conflict); a smarter merge (word level) is possible later. Diff budgets (1500 edit distance, 128 hunks) fall back to one big replacement, never to wrong text.

## 11. State this spike left on the machine

* Launch Services: every scratch bundle that was run was `lsregister -u`'d at the end (0 entries under the scratch dir, 0 bundles with a `local.scribe.*` id, `.mkd` dynamic again);
  `NSWorkspace` default handlers for Markdown and plain text are identical to the snapshot taken before the first experiment. Nothing was ever set as a default.
* One stray 2-byte file (`~/Documents/Untitled`, created by an early version of the self-test whose faked Save-panel URL was ignored once) and one empty file in `Scripts/` were **moved** (not deleted) to the
  scratch dir; the `UITrap.allowedRoot` guard now makes that impossible.
* UserDefaults domains created by test runs: `local.scribe.Scribe` (`ScribeFontSize = 14`, **`NSDocumentSaveAsShouldRevert = 0`**, written by AppKit during a Save As test),
  `local.scribe.spiketest`, `local.scribe.spikeprobe`. They are harmless for the placeholder id, but if the real app keeps `local.scribe.Scribe` run `defaults delete local.scribe.Scribe` once so Save As behaves per default.
* The self-tests create untitled documents and autosave drafts through NSDocument; each scenario closes its documents (`updateChangeCount(.changeCleared)` + `close()`), so no draft should remain in `~/Library/Autosave Information`
  (that folder is not readable from my sandbox - not verified).
* No network access, nothing under `~/Library/CloudStorage`, no other project files touched. Build products live in the scratch dir.
