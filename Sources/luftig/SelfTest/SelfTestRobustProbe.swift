#if LUFTIG_SELFTEST
// SelfTestRobustProbe.swift - throw-away experiments of the robustness review (not part of the delivered patch).
import AppKit
import MarkdownKit

extension Robust {
    @MainActor static func probe(_ t: SelfTest.T) async throws {
        let which = SelfTest.argument("probe") ?? "symlink"
        switch which {
        case "symlink": try await probeSymlink(t)
        case "keepunreadable": try await probeKeepUnreadable(t)
        case "bigcycles": try await probeBigCycles(t)
        case "quickclose": try await probeQuickClose(t)
        case "coldmiddle": try await probeColdMiddle(t)
        case "inflight": try await probeInFlight(t)
        case "wcclose": try await probeWCClose(t)
        case "symdir": try await probeSymDir(t)
        default: t.note("unknown probe \(which)")
        }
    }

    @MainActor static func probeSymlink(_ t: SelfTest.T) async throws {
        // an OPEN document whose file is replaced by a symlink to another regular file (stow / chezmoi / `ln -sf` style)
        let f = t.url("doc.md"), other = t.url("other.md")
        try Data("# doc\n\nhello\n".utf8).write(to: f)
        try Data("# other\n\nworld\n".utf8).write(to: other)
        let d = try await t.open(f)
        await t.sh("rm -f \(t.q(f)) && ln -s \(t.q(other)) \(t.q(f))")
        let seen = await t.waitFor(3000) { d.host?.currentText.contains("world") == true || d.syncState != .inSync }
        t.note("file replaced by a symlink: editor shows the other file: \(d.host?.currentText.contains("world") == true), state \(d.syncState)")
        t.typeText("X", into: d, at: NSRange(location: 0, length: 0))
        await t.sleep(50)
        UITrap.reset()
        let err = await t.autosave(d)
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: f.path)) != nil
        t.note("autosave: error \(String(describing: err)); path still a symlink: \(isLink); other.md: \(t.read(other).debugDescription); doc.md: \(t.read(f).debugDescription); seen \(seen); alerts \(UITrap.alerts.map { $0.message })")
        t.check(err == nil, "autosave of a document whose file was replaced by a symlink to a regular file succeeds")
        let w = SaveWaiterProbe()
        d.save(withDelegate: w, didSave: #selector(SaveWaiterProbe.document(_:didSave:contextInfo:)), contextInfo: nil)
        _ = await t.waitFor(4000) { w.result != nil }
        t.note("explicit save result \(String(describing: w.result)); doc.md: \(t.read(f).debugDescription); alerts: \(UITrap.alerts.map { $0.message })")
        t.close(d)
    }
}

extension Robust {
    @MainActor static func probeKeepUnreadable(_ t: SelfTest.T) async throws {
        let f = t.url("keep.md")
        try Data("# keep\n\nline one\n".utf8).write(to: f)
        let d = try await t.open(f)
        t.typeText("X", into: d, at: NSRange(location: 0, length: 0))
        await t.sleep(40)
        await t.sh("printf '\\000\\001\\002binary\\000' > \(t.q(f))")
        let seen = await t.waitFor(3000) { d.syncState == .unreadable }
        t.note("binary version noticed: \(seen), state \(d.syncState), banner buttons \(d.host.map { ($0 as? EditorViewController)?.bannerButtonTitles ?? [] } ?? [])")
        (d.host as? EditorViewController)?.pressBannerButton("Keep My Version")
        await t.sleep(30)
        t.note("after Keep My Version: state \(d.syncState), lastDisk hash \(d.lastDisk.map { String($0.hash, radix: 16) } ?? "nil"), file bytes \(t.readData(f).count), edited \(d.isDocumentEdited)")
        let err = await t.autosave(d)
        t.note("autosave: \(String(describing: err)); file bytes \(t.readData(f).count) text \(t.read(f).debugDescription); lastDisk hash \(d.lastDisk.map { String($0.hash, radix: 16) } ?? "nil") size \(d.lastDisk?.byteCount ?? -1); state \(d.syncState); edited \(d.isDocumentEdited)")
        t.typeText("Y", into: d, at: NSRange(location: 0, length: 0))
        await t.sleep(40)
        let err2 = await t.autosave(d)
        t.note("second autosave: \(String(describing: err2)); file text \(t.read(f).debugDescription); lastDisk hash \(d.lastDisk.map { String($0.hash, radix: 16) } ?? "nil"); state \(d.syncState)")
        t.close(d)
    }
}

extension Robust {
    /// N open / edit / close cycles of one document of `--mb` MB: per cycle footprint, malloc in-use, RSS and which objects are still alive.
    @MainActor static func probeBigCycles(_ t: SelfTest.T) async throws {
        RobustWatchdog.shared.start(); RobustCrash.install()
        let n = SelfTest.argument("n").flatMap { Int($0) } ?? 10, mb = SelfTest.argument("mb").flatMap { Int($0) } ?? 20
        let mode = SelfTest.argument("close").flatMap { Int($0) } ?? 1
        let f = t.url("cycle.md")
        try RobustFiles.writeCorpus(f, bytes: mb << 20, seed: 5)
        var lives: [LiveSet] = []
        func line(_ tag: String) { let sn = RobustResources.snapshot(); t.note("\(tag): footprint \(RobustResources.mbs(sn.footprint)), malloc-in-use \(RobustResources.mbs(sn.heap)), rss \(RobustResources.mbs(sn.rss)); alive: \(lives.filter { !$0.alive.isEmpty }.map { $0.alive.joined(separator: "+") })") }
        line("start")
        let userClose = CloseProbe()
        for i in 0..<n {
            let d = try await t.open(f, size: NSSize(width: 860, height: 700))
            lives.append(LiveSet(d))
            if let h = t.editor(d) { t.typeText("x", into: d, at: NSRange(location: 0, length: 0)); t.scrollToTop(h, character: h.currentText.length / 2); _ = t.renderPNG(d.windowControllers.first!.window!) }
            if mode == 0 { d.updateChangeCount(.changeCleared); d.close() }
            else if mode == 1 {
                await t.spin(60)
                d.canClose(withDelegate: userClose, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
                _ = await t.waitFor(5000) { userClose.result != nil }
                if userClose.result == true { d.close() } else { d.updateChangeCount(.changeCleared); d.close() }
                userClose.result = nil
            } else { await t.spin(60); d.windowControllers.first?.close(); if NSDocumentController.shared.documents.contains(where: { $0 === d }) { d.updateChangeCount(.changeCleared); d.close() } }
            await t.spin(400)
            line("cycle \(i + 1) (\(mb) MB, close mode \(mode))")
            try RobustFiles.writeCorpus(f, bytes: mb << 20, seed: 5)
        }
        await t.spin(3500)
        line("3.5 s after the last close")
        let rel = RobustResources.pressureRelief()
        await t.spin(300)
        line("after malloc_zone_pressure_relief (\(RobustResources.mbs(rel)) released)")
        if SelfTest.flag("vmmap") { t.note("vmmap 'Malloc Large (empty)' (virtual / resident / dirty): \(RobustResources.vmmapLargeEmpty() ?? "n/a")") }
        if SelfTest.flag("relief") {
            // can the application give the freed blocks back?  (each variant, then the footprint)
            let z = malloc_default_zone()
            let a = malloc_zone_pressure_relief(z, 0); await t.spin(200); line("malloc_zone_pressure_relief(default zone, 0) returned \(RobustResources.mbs(Int(a)))")
            let b = malloc_zone_pressure_relief(nil, 1 << 30); await t.spin(200); line("malloc_zone_pressure_relief(all zones, 1 GB) returned \(RobustResources.mbs(Int(b)))")
            // a big allocation that is touched and freed makes libmalloc look at its cache
            let big = malloc(512 << 20); memset(big, 1, 512 << 20); free(big); await t.spin(300); line("after malloc/touch/free of 512 MB")
            if let v = RobustResources.vmmapLargeEmpty() { t.note("vmmap 'Malloc Large (empty)' now: \(v)") }
        }
        if SelfTest.flag("vmmap-full") {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap"); p.arguments = ["-summary", "\(getpid())"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            if (try? p.run()) != nil {
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
                for l in text.split(separator: "\n").prefix(70) { out("    | " + l.prefix(200)) }
            }
        }
    }
}

extension Robust {
    /// How long does a document stay alive after the test helper's quick close (updateChangeCount(.changeCleared) + close() right after an edit)?
    @MainActor static func probeQuickClose(_ t: SelfTest.T) async throws {
        let delay = SelfTest.argument("autosave-delay").flatMap { Double($0) }
        if let delay { NSDocumentController.shared.autosavingDelay = delay }
        t.note("NSDocumentController.autosavingDelay = \(NSDocumentController.shared.autosavingDelay)")
        let f = t.url("q.md")
        try RobustFiles.writeCorpus(f, bytes: 300_000, seed: 5)
        var lives: [LiveSet] = []
        for _ in 0..<4 {
            let d = try await t.open(f)
            lives.append(LiveSet(d))
            t.typeText("x", into: d, at: NSRange(location: 0, length: 0))
            d.updateChangeCount(.changeCleared); d.close()
            await t.spin(50)
        }
        let t0 = now()
        var reported = Set<Int>()
        while now() - t0 < 45_000 {
            await t.spin(500)
            let sec = Int((now() - t0) / 1000)
            if [1, 2, 3, 4, 5, 8, 12, 16, 20, 30, 40].contains(sec), !reported.contains(sec) {
                reported.insert(sec)
                t.note("\(sec) s after the quick closes: alive \(lives.map { $0.alive.joined(separator: "+").isEmpty ? "-" : $0.alive.joined(separator: "+") })")
            }
        }
    }
}

extension Robust {
    /// The first keystroke in the MIDDLE of a freshly opened big document of a given script: where do the milliseconds go? (`sample` runs in a separate process while the main thread is busy.)
    @MainActor static func probeColdMiddle(_ t: SelfTest.T) async throws {
        RobustWatchdog.shared.start(); RobustCrash.install()
        let kind = SelfTest.argument("kind") ?? "cjk"
        let f = t.url("cold-\(kind).md")
        let unit: String
        switch kind {
        case "rtl": unit = "مرحبا بالعالم שלום עולם **bold** `code`\n"
        case "cjk": unit = "日本語のテキストと中文的内容 **強調** `コード` 한국어\n"
        case "emoji": unit = "😀👩‍💻🎉 text\n"
        default: unit = "a line of ascii text with *emphasis* and `code` in it\n"
        }
        try RobustFiles.writeRepeating(f, unit: Array(unit.utf8), count: (10 << 20) / unit.utf8.count)
        let d = try await t.open(f, size: NSSize(width: 860, height: 700))
        guard let h = t.editor(d) else { return }
        _ = t.renderPNG(d.windowControllers.first!.window!)
        let units = h.currentText.length
        if SelfTest.flag("prefix") {
            // experiment: fix the font attributes of the whole text in slices (what an idle task after open could do) and see what the cold keystroke costs afterwards
            let ts = h.textView.textStorage!
            let slice = SelfTest.argument("slice").flatMap { Int($0) } ?? 200_000
            var loc = 0, worst = 0.0, total = 0.0
            while loc < units {
                let r = NSRange(location: loc, length: min(slice, units - loc))
                let ms = time { ts.fixAttributes(in: r) }
                worst = max(worst, ms); total += ms; loc += slice
            }
            t.note(String(format: "fixAttributes in %d-unit slices: total %.0f ms, worst slice %.0f ms", slice, total, worst))
        }
        let file = NSTemporaryDirectory() + "luftig-cold-\(getpid()).txt"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(getpid())", "1", "1", "-file", file]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        try await Task.sleep(nanoseconds: 300_000_000)       // sample has attached and waits for its first tick
        let ms = time { t.typeText("x", into: d, at: NSRange(location: units / 2, length: 0)) }
        t.note(String(format: "%@ 10 MB: first keystroke in the middle took %.0f ms (%d units)", kind, ms, units))
        let ms2 = time { t.typeText("x", into: d, at: NSRange(location: units / 2 + 5, length: 0)) }
        let ms3 = time { t.typeText("x", into: d, at: NSRange(location: units / 4, length: 0)) }
        let ms4 = time { t.typeText("x", into: d, at: NSRange(location: units * 3 / 4, length: 0)) }
        t.note(String(format: "second keystroke next to it %.0f ms, at 1/4: %.0f ms, at 3/4: %.0f ms", ms2, ms3, ms4))
        p.waitUntilExit()
        if let text = try? String(contentsOfFile: file, encoding: .utf8), let i = text.components(separatedBy: "\n").firstIndex(where: { $0.contains("Call graph:") }) {
            let lines = text.components(separatedBy: "\n")
            // heaviest leaf-ish frames: print the main thread's call graph down to where the width narrows
            for l in lines[(i + 1)..<min(lines.count, i + 90)] { out("    | " + l.prefix(190)) }
        }
        t.close(d)
    }
}

extension Robust {
    /// A document inside a SYMLINKED DIRECTORY (~/notes -> ~/Dropbox/notes): open, edit, autosave, external change.
    @MainActor static func probeSymDir(_ t: SelfTest.T) async throws {
        let realDir = t.url("realdir"), linkDir = t.url("linkdir")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        try Data("# in a symlinked dir\n\nhello\n".utf8).write(to: realDir.appendingPathComponent("a.md"))
        let viaLink = linkDir.appendingPathComponent("a.md")
        let d = try await t.open(viaLink)
        t.note("opened \(viaLink.lastPathComponent) through a symlinked directory: fileURL \(d.fileURL?.path ?? "nil")")
        t.typeText("X", into: d, at: NSRange(location: 0, length: 0))
        await t.sleep(50)
        UITrap.reset()
        let err = await t.autosave(d)
        t.note("autosave: \(String(describing: err)); real file: \(t.read(realDir.appendingPathComponent("a.md")).debugDescription)")
        t.check(err == nil && t.read(realDir.appendingPathComponent("a.md")).hasPrefix("X"), "a document inside a symlinked directory autosaves")
        await t.sh("printf 'external\\n' >> \(t.q(realDir.appendingPathComponent("a.md")))")
        let seen = await t.waitFor(3000) { d.host?.currentText.contains("external") == true }
        t.check(seen, "an external change to the real file is shown (document opened through the link)")
        t.close(d)
    }
}

extension Robust {
    /// What does NSWindowController.close() do to the document, with and without an external change in flight? Timeline of what stays alive.
    @MainActor static func probeWCClose(_ t: SelfTest.T) async throws {
        NSDocumentController.shared.autosavingDelay = 3
        let ext = SelfTest.flag("external")
        var lives: [(LiveSet, Bool)] = []
        for i in 0..<4 {
            let f = t.url("w\(i).md")
            try RobustFiles.writeCorpus(f, bytes: 2 << 20, seed: UInt64(70 + i))
            let a = try await t.open(f)
            let live = LiveSet(a)
            if SelfTest.flag("find"), let h = t.editor(a) {
                h.textView.performTextFinderAction(NSTextFinder.Action.showFindInterface.asSenderProbe); await t.spin(30)
                h.textView.performTextFinderAction(NSTextFinder.Action.hideFindInterface.asSenderProbe); await t.spin(30)
            }
            if SelfTest.flag("spell"), let h = t.editor(a) { h.luftigToggleSpellChecking(nil); await t.spin(10); h.luftigToggleSpellChecking(nil) }
            if SelfTest.flag("twice") { let b = try await NSDocumentController.shared.openDocument(withContentsOf: f, display: false).0; t.note("second open returns the same document: \(a === b)") }
            if ext { await t.sh("printf 'x\\n' >> \(t.q(f))"); await t.spin(60) } else { await t.spin(60) }
            a.windowControllers.first?.close()
            let stillRegistered = NSDocumentController.shared.documents.contains(where: { $0 === a })
            t.note("wc.close() #\(i): document still registered with NSDocumentController: \(stillRegistered); window controllers left: \(a.windowControllers.count); isClosed \(a.isClosed)")
            lives.append((live, stillRegistered))
            if stillRegistered { a.updateChangeCount(.changeCleared); a.close() }
        }
        let t0 = now()
        var reported = Set<Int>()
        while now() - t0 < 14_000 {
            await t.spin(500)
            let sec = Int((now() - t0) / 1000)
            if [1, 2, 3, 4, 5, 8, 12].contains(sec), !reported.contains(sec) { reported.insert(sec); t.note("\(sec) s: alive \(lives.map { $0.0.alive.joined(separator: "+").isEmpty ? "-" : $0.0.alive.joined(separator: "+") })") }
        }
    }
}

extension Robust {
    @MainActor static func probeInFlight(_ t: SelfTest.T) async throws {
        NSDocumentController.shared.autosavingDelay = 3
        let variant = SelfTest.argument("v") ?? "a"
        let f = t.url("twice.md")
        try RobustFiles.writeCorpus(f, bytes: 2 << 20, seed: 40)
        let a = try await t.open(f)
        if variant.contains("b") { _ = try await NSDocumentController.shared.openDocument(withContentsOf: f, display: false).0 }
        let live = LiveSet(a)
        var keep: MarkdownDocument?
        if variant.contains("k") { let g = t.url("keep.md"); try RobustFiles.writeCorpus(g, bytes: 100_000, seed: 41); keep = try await t.open(g) }
        if variant.contains("x") { await t.sh("printf 'x\\n' >> \(t.q(f))") }
        await t.spin(variant.contains("s") ? 60 : 1)
        if variant.contains("w") { a.windowControllers.first?.close() }
        if variant.contains("q") || NSDocumentController.shared.documents.contains(where: { $0 === a }) { a.updateChangeCount(.changeCleared); a.close() }
        for sec in [1, 2, 3, 4, 6, 9] {
            _ = await t.waitFor(Double(sec) * 1000) { live.alive.isEmpty }
            t.note("variant \(variant) after \(sec) s: alive \(live.alive)")
            if live.alive.isEmpty { break }
        }
        if variant.contains("n"), !live.alive.isEmpty {
            // does the NEXT document that opens and closes shake the old one loose?
            let g = t.url("next.md"); try RobustFiles.writeCorpus(g, bytes: 100_000, seed: 42)
            let n = try await t.open(g); await t.spin(60); n.windowControllers.first?.close()
            _ = await t.waitFor(4000) { live.alive.isEmpty }
            t.note("after another document was opened and closed: alive \(live.alive)")
        }
        keep.map { t.close($0) }
    }
}

final class SaveWaiterProbe: NSObject {
    var result: Bool?
    @objc func document(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) { result = didSave }
}

private extension NSTextFinder.Action {
    var asSenderProbe: NSMenuItem { let i = NSMenuItem(); i.tag = rawValue; return i }
}
#endif
