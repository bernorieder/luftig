// MarkdownDocument.swift
//
// The NSDocument subclass of Scribe: file I/O, encoding/line-ending round trip, save gating.
// The external-change policy (watch, silent reload, merge, conflict) lives in MarkdownDocument+ExternalChanges.swift.
//
// Info.plist wires this class as "Scribe.MarkdownDocument" (module-qualified: SwiftPM module is "Scribe").
//
// Threading: everything here runs on the main thread except `read(from:ofType:)` if
// `canConcurrentlyReadDocuments` is ever switched on (it is off: the measured gain is a 19 ms -> 1.5 ms main-thread stall
// for a 10 MB non-ASCII file and nothing for ASCII, see docs/spike-document.md).

import AppKit

final class MarkdownDocument: NSDocument {

    // MARK: configuration (class level)

    /// Autosave in place: edits go to the real file a few seconds after typing stops; "dirty" windows are short-lived,
    /// so an external change nearly always meets a clean document and reloads silently.
    override class var autosavesInPlace: Bool { autosavesInPlaceEnabled }
    /// Experiment switch (SelfTest "autosave-off" runs the policy with classic Save semantics); production value: true.
    nonisolated(unsafe) static var autosavesInPlaceEnabled = true

    /// Reading on a background thread: 10 MB ASCII = 0.3 ms read + 0.3 ms decode (nothing to gain); 10 MB non-ASCII UTF-8
    /// = 16 ms decode (main-thread stall 19 ms -> 1.5 ms when concurrent, total wall time unchanged). Costs a
    /// concurrency surface in read(from:). Off; flip it only if 10 MB+ non-ASCII files matter.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { concurrentReading }
    /// Experiment switch (SelfTestBench "open-perf" measures both); production value: false.
    nonisolated(unsafe) static var concurrentReading = false

    /// We always load the whole file or refuse it (> 200 MB / binary). If a "huge file preview" mode is ever added,
    /// return false for it: NSDocument then refuses to autosave/save-in-place over a partially loaded file.
    override var isEntireFileLoaded: Bool { true }

    /// How long the "Merged changes from disk" info banner stays.
    nonisolated(unsafe) static var mergeBannerSeconds: TimeInterval = 8

    /// Hook for tests: every interesting transition is reported here (nil in production).
    nonisolated(unsafe) static var trace: ((MarkdownDocument, String) -> Void)?

    // MARK: state

    /// Encoding / BOM / line-ending style of the file as read (and as written back).
    var textFormat = TextFormat()
    /// Text before an editor is attached (read from disk, window not built yet) - dropped once the host has it.
    var pendingText: NSString = ""
    weak var host: EditorHost?

    /// What we believe is on disk right now (fingerprint + content hash). nil for a never-saved untitled document.
    var lastDisk: DiskState?
    /// Hash/size of the bytes produced by the last `data(ofType:)` (becomes `lastDisk` when the save succeeds).
    var lastEncoded: (hash: UInt64, count: Int)?
    /// Text as it was on disk when the document was last in sync - captured lazily at the first edit after a sync
    /// point (see editorWillChangeText) and used as the base of the three-way merge.
    var baseSnapshot: NSString?
    var syncState: ExternalSyncState = .inSync
    var conflict: ExternalConflict?
    var monitor: ExternalChangeMonitor?
    var isSaving = false
    var isApplyingExternal = false
    var isClosed = false
    var checkInFlight = false
    var recheckRequested = false
    var generation = 0
    var lastUnreadableSignature: FileSignature?
    var deletedMarkedDirty = false
    var missingCheckScheduled = false
    var stats = ExternalChangeStats()
    var bannerSerial = 0
    let loadQueue = DispatchQueue(label: "local.scribe.diskload", qos: .userInitiated)

    func trace(_ s: @autoclosure () -> String) { MarkdownDocument.trace?(self, s()) }

    // MARK: lifecycle

    override init() {
        super.init()
        // New untitled documents: Markdown, UTF-8, LF. fileType comes from the first CFBundleDocumentTypes entry.
        hasUndoManager = true
    }

    override func makeWindowControllers() {
        let wc = EditorWindowController()        // <- Scribe's real window controller goes here; it must expose an EditorHost
        addWindowController(wc)
        if let h = wc.editorHost {
            host = h
            h.loadInitialText(pendingText)
            pendingText = ""
        }
    }

    /// The window for sheets. (The reference window controller - EditorWindowController.swift - is replaceable: its
    /// `editorHost` is the only coupling, see makeWindowControllers.)
    var sheetWindow: NSWindow? { windowControllers.first?.window }

    override func close() {
        isClosed = true
        NotificationCenter.default.removeObserver(self)
        monitor?.stop(); monitor = nil
        super.close()
    }

    // MARK: reading

    override func read(from url: URL, ofType typeName: String) throws {
        let (data, sig) = try DiskReader.readFile(path: url.path)
        let decoded = try data.withUnsafeBytes { try TextCodec.decode(bytes: $0) }
        let state = DiskReader.state(of: data, signature: sig)
        textFormat = decoded.format
        lastDisk = state
        baseSnapshot = nil
        if let host {      // not the initial read (NSDocument-initiated re-read): go through the live path
            host.applyExternalText(decoded.text, mode: isDocumentEdited ? .undoable : .silent)
        } else {
            pendingText = decoded.text
        }
        trace("read(from:) \(data.count) bytes, \(decoded.format)")
        DispatchQueue.main.async { [weak self] in self?.armMonitorIfNeeded() }
    }

    /// Never called for files (we override read(from url:)), but required to exist for NSDocument subclasses that
    /// are also asked to read non-file data (e.g. pasteboard / drag). Same decoding.
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try TextCodec.decode(data)
        textFormat = decoded.format
        pendingText = decoded.text
    }

    // MARK: writing

    override func data(ofType typeName: String) throws -> Data {
        let text = host?.currentText ?? pendingText
        let data: Data
        do {
            data = try TextCodec.encode(text, format: textFormat)
        } catch ScribeError.notRepresentable {
            // Typed a character the legacy encoding cannot hold: keep the user's text, switch the file to UTF-8.
            trace("encoding \(textFormat.encoding.displayName) cannot represent the text; saving as UTF-8")
            textFormat.encoding = .utf8
            textFormat.hasBOM = false
            data = try TextCodec.encode(text, format: textFormat)
        }
        lastEncoded = (data.withUnsafeBytes { FastHash.hash64($0) }, data.count)
        return data
    }

    /// Default file type / extension for new documents: ".md" (the Markdown type is the first document type).
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        super.fileNameExtension(forType: typeName, saveOperation: saveOperation) ?? "md"
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowsOtherFileTypes = true            // let the user type "notes.txt" or "README" without being forced to .md
        savePanel.isExtensionHidden = false
        savePanel.canCreateDirectories = true
        return super.prepareSavePanel(savePanel)
    }

    /// Explicit save (⌘S, close-and-save). With autosavesInPlace == false NSDocument runs its OWN "file changed by another
    /// application since you opened or saved it - Save anyway?" sheet right here, before save(to:) is reached; with
    /// autosavesInPlace == true it fails inside save(to:) with error 67000 and a 3-button sheet. Both are pre-empted by
    /// resolving the external change first (merge / our sheet) so that NSDocument's modification-date check passes.
    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        func answer(_ saved: Bool) {
            if let sel = didSaveSelector, let d = delegate as? NSObject {
                typealias Fn = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
                unsafeBitCast(d.method(for: sel), to: Fn.self)(d, sel, self, saved, contextInfo)
            }
        }
        guard fileURL != nil, lastDisk != nil, syncState != .deletedOnDisk else {
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo); return
        }
        switch preSaveGate(.saveOperation) {
        case .proceed, .cancelSilently:
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
        case .ask:
            presentOverwriteSheet { choice in
                switch choice {
                case .overwrite: self.keepMyVersion(); super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
                case .reload: self.reloadFromDisk(); answer(false)
                case .cancel: answer(false)
                }
            }
        }
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let toOwnFile = fileURL.map { $0.standardizedFileURL.path == url.standardizedFileURL.path } ?? false
        let gated = toOwnFile && (saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation)
        guard gated else { performSave(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler); return }
        switch preSaveGate(saveOperation) {
        case .proceed:
            performSave(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
        case .cancelSilently:
            // NSUserCancelledError is swallowed by NSDocument: no alert, no write, the document stays dirty.
            trace("save(op=\(saveOperation.rawValue)) held back: \(syncState)")
            completionHandler(CocoaError(.userCancelled))
        case .ask:
            presentOverwriteSheet { [self] choice in
                switch choice {
                case .overwrite: keepMyVersion(); performSave(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
                case .reload: reloadFromDisk(); completionHandler(CocoaError(.userCancelled))
                case .cancel: completionHandler(CocoaError(.userCancelled))
                }
            }
        }
    }

    private func performSave(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                             completionHandler: @escaping (Error?) -> Void) {
        isSaving = true
        // Only these operations write the document's own file. autosaveElsewhere (drafts, autosavesInPlace == false) and
        // saveTo (a copy) write somewhere else and must not touch our idea of what is on disk.
        let writesOwnFile = saveOperation == .saveOperation || saveOperation == .saveAsOperation || saveOperation == .autosaveInPlaceOperation
        trace("save(to: \(url.lastPathComponent), op=\(saveOperation.rawValue)) begins")
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            self.trace("save(to: \(url.lastPathComponent), op=\(saveOperation.rawValue)) finished: \(error.map { "\($0)" } ?? "ok")")
            self.isSaving = false
            if error == nil, writesOwnFile { self.didSaveToOwnFile() }
            completionHandler(error)
            if self.recheckRequested { self.recheckRequested = false; self.checkForExternalChange("after-save") }
        }
    }

    // MARK: NSFilePresenter (NSDocument is its own presenter)
    // Callbacks arrive on a private queue ~0.5-1.1 s after an external write; hop to main and run the idempotent check.

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.checkForExternalChange("presenter:change") }
    }
    override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)          // NSDocument updates fileURL (-> fileURLDidChange re-arms the monitor)
        DispatchQueue.main.async { [weak self] in self?.checkForExternalChange("presenter:move") }
    }
    override func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        super.accommodatePresentedItemDeletion(completionHandler: completionHandler)
        DispatchQueue.main.async { [weak self] in self?.checkForExternalChange("presenter:deletion") }
    }
    override func presentedItemDidGain(_ version: NSFileVersion) {
        super.presentedItemDidGain(version)
        DispatchQueue.main.async { [weak self] in self?.checkForExternalChange("presenter:version") }
    }

    /// ⌘S. NSDocument cannot save in place to a file that no longer exists (alert: "The location of the document
    /// cannot be determined"): ask for a new location instead (the panel starts in the old folder).
    override func save(_ sender: Any?) {
        if syncState == .deletedOnDisk { runSaveAsPanel(completion: { _ in }) } else { super.save(sender) }
    }

    /// Save As… for an autosave-in-place document first autosaves the original; while an external conflict / deletion is
    /// unresolved that autosave is (deliberately) held back and the whole flow would fail silently. In those states
    /// Save As… is our own panel + save(to:for:.saveAsOperation), which re-homes the document to the new file.
    override func saveAs(_ sender: Any?) {
        if syncState == .inSync { super.saveAs(sender) } else { runSaveAsPanel(completion: { _ in }) }
    }

    func runSaveAsPanel(completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        if let dir = fileURL?.deletingLastPathComponent(), FileManager.default.fileExists(atPath: dir.path) { panel.directoryURL = dir }
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? ((displayName ?? "Untitled") + ".md")
        _ = prepareSavePanel(panel)
        let finish: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK, let url = panel.url else { completion(false); return }
            self.save(to: url, ofType: self.fileType ?? "net.daringfireball.markdown", for: .saveAsOperation) { error in
                if let error { self.presentError(error) }
                completion(error == nil)
            }
        }
        if let w = sheetWindow { panel.beginSheetModal(for: w, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// File > Reload from Disk (⌥⌘R): the manual counterpart of the automatic reload. Discards unsaved edits (undoable).
    @objc func scribeReloadFromDisk(_ sender: Any?) {
        guard let url = fileURL else { return }
        let doIt = { [self] in
            try? revert(toContentsOf: url, ofType: fileType ?? "net.daringfireball.markdown")
        }
        guard isDocumentEdited, hasRealEdits else { doIt(); return }
        let alert = NSAlert()
        alert.messageText = "Reload “\(displayName ?? "this document")” from disk?"
        alert.informativeText = "Your unsaved changes are discarded. Undo brings them back."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { doIt() } }
        if let w = sheetWindow { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(scribeReloadFromDisk(_:)) { return fileURL != nil }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: closing with an unresolved external change
    // With autosave in place NSDocument saves on close. A held-back autosave (conflict / deleted file) would make the
    // close fail silently ("the window cannot be closed and nothing says why") - ask instead.

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard syncState != .inSync, isDocumentEdited else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        func answer(_ close: Bool) {
            if let sel = shouldCloseSelector, let d = delegate as? NSObject {
                typealias Fn = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
                unsafeBitCast(d.method(for: sel), to: Fn.self)(d, sel, self, close, contextInfo)
            }
        }
        presentCloseSheet { choice in
            switch choice {
            case .save:
                if self.syncState == .deletedOnDisk {
                    self.runSaveAsPanel { ok in answer(ok) }
                } else {
                    self.keepMyVersion()          // the user chose to overwrite: acknowledge, then the normal save-and-close
                    super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
                }
            case .discard:
                self.clearConflictUI()
                self.deletedMarkedDirty = false
                self.updateChangeCount(.changeCleared)
                super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            case .cancel:
                answer(false)
            }
        }
    }

    override var fileURL: URL? {
        didSet { if fileURL != oldValue { fileURLDidChange() } }
    }

    // MARK: editor -> document notifications

    /// Called by the editor BEFORE it applies a user edit (NSTextViewDelegate.textView(_:shouldChangeTextIn:...)).
    /// Captures the merge base once per "dirty cycle": the text equals the disk text at this moment.
    nonisolated(unsafe) static var captureMergeBase = true      // experiment switch (bench measures the cost of the snapshot)
    func editorWillChangeText() {
        guard MarkdownDocument.captureMergeBase, baseSnapshot == nil, lastDisk != nil, let host, !isApplyingExternal else { return }
        baseSnapshot = host.currentText.copy() as? NSString
    }

    // MARK: printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = (printInfo.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.dictionary().addEntries(from: printSettings.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value })
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.isVerticallyResizable = true
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.string = (host?.currentText ?? pendingText) as String
        tv.sizeToFit()
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = true
        return op
    }
}
