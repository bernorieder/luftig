// MarkdownDocument+ExternalChanges.swift
//
// External-change policy of luftig (see docs/spike-document.md for the measurements behind it):
//
//   triggers  (all end in the same idempotent `checkForExternalChange`)
//     1. ExternalChangeMonitor  kqueue file + directory events           ~50-100 ms after the write
//     2. NSFilePresenter        presentedItemDidChange/Move/Gain/Deletion ~0.5-1.1 s (daemon latency), main-thread hop
//     3. app activation / window becoming key                             catches anything the above missed
//     4. save gate              synchronous check right before every save/autosave
//
//   decision  (on the main thread, after a background read+hash+decode)
//     signature unchanged                     -> nothing (one stat(2))
//     signature changed, hash unchanged       -> touch/chmod/identical rewrite: refresh signature, NO reload
//     content changed, document clean         -> silent reload: minimal diff, selection+scroll kept, undo cleared
//                                                ("clean" = NSDocument's change count says so AND the editor holds the text of the disk version
//                                                we last synced with: the change count can lag behind the text, see editorHasUnsavedText)
//     content changed, document dirty         -> 3-way line merge (base = last synced text); success: applied as ONE undoable
//                                                edit; overlap: keep the typed text, show a non-modal banner
//                                                [Reload from Disk] [Keep My Version]; autosave is held back meanwhile
//     (Settings > General > When the file changes on disk: "Ask first" shows that banner for every change, clean or dirty, and
//      merges nothing; "Never reload" shows nothing and only asks when the file is about to be overwritten - see externalChangeArrived)
//     file gone                               -> grace period (move/atomic replace), then banner [Save Again]; autosave held back
//
// Invariant: luftig never writes over a disk version it has not either loaded, merged, or been told to overwrite.

import AppKit

enum ExternalSyncState: Equatable {
    case inSync
    case conflict          // disk and editor both changed, merge impossible: waiting for the user
    case unreadable        // disk changed to something we cannot show (binary, too large): waiting for the user
    case deletedOnDisk     // file disappeared
}

struct ExternalConflict {
    var diskText: NSString?
    var diskFormat: TextFormat?
    var disk: DiskState
    var reason: String?
}

struct ExternalChangeStats {
    var checks = 0                 // checkForExternalChange calls that did real work (stat'ed)
    var statUnchanged = 0          // ... of which the signature was unchanged
    var hashUnchanged = 0          // ... signature changed but content identical (no reload)
    var silentReloads = 0
    var merges = 0
    var conflicts = 0
    var deletions = 0
    var lastApply: ExternalApplyReport?
    var lastReloadTrigger = ""
}

enum DiskLoad {
    case unchanged(DiskState)
    case changed(DecodedText, DiskState)

    /// Read + hash; decode only if the hash differs from `knownHash`. Safe to call on any thread.
    static func load(path: String, knownHash: UInt64?) throws -> DiskLoad {
        let (data, sig) = try DiskReader.readFile(path: path)
        let st = DiskReader.state(of: data, signature: sig)
        if let knownHash, st.hash == knownHash { return .unchanged(st) }
        let decoded = try data.withUnsafeBytes { try TextCodec.decode(bytes: $0) }
        return .changed(decoded, st)
    }
}

extension MarkdownDocument {

    // MARK: arming

    func armMonitorIfNeeded() {
        guard !isClosed, let url = fileURL, lastDisk != nil else { return }
        if let monitor {
            monitor.retarget(path: url.path)
        } else {
            let m = ExternalChangeMonitor(path: url.path) { [weak self] in self?.checkForExternalChange("fswatch") }
            monitor = m
            m.start()
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(activationSignal(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(activationSignal(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        }
        // a check right after arming closes the gap between the read and the first event
        DispatchQueue.main.async { [weak self] in self?.checkForExternalChange("armed") }
    }

    @objc func activationSignal(_ note: Notification) {
        if note.name == NSWindow.didBecomeKeyNotification, (note.object as? NSWindow) !== sheetWindow { return }
        checkForExternalChange("activation")
    }

    func fileURLDidChange() {
        host?.documentURLDidChange(fileURL)
        if fileURL == nil {
            monitor?.stop(); monitor = nil
            NotificationCenter.default.removeObserver(self)      // armMonitorIfNeeded installs them again with a new monitor
        } else {
            armMonitorIfNeeded()
        }
    }

    // MARK: the check

    /// Idempotent and cheap when nothing changed (one stat). Main thread.
    func checkForExternalChange(_ reason: String) {
        guard !isClosed, let url = fileURL, let last = lastDisk else { return }
        if isSaving || isApplyingExternal || checkInFlight { recheckRequested = true; return }
        stats.checks += 1
        guard let sig = FileSignature.of(path: url.path) else { fileMissing(); return }
        if syncState == .deletedOnDisk { fileReappeared() }
        if sig == last.signature { stats.statUnchanged += 1; return }
        if sig == lastUnreadableSignature { return }
        checkInFlight = true
        let known = last.hash
        let gen = generation
        let path = url.path
        loadQueue.async { [weak self] in
            let result = Result { try DiskLoad.load(path: path, knownHash: known) }
            DispatchQueue.main.async { self?.finishCheck(result, generation: gen, reason: reason, signature: sig) }
        }
    }

    private func finishCheck(_ result: Result<DiskLoad, Error>, generation gen: Int, reason: String, signature: FileSignature) {
        checkInFlight = false
        defer { if recheckRequested && !isClosed { recheckRequested = false; DispatchQueue.main.async { [weak self] in self?.checkForExternalChange("recheck") } } }
        guard !isClosed, gen == generation else { return }
        if isSaving || isApplyingExternal { recheckRequested = true; return }
        switch result {
        case .failure(let error):
            if (error as? LuftigError).map({ if case .ioError(_, let e) = $0 { return e == ENOENT }; return false }) == true { fileMissing(); return }
            lastUnreadableSignature = signature
            enterUnreadable(error, signature: signature)
        case .success(.unchanged(let st)):
            stats.hashUnchanged += 1
            lastDisk = st
            syncModificationDate(st.signature)
            lastUnreadableSignature = nil
            // content is what we last synced with: whatever conflict/unreadable state we were in is over (disk reverted)
            if syncState == .unreadable || syncState == .conflict { clearConflictUI() }
            trace("check(\(reason)): signature changed, content identical -> no reload")
        case .success(.changed(let decoded, let st)):
            lastUnreadableSignature = nil
            if host?.isComposingText == true {      // IME composition in progress: try again shortly
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.checkForExternalChange("composing") }
                return
            }
            // A keystroke that has been applied but whose undo group is still open does not count as an edit yet (NSDocument counts the change
            // when the group closes, at the end of the event cycle): `hasRealEdits` is false, and a silent reload would diff the typed character
            // away and `removeAllActions()` the open group. Wait for the group to close; the next pass sees a dirty document and merges.
            if (undoManager?.groupingLevel ?? 0) > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.checkForExternalChange("open-undo-group") }
                return
            }
            if syncState == .conflict, conflict?.disk.hash == st.hash { return }      // same disk version we already told the user about
            stats.lastReloadTrigger = reason
            externalChangeArrived(decoded, st)
        }
    }

    /// The file holds other text than the editor was synced with: Settings > General > When the file changes on disk decides.
    ///   automatic  a clean document reloads silently, a dirty one merges (or asks when the edits overlap)
    ///   ask        the banner asks, clean or dirty: Reload from Disk / Keep My Version (nothing is applied by itself)
    ///   never      nothing is shown; the state is remembered so that saving over the other version asks first (the invariant above holds)
    private func externalChangeArrived(_ decoded: DecodedText, _ disk: DiskState) {
        switch EditorPreferences.reloadBehavior {
        case .automatic:
            if !hasRealEdits && !editorHasUnsavedText() { silentReload(decoded, disk) } else { resolveDirtyChange(decoded, disk) }
        case .ask:
            enterConflict(decoded, disk, banner: true)
            trace("external change: asking (Settings)")
        case .never:
            enterConflict(decoded, disk, banner: false)
            trace("external change: not reloaded (Settings)")
        }
    }

    // MARK: applying

    /// `true` when there is user-typed work that is not on disk.
    var hasRealEdits: Bool { isDocumentEdited && !(deletedMarkedDirty && undoManager?.canUndo != true) }

    /// The editor holds other text than the disk version we last synced with, whatever NSDocument's change count says. The change count can lag
    /// behind the text: it moves at the end of an event cycle, and typing that NSTextView coalesced into an undo action from before the last save
    /// registers nothing (luftig 1.0.5 lost letters that way: a File Provider's coordinated write made NSDocument revert a "clean" document). Text
    /// that is not on disk is never replaced silently: the caller merges or asks instead, and the document is marked edited so that the autosave
    /// writes it. One encode of the text (10 MB: ~8 ms), only when the disk changed or NSDocument wants to revert.
    func editorHasUnsavedText() -> Bool {
        guard let host, let last = lastDisk else { return false }
        guard let data = try? TextCodec.encode(host.currentText, format: textFormat) else { return true }
        let unsaved = data.count != last.byteCount || data.withUnsafeBytes { FastHash.hash64($0) } != last.hash
        if unsaved && !isDocumentEdited {
            trace("the editor holds text that is not on disk, but the document counted as saved: marked edited")
            updateChangeCount(.changeDone)
        }
        return unsaved
    }

    private func silentReload(_ decoded: DecodedText, _ disk: DiskState) {
        applyExternal(decoded, disk, mode: .silent)
        stats.silentReloads += 1
        updateChangeCount(.changeCleared)
        deletedMarkedDirty = false
        clearConflictUI()
        trace("silent reload (\(stats.lastReloadTrigger)): \(decoded.text.length) units, edits=\(stats.lastApply?.edits ?? 0)")
    }

    /// Core apply: used by silent reload, merge, "Reload from Disk", and NSDocument-initiated reverts.
    func applyExternal(_ decoded: DecodedText, _ disk: DiskState, mode: ExternalApplyMode) {
        isApplyingExternal = true
        defer { isApplyingExternal = false }
        textFormat = decoded.format
        if let host {
            stats.lastApply = host.applyExternalText(decoded.text, mode: mode)
            trace("disk text applied (\(mode == .silent ? "silent" : "undoable")): \(stats.lastApply?.edits ?? 0) edits, \(stats.lastApply?.changedUnits ?? 0) units changed")
        } else {
            pendingText = decoded.text
        }
        lastDisk = disk
        generation &+= 1
        baseSnapshot = nil; baseFormat = nil
        syncModificationDate(disk.signature)
    }

    /// Keeps NSDocument's own idea of "the file's modification date" in step with what we loaded, so that its built-in
    /// "file has been changed by another application" save check (error 67000, modal sheet) never fires spuriously.
    func syncModificationDate(_ sig: FileSignature) {
        let fromFS = (try? fileURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        fileModificationDate = fromFS ?? sig.modificationDate
    }

    // MARK: dirty document: merge or conflict

    /// The merge base must be EXACTLY the text of the disk version we last synced with. It is captured lazily, at the first edit, by
    /// `editorWillChangeText`; if any edit path ever bypassed that hook the base would contain text that is not on disk, and the 3-way merge
    /// would read "not on disk" as "deleted by the other tool" and silently drop the user's text. So verify: the base re-encodes to the
    /// bytes (hash, size) of `lastDisk`. A base that does not -> no merge, the conflict banner asks instead. Costs one encode, only when an
    /// external change meets unsaved edits (10 MB: ~8 ms).
    func baseMatchesLastDisk() -> Bool {
        guard let base = baseSnapshot, let fmt = baseFormat, let last = lastDisk,
              let data = try? TextCodec.encode(base, format: fmt), data.count == last.byteCount else { return false }
        return data.withUnsafeBytes { FastHash.hash64($0) } == last.hash
    }

    private func resolveDirtyChange(_ decoded: DecodedText, _ disk: DiskState) {
        if let base = baseSnapshot, baseMatchesLastDisk(), let host,
           let merged = Diff3.merge(base: base, mine: host.currentText, theirs: decoded.text) {
            var d = decoded
            d.text = merged
            applyExternal(d, disk, mode: .undoable)      // textFormat <- disk format; text <- merged
            baseSnapshot = decoded.text                   // the new base is what is on disk now
            baseFormat = decoded.format
            stats.merges += 1
            clearConflictUI(keepState: false)
            host.showBanner(EditorBanner(message: "Merged changes from “\(displayName ?? "file")” on disk with your edits.",
                                         style: .info, buttons: [("OK", { [weak self] in self?.host?.hideBanner() })]))
            bannerSerial += 1
            let serial = bannerSerial
            DispatchQueue.main.asyncAfter(deadline: .now() + MarkdownDocument.mergeBannerSeconds) { [weak self] in            // info only: fade away by itself
                if let self, self.bannerSerial == serial, self.syncState == .inSync { self.host?.hideBanner() }
            }
            trace("merged external change into dirty document (units \(merged.length))")
            return
        }
        enterConflict(decoded, disk, banner: true)
        trace("conflict: dirty document and the file both changed")
    }

    /// The other version is remembered and waits for the user: the banner (if asked for), autosave held back, ⌘S and closing ask with a sheet.
    private func enterConflict(_ decoded: DecodedText, _ disk: DiskState, banner: Bool) {
        stats.conflicts += 1
        conflict = ExternalConflict(diskText: decoded.text, diskFormat: decoded.format, disk: disk, reason: nil)
        syncState = .conflict
        if banner { showConflictBanner() } else { bannerSerial += 1; host?.hideBanner() }
    }

    private func enterUnreadable(_ error: Error, signature: FileSignature) {
        let desc = (error as NSError).localizedDescription
        // we cannot show it, but must not overwrite it silently either: acknowledge this exact signature on "Keep My Version"
        conflict = ExternalConflict(diskText: nil, diskFormat: nil, disk: DiskState(signature: signature, hash: 0, byteCount: 0), reason: desc)
        syncState = .unreadable
        stats.conflicts += 1
        host?.showBanner(EditorBanner(
            message: "“\(displayName ?? "file")” changed on disk, but luftig cannot show it: \(desc) Your text is unchanged.",
            style: .warning,
            buttons: [("Keep My Version", { [weak self] in self?.keepMyVersion() })]))
        trace("unreadable external change: \(desc)")
    }

    private func showConflictBanner() {
        host?.showBanner(EditorBanner(
            message: hasRealEdits ? "“\(displayName ?? "file")” was changed on disk, and you have unsaved changes." : "“\(displayName ?? "file")” was changed on disk.",
            style: .warning,
            buttons: [("Reload from Disk", { [weak self] in self?.reloadFromDisk() }),
                      ("Keep My Version", { [weak self] in self?.keepMyVersion() })]))
    }

    func clearConflictUI(keepState: Bool = false) {
        conflict = nil
        if !keepState { syncState = .inSync }
        bannerSerial += 1
        host?.hideBanner()
    }

    /// Banner/sheet action: discard the typed text in favour of the disk version. One undoable edit (Undo brings
    /// the typed text back); the document counts as unmodified afterwards.
    func reloadFromDisk() {
        if let c = conflict, let text = c.diskText, let fmt = c.diskFormat {
            applyExternal(DecodedText(text: text, format: fmt, byteCount: c.disk.byteCount), c.disk, mode: isDocumentEdited ? .undoable : .silent)
            updateChangeCount(.changeCleared)
            clearConflictUI()
            deletedMarkedDirty = false
            trace("conflict resolved: reloaded from disk")
        } else if let url = fileURL {
            do { try revertNow(toContentsOf: url) } catch { presentError(error) }
        }
    }

    /// Banner/sheet action: the typed text wins. The disk version we were told about is acknowledged (so the next save
    /// is allowed to replace it) and becomes the merge base.
    func keepMyVersion() {
        guard let c = conflict else { clearConflictUI(); return }
        lastDisk = c.disk
        generation &+= 1
        syncModificationDate(c.disk.signature)
        baseSnapshot = c.diskText
        baseFormat = c.diskFormat
        clearConflictUI()
        trace("conflict resolved: keeping my version (next save overwrites)")
        if isDocumentEdited { updateChangeCount(.changeDone) }       // make sure an autosave is scheduled soon
    }

    // MARK: NSDocument-driven reverts (Revert to Saved, Versions, coordinated external writes)

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        // NSDocument calls this BY ITSELF when a COORDINATED writer (iCloud Drive, OneDrive / Dropbox File Provider clients, anything that uses
        // NSFileCoordinator) is done: relinquishPresentedItem(toWriter:) -> reacquirer -> _revertToVersion:preservingFirst: -> here, whether or
        // not the document has unsaved edits. Applying the disk text then threw away the merge that our own check had made a moment earlier,
        // marked the document clean and dropped the typed text without a word (found by the audit: type, coordinated write -> the typed text
        // is gone). Typed text is never discarded on NSDocument's initiative: the policy (merge / conflict) decides. The explicit
        // "discard my edits" commands (banner, File > Reload from Disk) use `revertNow` directly.
        if hasRealEdits || (undoManager?.groupingLevel ?? 0) > 0 || editorHasUnsavedText() {      // (a keystroke whose undo group is still open does not count as an edit yet; the change count can lag: editorHasUnsavedText)
            trace("revert(toContentsOf:) by NSDocument while the document has unsaved edits: not applied, the external-change policy decides")
            checkForExternalChange("nsdocument-revert")
            return
        }
        try revertNow(toContentsOf: url)
    }

    /// Replaces the editor text by what is on disk (minimal diff, selection / scroll kept). Does NOT call super: it would call read(from:), which
    /// replaces the text wholesale (selection, scroll and undo state are lost). Same minimal-diff path as every other reload.
    func revertNow(toContentsOf url: URL) throws {
        let (data, sig) = try DiskReader.readFile(path: url.path)
        let decoded = try data.withUnsafeBytes { try TextCodec.decode(bytes: $0) }
        let state = DiskReader.state(of: data, signature: sig)
        let wasEdited = isDocumentEdited
        applyExternal(decoded, state, mode: wasEdited ? .undoable : .silent)
        deletedMarkedDirty = false
        updateChangeCount(.changeCleared)
        clearConflictUI()
        stats.lastReloadTrigger = "revert"
        trace("revert(toContentsOf:) -> minimal-diff reload (wasEdited=\(wasEdited))")
    }

    // MARK: missing file

    private func fileMissing() {
        if syncState == .deletedOnDisk || missingCheckScheduled { return }
        missingCheckScheduled = true
        // Grace period: a move is reported by NSFilePresenter (presentedItemDidMove -> fileURL changes) within ~1.1 s,
        // and a delete+recreate writer needs a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.missingCheckScheduled = false
            guard let url = self.fileURL else { return }
            if FileSignature.of(path: url.path) != nil { self.checkForExternalChange("missing-grace"); return }
            self.enterDeleted()
        }
    }

    /// The file is gone and the user asks to close the (dirty) document before the grace period of `fileMissing()` has run out: nothing may be
    /// refused silently (the held-back autosave cancels the close without a word), so the "deleted or moved" state is entered now.
    func noteFileGoneBeforeClose() {
        guard syncState == .inSync, isDocumentEdited, let url = fileURL, lastDisk != nil, !isSaving, FileSignature.of(path: url.path) == nil else { return }
        enterDeleted()
    }

    private func enterDeleted() {
        guard syncState != .deletedOnDisk else { return }
        syncState = .deletedOnDisk
        stats.deletions += 1
        if !isDocumentEdited { updateChangeCount(.changeDone); deletedMarkedDirty = true }   // closing must ask; the text may be the only copy
        host?.showBanner(EditorBanner(
            message: "“\(displayName ?? "file")” was deleted or moved. Your text is still open.",
            style: .warning,
            buttons: [("Save Again…", { [weak self] in self?.save(nil) })]))
        trace("file deleted/moved away")
    }

    private func fileReappeared() {
        // back at the same path (restored, recreated by an atomic writer): fall through to the normal comparison
        syncState = .inSync
        host?.hideBanner()
        monitor?.nudge()        // the descriptors may sit on the deleted inode / directory: make the monitor look again (re-bind if needed)
        trace("file reappeared")
    }

    // MARK: save gate

    enum SaveGate { case proceed, cancelSilently, ask }

    /// Called at the start of every save/autosave to the document's own file. Synchronous.
    func preSaveGate(_ op: NSDocument.SaveOperationType) -> SaveGate {
        guard let url = fileURL, let last = lastDisk else { return .proceed }
        let isAutosave = op == .autosaveInPlaceOperation
        switch syncState {
        case .conflict, .unreadable: return isAutosave ? .cancelSilently : .ask
        case .deletedOnDisk: return isAutosave ? .cancelSilently : .proceed
        case .inSync: break
        }
        guard let sig = FileSignature.of(path: url.path) else { return isAutosave ? .cancelSilently : .proceed }
        if sig == last.signature { return .proceed }
        do {
            switch try DiskLoad.load(path: url.path, knownHash: last.hash) {
            case .unchanged(let st):
                lastDisk = st; syncModificationDate(st.signature); return .proceed
            case .changed(let decoded, let st):
                // An autosave tick during IME composition must not apply the other tool's text (merge or reload) under the marked text: AppKit then
                // drops the composition and the preedit letters stay in the text as ordinary characters (found by the audit: "ni" + commit "你" ->
                // "ni你"). Same guard as finishCheck: hold the autosave back, look again when the composition is over (the merge makes the document
                // dirty again, which schedules the next autosave).
                if isAutosave, host?.isComposingText == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.retryAfterComposition() }
                    return .cancelSilently
                }
                let behavior = EditorPreferences.reloadBehavior
                if behavior == .automatic {
                    if !isDocumentEdited && (undoManager?.groupingLevel ?? 0) == 0 && !editorHasUnsavedText() { silentReload(decoded, st); return .proceed }     // (open undo group: see finishCheck)
                    resolveDirtyChange(decoded, st)
                } else {
                    enterConflict(decoded, st, banner: behavior == .ask)        // ask / never: nothing is merged or reloaded by itself
                }
                return syncState == .inSync ? .proceed : (isAutosave ? .cancelSilently : .ask)
            }
        } catch {
            enterUnreadable(error, signature: sig)
            return isAutosave ? .cancelSilently : .ask
        }
    }

    /// A held-back autosave is not retried by NSDocument by itself: wait for the end of the composition, let the policy look at the file, and
    /// make sure the next autosave is scheduled.
    private func retryAfterComposition() {
        guard !isClosed else { return }
        if host?.isComposingText == true { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.retryAfterComposition() }; return }
        checkForExternalChange("composing")
        if isDocumentEdited { updateChangeCount(.changeDone) }
    }

    enum OverwriteChoice { case overwrite, reload, cancel }

    func presentOverwriteSheet(completion: @escaping (OverwriteChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "“\(displayName ?? "This file")” was changed by another application."
        alert.informativeText = syncState == .unreadable
            ? "luftig cannot show the new version. Saving now replaces it with your text."
            : "Saving now replaces those changes with your version. You can also load the other version instead (Undo brings your text back)."
        alert.addButton(withTitle: "Overwrite File")
        if syncState != .unreadable { alert.addButton(withTitle: "Reload from Disk") }
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { r in
            let idx = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let canReload = self.syncState != .unreadable
            switch idx {
            case 0: completion(.overwrite)
            case 1: completion(canReload ? .reload : .cancel)
            default: completion(.cancel)
            }
        }
        if let w = sheetWindow { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    enum CloseChoice { case save, discard, cancel }

    func presentCloseSheet(completion: @escaping (CloseChoice) -> Void) {
        let alert = NSAlert()
        let name = displayName ?? "This document"
        if syncState == .deletedOnDisk {
            alert.messageText = "“\(name)” was deleted or moved, and has unsaved text."
            alert.informativeText = "Save it again to keep your text, or discard it."
            alert.addButton(withTitle: "Save Again")
        } else {
            alert.messageText = "“\(name)” has unsaved changes, and the file was changed by another application."
            alert.informativeText = "Overwrite the file with your version, or discard your changes and keep the other application's version."
            alert.addButton(withTitle: "Overwrite File")
        }
        alert.addButton(withTitle: "Discard My Changes")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { r in
            switch r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
            case 0: completion(.save)
            case 1: completion(.discard)
            default: completion(.cancel)
            }
        }
        if let w = sheetWindow { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// After a successful save to our own file: the bytes we wrote are the new disk state.
    func didSaveToOwnFile() {
        guard let url = fileURL, let enc = lastEncoded else { return }
        guard let sig = FileSignature.of(path: url.path) else { return }
        lastDisk = DiskState(signature: sig, hash: enc.hash, byteCount: enc.count)
        generation &+= 1
        baseSnapshot = nil; baseFormat = nil
        syncState = .inSync
        conflict = nil
        deletedMarkedDirty = false
        host?.hideBanner()
        armMonitorIfNeeded()
        // Narrow race: another process may have replaced the file between our write and the stat. Verify the bytes.
        let path = url.path, want = enc.hash
        loadQueue.async { [weak self] in
            guard let (data, _) = try? DiskReader.readFile(path: path) else { return }
            let h = data.withUnsafeBytes { FastHash.hash64($0) }
            if h != want { DispatchQueue.main.async { self?.lastDisk?.signature.size = -1; self?.checkForExternalChange("post-save-verify") } }
        }
    }
}
