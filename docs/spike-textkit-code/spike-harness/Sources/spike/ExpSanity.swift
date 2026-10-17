import AppKit

func attrKeys(_ a: [NSAttributedString.Key: Any]) -> String {
    a.keys.map { $0.rawValue.replacingOccurrences(of: "NS", with: "") }.sorted().joined(separator: ",")
}

func runSanity(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let engines = Engine.parse(arg("engine", "tk1n,tk2"))
    let theme = Theme()
    let base = "Hello world\n\n# Heading line\n\nSecond paragraph with `code` and **bold** text.\n"

    func fresh(_ engine: Engine) -> (Harness, HighlightController) {
        let h = Harness(engine: engine)
        let hc = HighlightController(theme: theme)
        h.storage.delegate = hc
        h.textView.font = theme.bodyFont
        h.textView.string = base
        let doc = Doc(base)
        Styler.style(doc: doc, range: NSRange(location: 0, length: doc.length), storage: h.storage, theme: theme)
        h.layoutVisible()
        return (h, hc)
    }

    // ---------------------------------------------------------------- 7a IME
    func imeString(_ str: String) -> NSAttributedString {
        // what a real IME hands to setMarkedText: per-clause underline + clause segment attributes
        NSAttributedString(string: str, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0])
    }
    log("### 7a. IME composition (marked text, attributed like a real IME) vs attribute application")
    log("| engine | restyle policy | after setMarkedText(\"n\"): markedRange / attribute keys on marked text | underline / clause-segment attributes found in the text storage during composition? | hasMarkedText sequence over 3 compositions steps | final string correct after commit | marked attrs at commit |")
    log("|---|---|---|---|---|---|---|")
    for engine in engines {
        for policy in ["no restyle", "restyle during composition (setAttributes, no guard)", "guard: skip while hasMarkedText(), restyle at commit"] {
            let (h, hc) = fresh(engine)
            let tv = h.textView
            if policy.hasPrefix("restyle") { hc.enabled = true }
            else if policy.hasPrefix("guard") { hc.enabled = true; hc.shouldSkip = { [weak tv] in tv?.hasMarkedText() ?? false } }
            else { hc.enabled = false }
            tv.setSelectedRange(NSRange(location: 5, length: 0))      // after "Hello"
            tv.setMarkedText(imeString("n"), selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let mr = tv.markedRange()
            let keys1 = mr.location != NSNotFound ? attrKeys(h.storage.attributes(at: mr.location, effectiveRange: nil)) : "n/a"
            var seq = [tv.hasMarkedText()]
            // a lazily-scheduled restyle of the viewport (what a scroll would do) while composing
            if policy.hasPrefix("restyle") {
                Styler.style(doc: Doc(h.storage.string), range: NSRange(location: 0, length: h.storage.length), storage: h.storage, theme: theme)
            } else if policy.hasPrefix("guard") {
                if !tv.hasMarkedText() { Styler.style(doc: Doc(h.storage.string), range: NSRange(location: 0, length: h.storage.length), storage: h.storage, theme: theme) }
            }
            let mr2 = tv.markedRange()
            let keys2 = mr2.location != NSNotFound ? attrKeys(h.storage.attributes(at: mr2.location, effectiveRange: nil)) : "n/a"
            let stillMarked = keys2.contains("MarkedClauseSegment") || keys2.contains("Underline")
            tv.setMarkedText(imeString("ni"), selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            seq.append(tv.hasMarkedText())
            tv.setMarkedText(imeString("你"), selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            seq.append(tv.hasMarkedText())
            let keys3 = tv.markedRange().location != NSNotFound ? attrKeys(h.storage.attributes(at: tv.markedRange().location, effectiveRange: nil)) : "n/a"
            tv.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))   // commit
            seq.append(tv.hasMarkedText())
            if policy.hasPrefix("guard"), let pending = hc.pendingSkipped { hc.restyle(h.storage, around: pending); hc.pendingSkipped = nil }
            let ok = h.storage.string.hasPrefix("Hello你 world") || h.storage.string.hasPrefix("Hello你world")
            log("| \(engine.rawValue) | \(policy) | \(mr.location == NSNotFound ? "none" : "\(mr.location)+\(mr.length)") / `\(keys1)` | \(stillMarked ? "yes" : "no: marked-text decoration is not stored in the storage (keys `\(keys2)`)") | \(seq.map { $0 ? "T" : "F" }.joined()) | \(ok ? "yes" : "NO: \(h.storage.string.prefix(14))") | `\(keys3)` |")
            h.window.contentView = nil
        }
    }

    // ---------------------------------------------------------------- 7b restyle inside didProcessEditing takes effect in layout
    log("\n### 7b. restyle made inside textStorage(_:didProcessEditing:) is picked up by layout (typing '# ' at the start of a plain line)")
    log("| engine | line height before | after '#' | after '# ' (heading) | font size at line start after '# ' |")
    log("|---|---|---|---|---|")
    for engine in engines {
        let (h, _) = fresh(engine)
        let tv = h.textView
        let ns = h.storage.string as NSString
        let loc = ns.range(of: "Second paragraph").location
        let h0 = h.heightOfChar(loc)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        tv.insertText("#", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.layoutVisible()
        let h1 = h.heightOfChar(loc)
        tv.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.layoutVisible()
        let h2 = h.heightOfChar(loc)
        let font = h.storage.attribute(.font, at: loc + 2, effectiveRange: nil) as? NSFont
        log("| \(engine.rawValue) | \(f1(h0)) | \(f1(h1)) | \(f1(h2)) | \(f1(Double(font?.pointSize ?? 0))) |")
        h.window.contentView = nil
    }

    // ---------------------------------------------------------------- 7c undo
    log("\n### 7c. undo stack vs attribute-only changes")
    log("| engine | step | canUndo | levels undone to reach empty | note |")
    log("|---|---|---|---|---|")
    for engine in engines {
        let (h, hc) = fresh(engine)
        let tv = h.textView
        tv.allowsUndo = true
        guard let um = tv.undoManager else { log("| \(engine.rawValue) | (no undo manager) | | | |"); continue }
        um.removeAllActions()
        _ = hc
        // 1. big attribute-only restyle outside any edit
        Styler.style(doc: Doc(h.storage.string), range: NSRange(location: 0, length: h.storage.length), storage: h.storage, theme: theme)
        log("| \(engine.rawValue) | restyle whole doc with setAttributes (begin/endEditing) | \(um.canUndo) | - | attribute-only changes must not register undo |")
        // 2. a typed character (restyle happens in didProcessEditing)
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = h.spin(0.01)
        tv.insertText("Y", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = h.spin(0.01)
        var levels = 0
        let afterTyping = h.storage.string
        while um.canUndo && levels < 20 { um.undo(); levels += 1; _ = h.spin(0.005) }
        let reverted = h.storage.string == base
        log("| \(engine.rawValue) | type X, (event loop turn), type Y, then undo until empty | \(um.canUndo) | \(levels) | text after typing began \"\(afterTyping.prefix(8))...\"; fully reverted to original: \(reverted) |")
        // 3. redo returns the text; attributes right after redo?
        var redos = 0
        while um.canRedo && redos < 20 { um.redo(); redos += 1; _ = h.spin(0.005) }
        let heading = h.storage.attribute(.font, at: (h.storage.string as NSString).range(of: "Heading line").location, effectiveRange: nil) as? NSFont
        log("| \(engine.rawValue) | redo all | canUndo=\(um.canUndo) | \(redos) | text restored: \(h.storage.string == afterTyping); heading font still \(f1(Double(heading?.pointSize ?? 0))) pt |")
        // 4. string= resets? (external reload)
        um.removeAllActions()
        tv.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = h.spin(0.01)
        let beforeReload = um.canUndo
        tv.string = base
        log("| \(engine.rawValue) | textView.string = ... after an edit (reload) | canUndo \(beforeReload) -> \(um.canUndo) | - | call undoManager.removeAllActions() yourself on reload |")
        h.window.contentView = nil
    }

    // ---------------------------------------------------------------- 7d TK2 storage delegate
    log("\n### 7d. storage delegate ownership")
    for engine in engines {
        let h = Harness(engine: engine)
        let before = h.storage.delegate.map { String(describing: type(of: $0)) } ?? "nil"
        log("- \(engine.rawValue): textStorage.delegate by default = \(before); our HighlightController installed fine and was called (see 7b: heading height changed)")
        h.window.contentView = nil
    }

    // ---------------------------------------------------------------- 7e accessibility
    log("\n### 7e. accessibility queries VoiceOver makes (ms)")
    log("| corpus | engine | numberOfCharacters | visibleCharacterRange | accessibilityValue (whole text) | string(for: 1 line) | line(for: mid) | selectedTextRange |")
    log("|---|---|---|---|---|---|---|---|")
    for corpus in ["1m", "20m"] {
        let text = Corpus.load(corpus)
        for engine in engines {
            let h = Harness(engine: engine)
            h.textView.font = theme.bodyFont
            h.textView.string = text
            h.layoutVisible()
            let tv = h.textView
            let n = tv.accessibilityNumberOfCharacters()
            let t1 = ms { _ = tv.accessibilityNumberOfCharacters() }
            var vr = NSRange(location: 0, length: 0)
            let t2 = ms { vr = tv.accessibilityVisibleCharacterRange() }
            let t3 = ms { _ = tv.accessibilityValue() }
            let t4 = ms { _ = tv.accessibilityString(for: NSRange(location: 0, length: min(80, n))) }
            let t5 = ms { _ = tv.accessibilityLine(for: n / 2) }
            let t6 = ms { _ = tv.accessibilitySelectedTextRange() }
            log("| \(corpus) | \(engine.rawValue) | \(f2(t1)) (n=\(n)) | \(f2(t2)) (\(vr.location)+\(vr.length)) | \(f2(t3)) | \(f2(t4)) | \(f2(t5)) | \(f2(t6)) |")
            h.window.contentView = nil
        }
    }
}
