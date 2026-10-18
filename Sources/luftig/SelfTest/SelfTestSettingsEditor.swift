#if LUFTIG_SELFTEST
// SelfTestSettingsEditor.swift - what the Settings do to the EDITORS: settings-apply, settings-oracle, settings-lineboxes, settings-faces, settings-perf.

import AppKit
import MarkdownKit

extension SelfTestScenarios {

    // MARK: settings-apply

    @MainActor static func settingsApply(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let P = EditorPreferences.self
            let text = settingsDocument(times: 14)               // ~1000 lines: the end of it is never styled or laid out while the top is on screen
            let (docA, a, _) = try await openEditor(t, text: text, name: "sa-a.md", size: NSSize(width: 1400, height: 700))
            let (docB, b, _) = try await openEditor(t, text: text, name: "sa-b.md", size: NSSize(width: 1400, height: 700))
            let hosts = [("A", a), ("B", b)]
            let body = installedFamilies(["Georgia", "Times", "Helvetica Neue"]).first ?? anyFamily() ?? "Helvetica"
            let code = installedFamilies(["Menlo", "Courier New", "Monaco"]).first ?? anyFamily(not: [body], monospaced: true) ?? "Courier"
            t.note("body family \(body), code family \(code)")
            let farLoc = (text as NSString).length - 300          // far below the viewport
            let nearText = "A paragraph with"
            @MainActor func fontAt(_ host: EditorViewController, _ needle: String) -> NSFont? {
                let r = ns(host.textView).range(of: needle)
                return r.location == NSNotFound ? nil : t.fontOf(host.textView, at: r.location + 2)
            }
            @MainActor func paragraphHeight(_ host: EditorViewController, at loc: Int) -> (CGFloat, CGFloat)? {
                guard let p = host.textView.textStorage?.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle else { return nil }
                return (p.minimumLineHeight, p.maximumLineHeight)
            }
            t.check(!a.styler.styled.contains(farLoc), "set-up: the far end of the document is not styled")
            let startSelection = NSRange(location: ns(a.textView).range(of: nearText).location + 4, length: 5)
            a.textView.setSelectedRange(startSelection)

            // ---- text font
            P.bodyFontFamily = body
            for (name, host) in hosts {
                t.equal(host.theme.bodyFamily, body, "text font: window \(name) uses \(body)")
                t.equal(host.theme.settings, P.themeSettings, "text font: window \(name)'s theme was built from the preferences")
                t.equal(fontAt(host, nearText)?.familyName, body, "text font: styled body text of \(name) is set in \(body)")
                t.equal(t.fontOf(host.textView, at: farLoc)?.familyName, body, "text font: NOT yet styled text of \(name) has it too (base attributes)")
                t.check(fontAt(host, "Heading one")?.familyName == body, "text font: headings of \(name) use the family (bold face)")
                t.check(fontAt(host, "inline code")?.isFixedPitch == true, "text font: inline code of \(name) is still the (system) code font")
            }
            t.equal(a.textView.string, text, "the text is untouched by a font change")
            t.equal(a.textView.selectedRange(), startSelection, "the selection survives a font change")

            // ---- code font
            P.codeFontFamily = code
            for (name, host) in hosts {
                t.equal(host.theme.codeFamily, code, "code font: window \(name) uses \(code)")
                t.equal(fontAt(host, "inline code")?.familyName, code, "code font: inline code of \(name) is set in \(code)")
                t.equal(fontAt(host, "let x = 1")?.familyName, code, "code font: code blocks of \(name) too")
                t.equal(fontAt(host, "| 1 |")?.familyName, code, "code font: tables of \(name) too")
                t.equal(t.fontOf(host.textView, at: ns(host.textView).range(of: "title: Sample").location)?.familyName, code, "code font: front matter of \(name) too")
                t.equal(fontAt(host, nearText)?.familyName, body, "code font: body text keeps the text font")
                let font = host.theme.monoFont
                let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
                t.equal(host.theme.monoAdvance, advance, "code font: the mono advance of \(name) comes from \(code) (\(advance) pt)")
                let tab = host.textView.textStorage?.attribute(.paragraphStyle, at: ns(host.textView).range(of: "let x = 1").location, effectiveRange: nil) as? NSParagraphStyle
                t.equal(tab?.defaultTabInterval, advance * 4, "code font: a tab in code is 4 columns of \(code) (\(advance * 4) pt)")
            }

            // ---- size
            P.fontSize = 20
            for (name, host) in hosts {
                t.equal(host.fontSize, 20, "size: window \(name) is at 20 pt")
                t.equal(fontAt(host, nearText)?.pointSize, 20, "size: body text of \(name) is 20 pt")
                t.equal(fontAt(host, nearText)?.familyName, body, "size: ... and still \(body)")
                t.equal(fontAt(host, "Heading one")?.pointSize, host.theme.headingSize(1), "size: H1 keeps its ratio (\(host.theme.headingSize(1)) pt)")
                t.equal(fontAt(host, "inline code")?.pointSize, host.theme.monoSize, "size: code is 0.9 x (\(host.theme.monoSize) pt)")
            }

            // ---- line spacing
            P.lineHeightFactor = 1.8
            for (name, host) in hosts {
                let expected = max((20 * 1.8 as CGFloat).rounded(), host.theme.bodyLineHeight)
                t.equal(host.theme.bodyLineHeight, expected, "line spacing: body line box of \(name) = round(20 x 1.8) = \(expected) pt")
                let near = ns(host.textView).range(of: nearText).location
                t.equal(paragraphHeight(host, at: near)?.0, host.theme.bodyLineHeight, "line spacing: styled text of \(name) has the box (min)")
                t.equal(paragraphHeight(host, at: near)?.1, host.theme.bodyLineHeight, "line spacing: ... uniform (max == min)")
                t.equal(paragraphHeight(host, at: farLoc)?.0, host.theme.bodyLineHeight, "line spacing: NOT yet styled text of \(name) has it too")
                t.equal(paragraphHeight(host, at: ns(host.textView).range(of: "Heading one").location)?.0, host.theme.lineHeight(headingLevel: 1), "line spacing: headings keep their own rule (\(host.theme.lineHeight(headingLevel: 1)) pt)")
                assertMatchesFreshLex(t, host, range: visibleRange(host), "line spacing: window \(name) visible part == fresh Theme(settings) + lex")
            }

            // the line at the top of the window stays at the top while the line box changes (every line below it moves)
            let mid = ns(a.textView).range(of: "# Heading one with `code`", options: [], range: NSRange(location: ns(a.textView).length / 2, length: 3000)).location
            t.scrollToTop(a, character: mid)
            let anchorBefore = ViewportAnchor.capture(in: a.textView)
            P.lineHeightFactor = 1.3
            P.lineHeightFactor = 1.8
            P.fontSize = 22
            P.fontSize = 20
            if let before = anchorBefore, let after = ViewportAnchor.capture(in: a.textView) {
                t.check(abs(before.characterIndex - after.characterIndex) < 400, "the text at the top of the window stays at the top (char \(before.characterIndex) -> \(after.characterIndex))")
            } else { t.check(false, "no anchor") }
            t.equal(a.textView.string, text, "the text is untouched by all of it")
            t.equal(a.textView.selectedRange(), startSelection, "the selection survives all of it")
            t.scrollToTop(a, character: 0)

            // ---- column width (the windows are 1400 pt wide)
            P.readableWidth = true
            P.columnWidth = 600
            for (name, host) in hosts {
                let tv = host.textView
                host.view.window?.contentView?.layoutSubtreeIfNeeded()
                t.check(abs(tv.textContainer!.size.width - 600) < 1.5, "column width: the text column of \(name) is \(Int(tv.textContainer!.size.width)) pt (600 expected)")
                t.check(abs(tv.textContainerInset.width - ((host.scrollView.contentView.bounds.width - CGFloat(0) - 600) / 2).rounded(.down)) < 1.5, "column width: ... centred in the clip view minus the right-hand extra (inset \(Int(tv.textContainerInset.width)) pt, extra \(Int(CGFloat(0))))")
            }
            P.columnWidth = 1000                   // (a 1400 pt window minus the outline, the scroller, the window frame and the insets holds about 1060 pt of column)
            for (name, host) in hosts { t.check(abs(host.textView.textContainer!.size.width - 1000) < 1.5, "column width: widened to \(Int(host.textView.textContainer!.size.width)) pt in \(name)") }
            P.readableWidth = false
            for (name, host) in hosts {           // (the outline on the left takes its 220 pt first: the text fills the text area, not the window)
                let area = host.scrollView.contentView.bounds.width
                let extra = CGFloat(0)
                let inset = host.padding.textInsetHorizontal
                t.check(host.textView.textContainerInset.width == inset && abs(host.textView.textContainer!.size.width - (area - 2 * inset - extra)) < 1.5 && area > 1000, "column off: \(name) uses the whole text area (\(Int(host.textView.textContainer!.size.width)) of \(Int(area)) pt, inset \(Int(inset)))")
            }
            P.readableWidth = true
            for (name, host) in hosts { t.check(abs(host.textView.textContainer!.size.width - 1000) < 1.5, "column on again: \(name) back to 1000 pt") }

            // ---- a window opened later starts with all of it
            let (docC, c, _) = try await openEditor(t, text: "# Title\n\nbody `code`\n", name: "sa-c.md", size: NSSize(width: 1400, height: 700))
            t.equal(c.theme.settings, P.themeSettings, "a window opened later is built from the preferences (\(c.theme.settings))")
            t.equal(t.fontOf(c.textView, at: 12)?.familyName, body, "... its body text is set in \(body)")
            t.equal(c.theme.bodyLineHeight, a.theme.bodyLineHeight, "... with the same line box")
            c.view.window?.contentView?.layoutSubtreeIfNeeded()
            t.check(abs(c.textView.textContainer!.size.width - 1000) < 1.5, "... and the same column (\(Int(c.textView.textContainer!.size.width)) pt)")

            // ---- nothing is rebuilt that does not need it
            let themeA = a.theme, runsA = a.styler.appliedRunCount
            P.columnWidth = 900
            P.readableWidth = false
            P.readableWidth = true
            NotificationCenter.default.post(name: EditorPreferences.didChange, object: nil)
            t.check(a.theme === themeA && a.provider.theme === themeA, "column width / the column flag / a notification without a change rebuild no Theme")
            t.equal(a.styler.appliedRunCount, runsA, "... and restyle nothing")
            P.lineHeightFactor = 1.8
            t.check(a.theme === themeA, "setting the value it already has rebuilds nothing")
            P.lineHeightFactor = 1.6
            t.check(a.theme !== themeA && a.theme.settings.lineHeightFactor == 1.6, "a changed line spacing does")

            // ---- colour scheme: the theme is rebuilt, a scheme that is always dark / light forces the window's appearance, the system scheme gives it back
            let dark = ColorSchemes.all.first { $0.appearance == .dark }, light = ColorSchemes.all.first { $0.appearance == .light }
            for (label, scheme, expected) in [("dark", dark, NSAppearance.Name.darkAqua), ("light", light, .aqua)] {
                guard let scheme else { t.note("no \(label) scheme in this build: skipped"); continue }
                let before = a.theme
                P.colorSchemeID = scheme.id
                for (name, host) in hosts + [("C", c)] {
                    t.check(host.theme !== before || name == "C", "scheme \(scheme.id): the theme of \(name) was rebuilt (its attribute dictionaries hold the colours)")
                    t.equal(host.view.window?.appearance?.name, expected, "scheme \(scheme.id) (\(label)): the window of \(name) is forced to \(expected.rawValue)")
                    t.check(host.textView.backgroundColor == Palette.background && host.scrollView.backgroundColor == Palette.background, "scheme \(scheme.id): the page colour of \(name) is the palette's")
                }
                assertMatchesFreshLex(t, a, range: visibleRange(a), "scheme \(scheme.id): visible text == fresh restyle")
                P.colorSchemeID = ColorSchemes.defaultID
                for (name, host) in hosts + [("C", c)] { t.check(host.view.window?.appearance == nil, "back to the system scheme: the window of \(name) follows the system again") }
            }

            // ---- restore defaults: every window is back to the default look
            P.restoreDefaults()
            for (name, host) in hosts + [("C", c)] {
                t.equal(host.theme.settings, ThemeSettings(baseSize: 16), "restore defaults: window \(name) is built from the default settings")
                t.equal(host.fontSize, 16, "restore defaults: size 16 in \(name)")
            }
            for d in [docA, docB, docC] { t.close(d) }
        }
    }

    // MARK: settings-oracle

    @MainActor static func settingsOracle(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let P = EditorPreferences.self
            P.bodyFontFamily = installedFamilies(["Georgia", "Times", "Helvetica Neue"]).first ?? anyFamily()
            P.codeFontFamily = installedFamilies(["Menlo", "Courier New", "Monaco"]).first
            P.fontSize = 18
            P.lineHeightFactor = 1.7
            t.note("settings under test: \(P.themeSettings)")
            try await differentialRun(t, label: "non-default family, factor and size", maxEditRegion: 60_000, seed: 31, edits: 700)
            // the same with the settings changing under the user's hands (every ~140 edits: a size, a family, a factor, the column)
            try await differentialRun(t, label: "settings churn", maxEditRegion: 8_000, seed: 47, edits: 700, settingsChurn: true)
        }
    }

    /// One of the settings, changed at random (used while a differential run types and scrolls).
    @MainActor static func churnSettings(_ rng: inout TestRNG) {
        let P = EditorPreferences.self
        switch rng.int(6) {
        case 0: P.fontSize = CGFloat(11 + rng.int(14))
        case 1: P.lineHeightFactor = rng.chance(25) ? nil : CGFloat(1.1 + Double(rng.int(10)) / 10)
        case 2: P.bodyFontFamily = rng.pick([nil, "Georgia", "Times", "Helvetica Neue", "Avenir Next", "Zapfino", "Menlo"].filter { $0 == nil || FontFactory.resolve($0) != nil })
        case 3: P.codeFontFamily = rng.pick([nil, "Menlo", "Courier New", "Monaco"].filter { $0 == nil || FontFactory.resolve($0) != nil })
        case 4: P.columnWidth = CGFloat(500 + rng.int(800))
        default: P.readableWidth.toggle()
        }
    }

    // MARK: settings-lineboxes

    @MainActor static func settingsLineBoxes(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let P = EditorPreferences.self
            let bodies: [String?] = [nil] + installedFamilies(["Helvetica Neue", "Georgia", "Times", "Avenir Next", "Hoefler Text", "Menlo", "Courier New", "Monaco", "Zapfino", "Papyrus", "Apple Symbols", "Palatino", "Optima"])
            let codes: [String?] = [nil] + installedFamilies(["Menlo", "Courier New", "Monaco"])
            t.note("families under test (\(bodies.count)): \(bodies.map { $0 ?? "System" }.joined(separator: ", "))")
            t.check(bodies.count >= 10, "at least ten different families are installed for this test (\(bodies.count))")
            t.check(bodies.contains("Zapfino") || bodies.count < 10, "a tall family (Zapfino) is among them: \(bodies.contains("Zapfino"))")
            t.check(bodies.contains("Menlo") || bodies.count < 10, "a monospaced family (Menlo) is among them: \(bodies.contains("Menlo"))")
            let (doc, host, _) = try await openEditor(t, text: settingsDocument(times: 1), name: "lb.md", size: NSSize(width: 900, height: 2400))
            let tv = host.textView, ts = tv.textStorage!, lm = tv.layoutManager!
            var combos = 0, lines = 0, raised = 0
            var leadingExtra: CGFloat = 0
            var worst: [String] = []
            for (i, body) in bodies.enumerated() {
                for factor in [1.1, 1.5, 2.0] as [CGFloat] {
                    for size in [12, 16, 26] as [CGFloat] {
                        P.bodyFontFamily = body
                        P.codeFontFamily = codes[(i + Int(size)) % codes.count]
                        P.lineHeightFactor = factor
                        P.fontSize = size
                        host.styler.styleEverything()
                        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: ts.length))
                        let theme = host.theme
                        let label = "\(body ?? "System") / \(P.codeFontFamily ?? "System Mono") \(Int(size)) pt x \(factor)"
                        combos += 1
                        if theme.settings != P.themeSettings { worst.append("\(label): the editor's theme is not the preference's") }
                        let requested = (size * factor).rounded()
                        if theme.bodyLineHeight < requested { worst.append("\(label): body box \(theme.bodyLineHeight) < what the factor asks (\(requested))") }
                        if theme.bodyLineHeight > requested { raised += 1 }
                        if !(theme.lineHeight(headingLevel: 1) >= theme.lineHeight(headingLevel: 2) && theme.lineHeight(headingLevel: 2) >= theme.lineHeight(headingLevel: 3) && theme.lineHeight(headingLevel: 3) >= theme.lineHeight(headingLevel: 4) && theme.lineHeight(headingLevel: 4) >= theme.bodyLineHeight) {
                            worst.append("\(label): heading boxes are not ordered H1 >= H2 >= H3 >= H4 >= body")
                        }
                        let allowed = Set<CGFloat>([theme.bodyLineHeight] + (1...6).map { theme.lineHeight(headingLevel: $0) })
                        let slack = 0.03 * size + 0.1
                        var seenSizes = Set<CGFloat>()
                        let okSizes = Set<CGFloat>([theme.baseSize, theme.monoSize] + (1...6).flatMap { [theme.headingSize($0), (theme.headingSize($0) * 0.9 * 2).rounded() / 2] })
                        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, used, _, glyphs, _ in
                            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                            guard chars.location < ts.length, let p = ts.attribute(.paragraphStyle, at: chars.location, effectiveRange: nil) as? NSParagraphStyle else { return }
                            lines += 1
                            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                            // the fonts of the glyphs the line shows: its line break carries the font of the run it ends (the underline of a setext heading ends in the
                            // heading's font) but draws nothing and is held to the line's fixed box like everything else
                            var inked = chars
                            while inked.length > 0, [0x0A, 0x0D].contains((ts.string as NSString).character(at: NSMaxRange(inked) - 1)) { inked.length -= 1 }
                            ts.enumerateAttribute(.font, in: inked, options: []) { v, _, _ in
                                if let f = v as? NSFont { ascent = max(ascent, f.ascender); descent = max(descent, -f.descender); seenSizes.insert(f.pointSize) }
                            }
                            ts.enumerateAttribute(.font, in: chars, options: []) { v, _, _ in if let f = v as? NSFont { leading = max(leading, f.leading) } }
                            leadingExtra = max(leadingExtra, leading)
                            let natural = ascent + descent          // the tallest ascender + the deepest descender: the fonts of a line share one baseline
                            if p.minimumLineHeight != p.maximumLineHeight { worst.append("\(label): line at \(chars.location): min \(p.minimumLineHeight) != max \(p.maximumLineHeight)") }
                            if !allowed.contains(p.minimumLineHeight) { worst.append("\(label): line at \(chars.location): box \(p.minimumLineHeight) is neither the body nor a heading box \(allowed.sorted())") }
                            if p.minimumLineHeight < natural - 0.001 { worst.append("\(label): line at \(chars.location): box \(p.minimumLineHeight) < the fonts' natural height \(natural)") }
                            // TextKit 1 adds the font's own LEADING on top of the fixed box (Helvetica Neue 3 % of its size, Monaco 5-8 %: measured, used = box + leading to the last digit);
                            // the system fonts have none, which is why the default look is exactly uniform
                            if used.height < p.minimumLineHeight - 0.01 || used.height > p.minimumLineHeight + leading + slack { worst.append("\(label): line at \(chars.location): used \(used.height) vs box \(p.minimumLineHeight) (+ leading \(leading))") }
                            _ = rect
                        }
                        let stray = seenSizes.subtracting(okSizes)
                        if !stray.isEmpty { worst.append("\(label): fonts of the wrong size \(stray.sorted()) (allowed \(okSizes.sorted()))") }
                    }
                }
            }
            t.note("\(combos) combinations, \(lines) line fragments measured, the box had to be raised above size x factor in \(raised) combinations; the largest font leading TextKit added on top of a box: \(String(format: "%.2f", Double(leadingExtra))) pt")
            t.check(worst.isEmpty, "every line box is uniform (min == max), one of the theme's boxes, never smaller than the natural height of its fonts, and every font has the size the theme asked for\(worst.isEmpty ? "" : ": \(worst.prefix(6))")")
            t.check(raised > 0, "the floor is exercised (tall fonts / low factors were raised: \(raised) combinations)")
            // the automatic default is unchanged by the floor
            P.restoreDefaults()
            t.equal(host.theme.bodyLineHeight, (16 * Theme.lineHeightRatio(baseSize: 16)).rounded(), "default settings: the body box is round(16 x \(Theme.lineHeightRatio(baseSize: 16))) = \((16 * Theme.lineHeightRatio(baseSize: 16)).rounded()) pt (the floor does not touch it)")
            for size in stride(from: 9, through: 40, by: 1) {
                let th = Theme(baseSize: CGFloat(size))
                if th.bodyLineHeight != (CGFloat(size) * Theme.lineHeightRatio(baseSize: CGFloat(size))).rounded() { t.check(false, "default look at \(size) pt: the body box moved to \(th.bodyLineHeight)") }
            }
            t.close(doc)
        }
    }

    // MARK: settings-faces

    @MainActor static func settingsFaces(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let P = EditorPreferences.self
            let ud = UserDefaults.standard
            let text = "Plain *italic words* and **bold words** and `code` here.\n\n```\nfenced\n```\n"
            let (doc, host, _) = try await openEditor(t, text: text, name: "faces.md", size: NSSize(width: 900, height: 500))
            let tv = host.textView, ts = tv.textStorage!
            @MainActor func attrs(_ needle: String) -> [NSAttributedString.Key: Any] { ts.attributes(at: ns(tv).range(of: needle).location, effectiveRange: nil) }
            func traits(_ f: NSFont) -> NSFontTraitMask { NSFontManager.shared.traits(of: f) }
            @MainActor func apply(_ body: String?, _ codeFamily: String? = nil) { P.bodyFontFamily = body; P.codeFontFamily = codeFamily; host.styler.styleEverything() }

            // ---- the system fonts: real italic / bold, no tricks (the attributes are exactly what they always were)
            apply(nil)
            for needle in ["italic words", "bold words", "Plain", "code", "fenced"] {
                let a = attrs(needle)
                t.check(a[.obliqueness] == nil && a[.strokeWidth] == nil, "system fonts: '\(needle)' carries no synthetic slant / stroke")
            }
            t.check(traits(attrs("italic words")[.font] as! NSFont).contains(.italicFontMask) && traits(attrs("bold words")[.font] as! NSFont).contains(.boldFontMask), "system fonts: italic is a real italic, bold a real bold")

            // ---- a family with all four faces (Menlo as the code font, Georgia as the text font): real faces, no tricks
            if let georgia = installedFamilies(["Georgia", "Times"]).first {
                apply(georgia)
                let it = attrs("italic words"), bd = attrs("bold words")
                t.check(traits(it[.font] as! NSFont).contains(.italicFontMask) && it[.obliqueness] == nil, "\(georgia): italic is the family's own italic face (no synthetic slant)")
                t.check(traits(bd[.font] as! NSFont).contains(.boldFontMask) && bd[.strokeWidth] == nil, "\(georgia): bold is the family's own bold face (no synthetic stroke)")
                t.equal((it[.font] as! NSFont).familyName, georgia, "\(georgia): the italic face is of the same family")
            }

            // ---- families that lack faces: Papyrus (no italic, no bold), Zapfino, Monaco (regular only)
            for family in installedFamilies(["Papyrus", "Zapfino", "Monaco", "Apple Symbols"]) {
                apply(family, nil)
                let it = attrs("italic words"), bd = attrs("bold words"), pl = attrs("Plain")
                let itFont = it[.font] as! NSFont, bdFont = bd[.font] as! NSFont
                let hasItalic = traits(itFont).contains(.italicFontMask), hasBold = NSFontManager.shared.weight(of: bdFont) >= 8
                t.equal(itFont.pointSize, host.theme.baseSize, "\(family): the italic run has the right size (\(itFont.pointSize))")
                t.equal(bdFont.pointSize, host.theme.baseSize, "\(family): the bold run has the right size (\(bdFont.pointSize))")
                t.check(hasItalic || (it[.obliqueness] as? NSNumber)?.doubleValue == FontFace.obliqueness, "\(family): italic is a real italic face (\(hasItalic)) or slanted by .obliqueness \(FontFace.obliqueness)")
                t.check(hasBold || ((bd[.strokeWidth] as? NSNumber)?.doubleValue ?? 0) < 0, "\(family): bold is a real bold face (\(hasBold)) or stroked by a negative .strokeWidth (\(String(describing: bd[.strokeWidth])))")
                t.check(pl[.obliqueness] == nil && pl[.strokeWidth] == nil, "\(family): plain text is neither slanted nor stroked")
                assertMatchesFreshLex(t, host, "\(family): the whole document == a fresh Theme + lex (the synthetic attributes are part of it)")
            }
            if installedFamilies(["Papyrus"]).first != nil {
                apply("Papyrus")
                t.equal((attrs("italic words")[.obliqueness] as? NSNumber)?.doubleValue, FontFace.obliqueness, "Papyrus has no italic: the run is slanted synthetically")
            }
            if installedFamilies(["Zapfino"]).first != nil {
                apply("Zapfino")
                t.check(((attrs("bold words")[.strokeWidth] as? NSNumber)?.doubleValue ?? 0) == FontFace.boldStroke, "Zapfino has no bold: the run is stroked (\(FontFace.boldStroke))")
            }

            // ---- a family that is NOT installed: the system font, the right size, and the saved name is NOT overwritten
            let ghost = "Ghost Family 4711"
            t.check(FontFactory.resolve(ghost) == nil, "set-up: '\(ghost)' is not installed")
            P.codeFontFamily = "Ghost Mono 4711"
            apply(ghost, "Ghost Mono 4711")
            t.equal(P.bodyFontFamily, ghost, "not installed: the saved text font is still \"\(ghost)\" after the window restyled")
            t.equal(host.theme.bodyFamily, nil, "not installed: the theme resolves it to the system font")
            t.equal(host.theme.settings.bodyFamily, ghost, "... but keeps the name in its settings")
            let plain = attrs("Plain")[.font] as! NSFont
            t.check(plain.fontName == NSFont.systemFont(ofSize: host.theme.baseSize).fontName && plain.pointSize == host.theme.baseSize, "not installed: body text is the system font at \(plain.pointSize) pt (\(plain.fontName))")
            let mono = attrs("fenced")[.font] as! NSFont
            t.check(mono.isFixedPitch && mono.pointSize == host.theme.monoSize && mono.familyName != "Ghost Mono 4711", "not installed: code is the system monospaced font at \(mono.pointSize) pt (\(mono.fontName))")
            P.fontSize = 22
            P.lineHeightFactor = 1.4
            P.columnWidth = 900
            host.styler.styleEverything()
            t.equal(ud.string(forKey: P.bodyFontFamilyKey), ghost, "not installed: changing size, spacing and column leaves the saved text font alone")
            t.equal(ud.string(forKey: P.codeFontFamilyKey), "Ghost Mono 4711", "not installed: ... and the saved code font")
            t.equal((attrs("Plain")[.font] as! NSFont).pointSize, 22, "not installed: the size change still applies (22 pt)")
            // a second window opens with it, too
            let (doc2, h2, _) = try await openEditor(t, text: text, name: "faces2.md", size: NSSize(width: 900, height: 500))
            t.equal((h2.textView.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 22, "not installed: a window opened later starts at the saved size with the system font")
            t.equal(ud.string(forKey: P.bodyFontFamilyKey), ghost, "not installed: opening a window leaves the saved name alone")
            t.close(doc2)
            // the family comes back when it is chosen again: the Theme is the real thing
            apply(installedFamilies(["Georgia", "Times"]).first)
            t.check(host.theme.bodyFamily != nil, "choosing an installed family again works")
            t.close(doc)
        }
    }

    // MARK: settings-perf

    @MainActor static func settingsPerf(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let P = EditorPreferences.self
            let load = PerfLab.loadAverage(), cores = Double(PerfLab.cores)
            t.note(String(format: "load average %.2f on %d cores", load, PerfLab.cores))
            let busy = load > cores / 2
            @MainActor func check(_ ok: Bool, _ msg: String) { if busy && !ok { t.note("SKIPPED under load (\(String(format: "%.1f", load))): \(msg)") } else { t.check(ok, msg) } }
            let body = installedFamilies(["Georgia", "Times", "Helvetica Neue"]).first, code = installedFamilies(["Menlo", "Courier New"]).first

            // ---- the Settings window itself: first use (the lists of installed fonts, the preview, the controls, one layout pass) and the font menus
            SettingsWindowController.headless = true
            let tCreate = SelfTest.nowMs()
            let controller = SettingsWindowController.shared
            let createMs = SelfTest.nowMs() - tCreate
            let tTitles = SelfTest.nowMs()
            controller.applyFontTitles(controller.bodyFontPopup.menu!)
            controller.applyFontTitles(controller.codeFontPopup.menu!)
            let titlesMs = SelfTest.nowMs() - tTitles
            let tPresent = SelfTest.nowMs()
            controller.present()
            let presentMs = SelfTest.nowMs() - tPresent
            t.note(String(format: "Settings window: first use %.1f ms (%d text families, %d monospaced), both font menus in their own typefaces %.1f ms, present() %.2f ms", createMs, controller.textFamilies.count, controller.codeFamilies.count, titlesMs, presentMs))
            check(createMs < 400 && titlesMs < 400 && presentMs < 50, String(format: "the Settings window is quick: created in %.1f ms (< 400), menus titled in %.1f ms (< 400), presented in %.2f ms (< 50)", createMs, titlesMs, presentMs))

            // ---- what building a Theme costs (it happens at every window and at every settings change): the first one of a process (fonts not built yet) and warm
            let tTheme0 = SelfTest.nowMs()
            _ = Theme(settings: ThemeSettings(baseSize: 16, bodyFamily: body, codeFamily: code, lineHeightFactor: 1.7))
            let themeColdMs = SelfTest.nowMs() - tTheme0
            var warmThemes: [Double] = []
            for i in 0..<20 {
                let t1 = SelfTest.nowMs()
                _ = Theme(settings: ThemeSettings(baseSize: 14 + CGFloat(i % 5), bodyFamily: i % 2 == 0 ? body : nil, codeFamily: i % 2 == 0 ? code : nil, lineHeightFactor: nil))
                warmThemes.append(SelfTest.nowMs() - t1)
            }
            t.note(String(format: "Theme(settings:): first with %@ / %@ %.2f ms, then median of 20 (new sizes / system and named families) %.2f ms", body ?? "System", code ?? "System Mono", themeColdMs, median(warmThemes)))
            check(themeColdMs < 50 && median(warmThemes) < 10, String(format: "building a Theme is cheap: first %.2f ms < 50, median %.2f ms < 10", themeColdMs, median(warmThemes)))
            let tApply = SelfTest.nowMs()
            Palette.apply(schemeID: "dracula")
            let applyColdMs = SelfTest.nowMs() - tApply
            Palette.apply(schemeID: ColorSchemes.defaultID)
            t.note(String(format: "Palette.apply of a scheme that was never built: %.2f ms", applyColdMs))

            // ---- open a 1 MB document with non-default settings: warm median of 7, budget 100 ms (DESIGN.md)
            let src = t.corpusFile(bytes: 1_000_000)
            @MainActor func openMedian(_ label: String) async throws -> Double {
                var ms: [Double] = []
                for _ in 0..<7 {
                    let r = try await openOnce(src)
                    ms.append(r.total)
                    r.doc.updateChangeCount(.changeCleared); r.doc.close()
                    await t.sleep(5)
                }
                let med = median(ms)
                t.note(String(format: "%@: open 1 MB, first screen laid out + styled + drawn: median %.1f ms (min %.1f)", label, med, ms.min() ?? 0))
                return med
            }
            let defaultOpen = try await openMedian("default settings")
            P.bodyFontFamily = body; P.codeFontFamily = code; P.fontSize = 19; P.lineHeightFactor = 1.7
            let customOpen = try await openMedian("\(body ?? "System") / \(code ?? "System Mono") 19 pt x 1.7")
            check(customOpen < 100, String(format: "open 1 MB with non-default fonts, size and spacing: %.1f ms < 100 ms (default settings: %.1f ms)", customOpen, defaultOpen))

            // ---- a settings change applied to a 1 MB and a 10 MB document that is open and scrolled
            for (label, bytes, budget) in [("1 MB", 1_000_000, 100.0), ("10 MB", 10_000_000, 400.0)] {
                let copy = t.url("sp-\(bytes).md")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: t.corpusFile(bytes: bytes), to: copy)
                let doc = try await t.open(copy, size: NSSize(width: 900, height: 700))
                guard let host = doc.host as? EditorViewController else { continue }
                t.scrollToTop(host, character: ns(host.textView).length / 2)
                var times: [(String, Double)] = []
                var repaints: [(String, Double)] = []
                // the change, the restyle and layout of what is visible, and the repaint of the window's visible part (cacheDisplay: what the
                // screen would draw; a headless process never displays by itself)
                @MainActor func measure(_ what: String, _ change: () -> Void) {
                    let t0 = SelfTest.nowMs()
                    change()
                    _ = host.textView.layoutManager?.ensureLayout(forBoundingRect: host.textView.visibleRect, in: host.textView.textContainer!)
                    let t1 = SelfTest.nowMs()
                    let sv = host.scrollView
                    if let rep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) { sv.cacheDisplay(in: sv.bounds, to: rep) }
                    times.append((what, SelfTest.nowMs() - t0))
                    repaints.append((what, SelfTest.nowMs() - t1))
                }
                measure("text font") { P.bodyFontFamily = installedFamilies(["Times", "Georgia"]).first }
                measure("code font") { P.codeFontFamily = installedFamilies(["Courier New", "Menlo"]).first }
                measure("size 22") { P.fontSize = 22 }
                measure("line spacing 1.9") { P.lineHeightFactor = 1.9 }
                measure("column 700") { P.columnWidth = 700 }
                measure("column off") { P.readableWidth = false }
                measure("column on") { P.readableWidth = true }
                measure("scheme dracula") { P.colorSchemeID = "dracula" }
                measure("scheme solarized-light") { P.colorSchemeID = "solarized-light" }
                measure("scheme default") { P.colorSchemeID = ColorSchemes.defaultID }
                measure("restore defaults") { P.restoreDefaults() }
                t.note("\(label) document, change applied + visible part restyled + laid out + repainted: " + times.map { "\($0.0) \(String(format: "%.1f", $0.1)) ms" }.joined(separator: ", "))
                t.note("\(label) document, of which the repaint of the visible part: " + repaints.map { "\($0.0) \(String(format: "%.1f", $0.1)) ms" }.joined(separator: ", "))
                for (what, ms) in times { check(ms < budget, String(format: "%@: '%@' takes %.1f ms < %.0f", label, what, ms, budget)) }
                assertMatchesFreshLex(t, host, range: visibleRange(host), "\(label): after the changes the visible part == fresh restyle")
                t.close(doc)
            }

            // ---- typing with non-default settings: the budget of DESIGN.md (8 ms median, p95 < 16 ms) at 200 KB
            P.bodyFontFamily = body; P.codeFontFamily = code; P.fontSize = 19; P.lineHeightFactor = 1.7
            let copy = t.url("sp-typing.md")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: t.corpusFile(bytes: 200_000), to: copy)
            let doc = try await t.open(copy, size: NSSize(width: 900, height: 700))
            guard let host = doc.host as? EditorViewController else { return }
            let tv = host.textView
            t.scrollToTop(host, character: ns(tv).length / 2)
            let vis = visibleRange(host)
            let loc = ns(tv).lineRange(for: NSRange(location: vis.location + min(vis.length / 2, 400), length: 0)).location
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            var real: [Double] = []
            for i in 0..<70 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                t.typeText(i % 11 == 10 ? "#" : "a", into: doc, at: NSRange(location: loc + i, length: 0))
                _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
                var strip = tv.visibleRect
                if let lm = tv.layoutManager {
                    let g = lm.glyphIndexForCharacter(at: min(loc + i, max(0, lm.numberOfGlyphs - 1)))
                    let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).offsetBy(dx: 0, dy: tv.textContainerOrigin.y)
                    strip = NSRect(x: 0, y: r.minY - r.height, width: tv.bounds.width, height: r.height * 3).intersection(tv.visibleRect)
                }
                let stripInScroll = host.scrollView.convert(strip, from: tv)
                if let rep = host.scrollView.bitmapImageRepForCachingDisplay(in: stripInScroll) { host.scrollView.cacheDisplay(in: stripInScroll, to: rep) }
                real.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            let s = real.dropFirst(10).sorted()
            let med = s[s.count / 2], p95 = s[Int(Double(s.count) * 0.95)]
            t.note(String(format: "200 KB document, non-default settings: keystroke (insert + restyle + layout + dirty-strip redraw) median %.2f ms, p95 %.2f ms", med, p95))
            check(med < 8 && p95 < 16, String(format: "typing with non-default settings: median %.2f ms < 8 and p95 %.2f ms < 16", med, p95))
            assertMatchesFreshLex(t, host, range: visibleRange(host), "after typing: the visible part == fresh restyle with the same settings")
            t.close(doc)
        }
    }
}
#endif
