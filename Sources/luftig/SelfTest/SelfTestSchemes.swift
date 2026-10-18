#if LUFTIG_SELFTEST
// SelfTestSchemes.swift - the colour schemes (Palette.swift, ColorSchemes*.swift):
//   schemes-roles      the list: ids / names / families unique, the schemes the brief asks for are there, every role of the palette is defined and resolvable
//                      for every scheme, the key roles are told apart, unknown ids give the default
//   schemes-contrast   EVERY scheme x every variant (normal, Increase contrast) x every surface with the SAME thresholds as the default scheme's visual-contrast
//                      (text 4.5:1, markers 3:1; 7:1 and 4.5:1 with Increase contrast; caret, quote bar, selection, banners); prints a compact table
//   schemes-apply      Palette.apply: 60 switches in random order: the app appearance is forced, the page / caret / decorations of an OPEN window follow without a rebuild,
//                      a new Theme holds the new colour objects, a window that lived through the switches is pixel-identical to a fresh one, no growth, no per-read cost
//   schemes-selection  the selection of a scheme on pixels: visible, translucent (the band shows through), active != inactive, the layout manager asks the Palette
//   schemes-default    the default scheme's values are the ones the baseline had (golden table, four variants)
//   schemes-report     (not in `all`) writes the table of what the legibility step changed, as markdown: docs/color-schemes.md
// The default scheme's own checks stay in visual-contrast / theme / audit-appearance / visual-selection.

import AppKit

private typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

extension SelfTestScenarios {
    static let schemeScenarios: [SelfTest.Scenario] = [
        .init(name: "schemes-roles", summary: "colour schemes: ids / names unique, the requested themes exist, every role defined for every scheme, unknown id -> default", run: { t in try await schemesRoles(t) }),
        .init(name: "schemes-contrast", summary: "every scheme x variant x surface with the thresholds of visual-contrast: text, markers, caret, bar, selection, banners (prints a table)", run: { t in try await schemesContrast(t) }),
        .init(name: "schemes-apply", summary: "Palette.apply x 60: forced appearance, open window follows, new Theme uses the new colours, pixel-identical to a fresh window, no leak, no per-read cost", run: { t in try await schemesApply(t) }),
        .init(name: "schemes-selection", summary: "selection of every scheme on pixels: visible, band shows through, active != inactive, the layout manager paints the Palette's fill", run: { t in try await schemesSelection(t) }),
        .init(name: "schemes-default", summary: "the default scheme's colours are exactly the baseline's (golden table, 4 variants)", run: { t in try await schemesDefault(t) }),
        .init(name: "schemes-report", summary: "writes what the legibility step changed per scheme (--out file.md), for docs/color-schemes.md", run: { t in try await schemesReport(t) }, inAll: false),
    ]

    /// The required themes of the brief.
    static let requiredSchemeIDs = ["luftig", "solarized-light", "solarized-dark", "github-light", "github-dark", "one-light", "one-dark", "gruvbox-light", "gruvbox-dark",
                                    "dracula", "nord", "monokai", "tomorrow-night", "catppuccin-latte", "catppuccin-mocha", "tokyo-night"]

    static func schemeAppearance(_ s: ColorScheme) -> NSAppearance { NSAppearance(named: s.appearance == .dark ? .darkAqua : .aqua)! }
    private static func rgba(_ c: NSColor, _ appearance: NSAppearance) -> RGBA { Contrast.rgba(c, appearance: appearance) }
    private static func hex(_ c: RGBA) -> String { String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }

    // MARK: roles

    @MainActor static func schemesRoles(_ t: SelfTest.T) async throws {
        defer { Palette.apply(schemeID: ColorSchemes.defaultID) }
        let all = ColorSchemes.all
        t.equal(ColorSchemes.defaultID, "luftig", "the default scheme's id is \"luftig\"")
        t.equal(all.first?.id, "luftig", "the default scheme is the first in the list")
        t.equal(all.first?.appearance, SchemeAppearance.system, "the default scheme follows the system appearance")
        t.check(all.count >= 16, "at least 16 schemes (the default and 15 themes): \(all.count)")
        t.equal(Set(all.map { $0.id }).count, all.count, "ids are unique")
        t.equal(Set(all.map { $0.name }).count, all.count, "names are unique")
        t.check(all.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty && !$0.family.isEmpty && $0.id == $0.id.lowercased() && !$0.id.contains(" ") }, "every scheme has an id (lower case, no blanks), a name and a family")
        for id in requiredSchemeIDs { t.check(all.contains { $0.id == id }, "scheme \(id) is provided") }
        t.check(all.dropFirst().allSatisfy { $0.appearance != .system }, "every theme is a light or a dark scheme (only the default follows the system)")
        let darkIDs: Set<String> = ["solarized-dark", "github-dark", "one-dark", "gruvbox-dark", "dracula", "nord", "monokai", "tomorrow-night", "catppuccin-mocha", "tokyo-night"]
        t.check(all.filter { $0.appearance == .dark }.map { $0.id }.sorted() == darkIDs.sorted(), "the dark themes are the dark ones: \(all.filter { $0.appearance == .dark }.map { $0.id }.joined(separator: ", "))")
        t.check(all.dropFirst().filter { $0.appearance == .light }.map { $0.id }.sorted() == ["catppuccin-latte", "github-light", "gruvbox-light", "one-light", "solarized-light"], "the light themes are the light ones")
        t.equal(Set(all.map { $0.family }).count, 11, "11 families (luftig, Solarized, GitHub, One, Gruvbox, Dracula, Nord, Monokai, Tomorrow, Catppuccin, Tokyo Night)")
        for s in all {
            t.check(s.swatch.count == 5 && s.swatch.allSatisfy { $0.usingColorSpace(.sRGB) != nil && $0.alphaComponent == 1 }, "\(s.id): swatch of 5 opaque colours")
        }
        t.equal(ColorSchemes.scheme(withID: "no-such-scheme").id, "luftig", "an unknown id gives the default scheme")
        t.equal(ColorSchemes.scheme(withID: "").id, "luftig", "an empty id gives the default scheme")
        t.equal(ColorSchemes.scheme(withID: "dracula").name, "Dracula", "scheme(withID:) finds a scheme")
        Palette.apply(schemeID: "no-such-scheme")
        t.equal(Palette.scheme.id, "luftig", "Palette.apply with an unknown id applies the default")

        // every role of the palette, for every scheme, in both variants of its kind
        for s in all {
            Palette.apply(schemeID: s.id)
            t.equal(Palette.scheme.id, s.id, "\(s.id): Palette.scheme is the applied scheme")
            let appearances: [NSAppearance] = s.appearance == .system ? [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] : [schemeAppearance(s)]
            var bad: [String] = []
            for appearance in appearances {
                for hc in [false, true] {
                    ContrastWatcher.shared.override = hc
                    let prose: [(String, NSColor)] = [("background", Palette.background), ("text", Palette.text), ("quoteText", Palette.quoteText), ("struck", Palette.struck), ("heading", Palette.heading),
                                                      ("headingMuted", Palette.headingMuted), ("accent", Palette.accent), ("caret", Palette.caret), ("marker", Palette.marker), ("link", Palette.link),
                                                      ("linkUnderline", Palette.linkUnderline), ("linkDestination", Palette.linkDestination), ("image", Palette.image), ("footnote", Palette.footnote),
                                                      ("escape", Palette.escape), ("copper", Palette.copper), ("codeText", Palette.codeText), ("inlineCode", Palette.inlineCode),
                                                      ("codeLanguage", Palette.codeLanguage), ("listMarker", Palette.listMarker), ("taskUnchecked", Palette.taskUnchecked), ("tableText", Palette.tableText),
                                                      ("frontMatter", Palette.frontMatter), ("html", Palette.html), ("bannerWarning", Palette.bannerWarning), ("bannerInfo", Palette.bannerInfo)]
                    for (name, c) in prose {
                        let v = rgba(c, appearance)
                        if !(v.r >= 0 && v.r <= 1 && v.g >= 0 && v.g <= 1 && v.b >= 0 && v.b <= 1) { bad.append("\(name) out of range") }
                        let wantAlpha = name == "linkUnderline" ? 0.5 : 1.0
                        // (the system label colour of the default scheme is translucent by itself)
                        if s.appearance == .system && (name == "text" || name == "tableText") { if v.a < 0.5 || v.a > 1 { bad.append("\(name) alpha \(v.a)") } }
                        else if abs(v.a - wantAlpha) > 0.001 { bad.append("\(name) alpha \(v.a)") }
                    }
                    let decor: [(String, NSColor)] = [("codeBand", Palette.codeBand), ("quoteBand", Palette.quoteBand), ("quoteBar", Palette.quoteBar), ("nestedBand", Palette.nestedBand),
                                                      ("inlinePill", Palette.inlinePill), ("panelBand", Palette.panelBand), ("tableHeaderBand", Palette.tableHeaderBand), ("rule", Palette.rule)]
                    for (name, c) in decor { let v = rgba(c, appearance); if !(v.a > 0.01 && v.a <= 1) { bad.append("\(name) alpha \(v.a)") } }
                    let border = rgba(Palette.bandBorder, appearance)
                    if hc ? border.a < 0.3 : border.a != 0 { bad.append("bandBorder alpha \(border.a) (hc \(hc))") }
                    // the roles that must be told apart: body text, heading, accent, link and the literal colour are five different colours
                    let five = ["text": Palette.text, "heading": Palette.heading, "accent": Palette.accent, "link": Palette.link, "copper": Palette.copper].mapValues { hex(rgba($0, appearance)) }
                    if Set(five.values).count != 5 { bad.append("text / heading / accent / link / copper are not five different colours: \(five)") }
                    if hex(rgba(Palette.marker, appearance)) == hex(rgba(Palette.text, appearance)) { bad.append("marker == text") }
                    if hex(rgba(Palette.background, appearance)) == hex(rgba(Palette.text, appearance)) { bad.append("background == text") }
                }
            }
            ContrastWatcher.shared.override = nil
            t.check(bad.isEmpty, "\(s.id): all \(26 + 8 + 1) colour roles are defined, in range, with the right alpha, and the key roles differ \(bad.prefix(3))")
            t.check(Palette.fullContrastTable.count == ColorSchemes.contrastRules.count && Palette.textColorsToCheck.count == 27, "\(s.id): the contrast tables are complete")
            t.check(Palette.background === Palette.background && Palette.heading === Palette.heading && Palette.codeBand === Palette.codeBand, "\(s.id): the accessors return the same precomputed objects")
        }
    }

    // MARK: contrast

    /// All checks of `visual-contrast` that make sense for a fixed scheme, for the CURRENT scheme in one variant. Returns the numbers for the table.
    @MainActor static func contrastOfCurrentScheme(_ t: SelfTest.T, label: String, appearance: NSAppearance, variant: PaletteVariant) -> (pairs: Int, tightest: String, markerWorst: Double, caretWorst: Double, selectionBody: Double, failures: Int) {
        typealias S = Palette.FullSurface
        let hc = variant.isHighContrast
        func c(_ x: NSColor) -> RGBA { rgba(x, appearance) }
        func over(_ top: NSColor, _ base: RGBA) -> RGBA { Contrast.over(c(top), base) }
        let bg = c(Palette.background)
        let quote = over(Palette.quoteBand, bg), panel = over(Palette.panelBand, bg)
        let surfaces: [S: RGBA] = [
            .plain: bg, .code: over(Palette.codeBand, bg), .quote: quote, .nestedQuote: over(Palette.nestedBand, over(Palette.nestedBand, quote)),
            .codeInQuote: over(Palette.codeBand, quote), .pill: over(Palette.inlinePill, bg), .pillInQuote: over(Palette.inlinePill, quote),
            .panel: panel, .tableHeader: over(Palette.tableHeaderBand, panel),
        ]
        var failures: [String] = []
        var worst: (String, Double, Double) = ("", 99, 0)
        var pairs = 0, markerWorst = 99.0
        for row in Palette.fullContrastTable {
            let need = hc ? row.minHC : row.min
            for s in row.on {
                let ratio = Contrast.ratio(c(row.color), on: surfaces[s]!)
                pairs += 1
                if ratio < need { failures.append(String(format: "%@ on %@ %.2f < %.1f", row.name, s.rawValue, ratio, need)) }
                if ratio - need < worst.1 - worst.2 { worst = ("\(row.name) on \(s.rawValue)", ratio, need) }
                if row.name == "syntax marker" { markerWorst = min(markerWorst, ratio) }
            }
        }
        var caretWorst = 99.0
        for s in ColorSchemes.caretSurfaces { caretWorst = min(caretWorst, Contrast.ratio(c(Palette.caret), on: surfaces[s]!)) }
        if caretWorst < 3 { failures.append(String(format: "caret %.2f < 3", caretWorst)) }
        let bar = Contrast.over(c(Palette.quoteBar), quote)
        let barRatio = Contrast.ratio(bar, on: quote)
        if barRatio < (hc ? 3 : 1.8) { failures.append(String(format: "quote bar %.2f", barRatio)) }
        let border = c(Palette.bandBorder)
        if hc ? border.a < 0.3 : border.a != 0 { failures.append("band border alpha \(border.a)") }
        // the page of a scheme is the page of the theme, and a fixed scheme resolves the same under the OTHER appearance (it IS light or dark)
        let other = NSAppearance(named: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .aqua : .darkAqua)!
        for (n, col) in [("background", Palette.background), ("text", Palette.text), ("heading", Palette.heading), ("codeBand", Palette.codeBand), ("selection", Palette.selectionFill(variant, active: true) ?? Palette.background)] {
            let a = c(col), b = rgba(col, other)
            if abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) + abs(a.a - b.a) > 0.0001 { failures.append("\(n) differs under the other appearance") }
        }
        // the variant the scheme resolves to
        if Palette.variant(for: appearance) != variant { failures.append("variant(for:) is \(Palette.variant(for: appearance)), expected \(variant)") }

        // the selection: active and inactive, over the page, a code band and a quote band
        var selBody = 99.0
        if let active = Palette.selectionFill(variant, active: true), let inactive = Palette.selectionFill(variant, active: false) {
            for (kind, fill) in [("selection", active), ("inactive selection", inactive)] {
                let sel = c(fill)
                for s in [S.plain, .code, .quote] {
                    let eff = Contrast.over(sel, surfaces[s]!)
                    let body = Contrast.ratio(c(Palette.text), on: eff)
                    selBody = min(selBody, body)
                    if body < (hc ? ColorSchemes.selectionTextMin.highContrast : ColorSchemes.selectionTextMin.normal) { failures.append(String(format: "%@/%@ body text %.2f", kind, s.rawValue, body)) }
                    if kind == "selection" {
                        for (n, col) in [("heading", Palette.heading), ("link", Palette.link), ("accent", Palette.accent), ("copper", Palette.copper), ("quote text", Palette.quoteText)] {
                            let r = Contrast.ratio(c(col), on: eff)
                            if r < ColorSchemes.selectionColouredMin { failures.append(String(format: "%@/%@ %@ %.2f", kind, s.rawValue, n, r)) }
                        }
                        let m = Contrast.ratio(c(Palette.marker), on: eff)
                        if m < ColorSchemes.selectionMarkerMin { failures.append(String(format: "%@/%@ marker %.2f", kind, s.rawValue, m)) }
                    }
                }
                let onPage = Contrast.over(sel, bg), onBand = Contrast.over(sel, surfaces[.code]!)
                let visible = Contrast.ratio(onPage, on: bg)
                if visible < ColorSchemes.selectionVisibleMin { failures.append(String(format: "%@ vs page %.2f:1", kind, visible)) }
                if kind == "selection" {
                    let delta = max(abs(onPage.r - onBand.r), abs(onPage.g - onBand.g), abs(onPage.b - onBand.b)) * 255
                    if delta < 3.0 { failures.append(String(format: "band under selection %.1f levels", delta)) }
                }
            }
        } else { failures.append("no selection fill") }
        // text on the two banners
        for (n, banner) in [("warning banner", Palette.bannerWarning), ("info banner", Palette.bannerInfo)] {
            let r = Contrast.ratio(c(Palette.text), on: c(banner))
            if r < (hc ? 7 : 4.5) { failures.append(String(format: "text on %@ %.2f", n, r)) }
        }
        t.check(failures.isEmpty, "\(label): \(pairs) text / surface pairs, caret, quote bar, selection (active + inactive), banners, appearance independence \(failures.prefix(4))")
        return (pairs, String(format: "%@ %.2f", worst.0, worst.1), markerWorst, caretWorst, selBody, failures.count)
    }

    @MainActor static func schemesContrast(_ t: SelfTest.T) async throws {
        defer { ContrastWatcher.shared.override = nil; Palette.apply(schemeID: ColorSchemes.defaultID) }
        t.info("scheme            variant      pairs  tightest pair (ratio)                           markers  caret  selection body")
        var totalPairs = 0
        for s in ColorSchemes.all where s.appearance != .system {
            Palette.apply(schemeID: s.id)
            let appearance = schemeAppearance(s)
            for hc in [false, true] {
                ContrastWatcher.shared.override = hc
                let variant: PaletteVariant = s.appearance == .dark ? (hc ? .darkHC : .dark) : (hc ? .lightHC : .light)
                let r = contrastOfCurrentScheme(t, label: "\(s.id) \(hc ? "+ Increase contrast" : "normal")", appearance: appearance, variant: variant)
                totalPairs += r.pairs
                t.info(String(format: "%@ %@ %4d   %@ %7.2f  %5.2f  %6.2f", s.id.padding(toLength: 17, withPad: " ", startingAt: 0), (hc ? "increased" : "normal").padding(toLength: 11, withPad: " ", startingAt: 0), r.pairs,
                              r.tightest.padding(toLength: 46, withPad: " ", startingAt: 0), r.markerWorst, r.caretWorst, r.selectionBody))
            }
        }
        t.info("\(totalPairs) text / surface pairs checked over \(ColorSchemes.all.count - 1) schemes x 2 variants")
    }

    // MARK: apply

    @MainActor static func schemesApply(_ t: SelfTest.T) async throws {
        defer { Palette.apply(schemeID: ColorSchemes.defaultID); ContrastWatcher.shared.override = nil }
        let savedSize = EditorPreferences.fontSize
        defer { EditorPreferences.fontSize = savedSize }
        EditorPreferences.fontSize = 16
        let ids = ColorSchemes.all.map { $0.id }
        Palette.apply(schemeID: ColorSchemes.defaultID)

        // ---- what building a scheme costs: the whole list from scratch (the app builds one when it is chosen)
        let t0 = SelfTest.nowMs()
        for spec in SchemeSpec.all { _ = SchemeBuilder.build(spec, info: spec.scheme) }
        let buildMs = SelfTest.nowMs() - t0
        t.note(String(format: "building all %d theme schemes from their palettes (adjustment included): %.1f ms (%.2f ms each)", SchemeSpec.all.count, buildMs, buildMs / Double(SchemeSpec.all.count)))
        t.check(buildMs < 250, String(format: "building 15 schemes takes %.1f ms (< 250 ms; one is built when it is first chosen)", buildMs))
        // determinism: the same spec gives the same colours
        for spec in SchemeSpec.all.prefix(4) {
            let a = SchemeBuilder.build(spec, info: spec.scheme), b = SchemeBuilder.build(spec, info: spec.scheme)
            let ap = NSAppearance(named: spec.dark ? .darkAqua : .aqua)!
            t.check(hex(rgba(a.prose.heading, ap)) == hex(rgba(b.prose.heading, ap)) && hex(rgba(a.prose.marker, ap)) == hex(rgba(b.prose.marker, ap)), "\(spec.id): building twice gives the same colours")
        }

        let text = """
        # Heading one

        Plain text, `inline code`, a [link](https://example.com) and **bold**.

        > a quote with `code` in it

        ```swift
        let x = 1
        ```

        - [x] done
        - list item

        | a | b |
        |---|---|
        | 1 | 2 |

        End.
        """
        let (doc, host, _) = try await openEditor(t, text: text, name: "apply.md", size: NSSize(width: 860, height: 700))
        guard let window = doc.windowControllers.first?.window else { t.check(false, "no window"); return }
        host.styler.styleEverything()
        let tv = host.textView, ts = tv.textStorage!
        let ns = tv.string as NSString
        let headingLoc = ns.range(of: "Heading").location, plainLoc = ns.range(of: "Plain").location, codeLoc = ns.range(of: "inline code").location + 3, markerLoc = ns.range(of: "# Heading").location

        var seen = 0
        let observer = NotificationCenter.default.addObserver(forName: Palette.didChangeNotification, object: nil, queue: nil) { _ in seen += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var rng = TestRNG(0x5C1BE)
        var current = ColorSchemes.defaultID
        var order: [String] = []
        for _ in 0..<60 { var next = ids[rng.int(ids.count)]; if next == current { next = ids[(ids.firstIndex(of: next)! + 1) % ids.count] }; order.append(next); current = next }
        var expectedSwitches = 0
        var colourObjects: [String: NSColor] = [:]
        var applyMs: [Double] = []
        var failures: [String] = []
        for (i, id) in order.enumerated() {
            let s = ColorSchemes.scheme(withID: id)
            let a0 = SelfTest.nowMs()
            Palette.apply(schemeID: id)
            applyMs.append(SelfTest.nowMs() - a0)
            expectedSwitches += 1
            if Palette.scheme.id != id { failures.append("#\(i) \(id): Palette.scheme is \(Palette.scheme.id)") }
            // the app appearance is forced to the scheme's kind (nil for the default)
            let want: NSAppearance.Name? = s.appearance == .system ? nil : (s.appearance == .dark ? .darkAqua : .aqua)
            if NSApp.appearance?.name != want { failures.append("#\(i) \(id): NSApp.appearance is \(String(describing: NSApp.appearance?.name)), expected \(String(describing: want))") }
            if s.appearance != .system {
                let eff = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
                if eff != (s.appearance == .dark ? .darkAqua : .aqua) { failures.append("#\(i) \(id): NSApp.effectiveAppearance is \(String(describing: eff))") }
            }
            // the OPEN window follows without any rebuild: page, caret, decoration colours of the draw path
            let ap = tv.effectiveAppearance
            let pageNow = rgba(Palette.background, ap)
            let tvBg = rgba(tv.backgroundColor, ap), svBg = rgba(host.scrollView.backgroundColor, ap)
            if hex(tvBg) != hex(pageNow) || hex(svBg) != hex(pageNow) { failures.append("#\(i) \(id): page colour of the open window is \(hex(tvBg)) / \(hex(svBg)), expected \(hex(pageNow))") }
            if tv.insertionPointColor !== Palette.caret { failures.append("#\(i) \(id): the insertion point colour is stale") }
            let cols = DecorationDrawing.Colors(appearance: ap)
            let expBand = Contrast.over(rgba(Palette.codeBand, ap), pageNow)
            if let got = NSColor(cgColor: cols.codeBand)?.usingColorSpace(.sRGB), abs(Double(got.redComponent) - expBand.r) > 0.004 || abs(Double(got.greenComponent) - expBand.g) > 0.004 || abs(Double(got.blueComponent) - expBand.b) > 0.004 {
                failures.append("#\(i) \(id): the code band of the draw path is stale (\(got) vs \(hex(expBand)))")
            }
            let barGot = NSColor(cgColor: cols.quoteBar)?.usingColorSpace(.sRGB)
            let barExp = rgba(Palette.quoteBar, ap)
            if let barGot, abs(Double(barGot.redComponent) - barExp.r) > 0.004 || abs(Double(barGot.alphaComponent) - barExp.a) > 0.004 { failures.append("#\(i) \(id): the quote bar of the draw path is stale") }
            // the same colour OBJECTS every time a scheme is applied (precomputed, never rebuilt)
            if let before = colourObjects[id] { if before !== Palette.heading { failures.append("#\(i) \(id): Palette.heading is a new object after switching back") } } else { colourObjects[id] = Palette.heading }
            // a new Theme (what the editors build on a change) holds the new colour objects: emulated through the font-size path, which rebuilds the Theme
            EditorPreferences.fontSize = 17
            EditorPreferences.fontSize = 16
            host.styler.styleEverything()
            func fg(_ loc: Int) -> NSColor? { ts.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor }
            if fg(headingLoc) !== Palette.heading { failures.append("#\(i) \(id): heading text does not hold Palette.heading") }
            if fg(plainLoc) !== Palette.text { failures.append("#\(i) \(id): body text does not hold Palette.text") }
            if fg(codeLoc) !== Palette.inlineCode { failures.append("#\(i) \(id): inline code does not hold Palette.inlineCode") }
            if fg(markerLoc) !== Palette.marker { failures.append("#\(i) \(id): the # marker does not hold Palette.marker") }
            if host.theme.baseAttributes[.foregroundColor] as? NSColor !== Palette.text { failures.append("#\(i) \(id): the new Theme's base attributes hold a stale colour") }
            // a window that lived through the switches is pixel-identical to a fresh window in the scheme (every 6th switch; rendering is the expensive part)
            if i % 6 == 5 || i >= order.count - 2 {
                host.styler.styleVisible()
                let (doc2, host2, _) = try await openEditor(t, text: text, name: "apply-fresh-\(i).md", size: NSSize(width: 860, height: 700))
                host2.styler.styleEverything()
                if let pa = pixels(window), let win2 = doc2.windowControllers.first?.window, let pb = pixels(win2) {
                    let d = pixelDiff(pa, pb)
                    if d.count != 0 { failures.append("#\(i) \(id): the long-lived window differs from a fresh one in \(d.count) pixels (\(d.box))") }
                }
                t.close(doc2)
            }
        }
        t.check(failures.isEmpty, "60 random switches over \(ids.count) schemes: forced appearance, page / caret / decorations of the open window, new Theme colours, pixel-identical to a fresh window \(failures.prefix(3))")
        t.equal(seen, expectedSwitches, "Palette.didChangeNotification was posted once per real switch (\(seen) of \(expectedSwitches))")
        // applying the scheme that is already current changes nothing and posts nothing
        let before = seen
        Palette.apply(schemeID: Palette.scheme.id); Palette.apply(schemeID: Palette.scheme.id)
        t.equal(seen, before, "applying the current scheme again posts no notification")
        applyMs.sort()
        t.note(String(format: "Palette.apply: median %.3f ms, max %.3f ms (all schemes were built before; the first apply of a scheme builds it)", applyMs[applyMs.count / 2], applyMs.last ?? 0))
        t.check(applyMs[applyMs.count / 2] < 5, "Palette.apply (a scheme that is built) takes < 5 ms, median \(applyMs[applyMs.count / 2]) ms")

        // ---- no growth: 300 more switches, each with a new Theme and a restyle (no pixel capture: AppKit keeps the bitmaps of a headless process until an event arrives)
        await drainPools(t)
        let rss0 = ProcessMetrics.residentBytes()
        for i in 0..<300 {
            Palette.apply(schemeID: ids[rng.int(ids.count)])
            EditorPreferences.fontSize = i % 2 == 0 ? 17 : 16
            host.styler.styleVisible()
        }
        EditorPreferences.fontSize = 16
        await drainPools(t)
        let grew = ProcessMetrics.residentBytes() - rss0
        t.note("RSS change over 300 scheme switches with a new Theme and a restyle each: \(ProcessMetrics.mb(grew))")
        t.check(grew < 25 * 1_048_576, "no growth over 300 switches: \(ProcessMetrics.mb(grew)) (< 25 MB)")

        // ---- the accessors are plain loads: nothing is rebuilt per read
        Palette.apply(schemeID: "dracula")
        let r0 = SelfTest.nowMs()
        let sink = unoptimizedPaletteReads(2_000_000)
        let readMs = SelfTest.nowMs() - r0
        t.note(String(format: "8,000,000 Palette reads (heading, text, codeBand, marker) in UNOPTIMIZED code: %.1f ms (%.1f ns each)", readMs, readMs * 1e6 / 8_000_000))
        t.check(sink == 0 && readMs * 1e6 / 8_000_000 < 200, String(format: "a Palette read is a load, not a rebuild (%.1f ns each even unoptimized; building a colour takes microseconds)", readMs * 1e6 / 8_000_000))

        // ---- a stray window.appearance cannot turn a fixed scheme into light text on a light page: the text view looks the same under either appearance
        Palette.apply(schemeID: "dracula")
        host.styler.styleEverything()
        EditorPreferences.fontSize = 17; EditorPreferences.fontSize = 16            // new Theme with the new colours
        host.styler.styleEverything()
        window.appearance = nil
        settle(host)
        let natural = ViewPixels(tv)
        window.appearance = NSAppearance(named: .aqua)
        settle(host)
        let forcedLight = ViewPixels(tv)
        window.appearance = nil
        if let a = natural, let b = forcedLight, a.rep.pixelsWide == b.rep.pixelsWide, a.rep.pixelsHigh == b.rep.pixelsHigh, let da = a.rep.bitmapData, let db = b.rep.bitmapData {
            var differing = 0
            for row in 0..<a.rep.pixelsHigh { for col in 0..<(a.rep.pixelsWide * a.rep.samplesPerPixel) where da[row * a.rep.bytesPerRow + col] != db[row * b.rep.bytesPerRow + col] { differing += 1 } }
            t.equal(differing, 0, "dracula in a window whose appearance is forced to Aqua: the text view is pixel-identical (a fixed scheme is dark by itself; \(differing) differing samples)")
        } else { t.check(false, "dracula: could not compare the two appearances") }
        Palette.apply(schemeID: ColorSchemes.defaultID)
        t.close(doc)
    }

    /// Reads four accessors `n` times each without letting the optimizer hoist the loads (the reads are one function call away and the function is not optimized).
    @_optimize(none) private static func unoptimizedPaletteReads(_ n: Int) -> Int {
        var sink = 0
        for _ in 0..<n { if Palette.heading === Palette.text { sink += 1 }; if Palette.codeBand === Palette.marker { sink += 1 }; if Palette.link === Palette.accent { sink += 1 }; if Palette.rule === Palette.quoteBar { sink += 1 } }
        return sink
    }

    // MARK: selection

    @MainActor static func schemesSelection(_ t: SelfTest.T) async throws {
        defer { LuftigLayoutManager.simulateActiveSelection = false; ContrastWatcher.shared.override = nil; Palette.apply(schemeID: ColorSchemes.defaultID) }
        let text = "Plain line of text here.\n\n```\nHxgy code line\n```\n\nAnother plain line.\n\n```\nunselected code\n```\n"
        for s in ColorSchemes.all where s.appearance != .system {
            Palette.apply(schemeID: s.id)
            let (doc, host, _) = try await openEditor(t, text: text, name: "scheme-sel-\(s.id).md", size: NSSize(width: 860, height: 700))
            host.styler.styleEverything()
            let tv = host.textView
            let ns = tv.string as NSString
            let start = ns.range(of: "Plain").location, end = ns.range(of: "Another").location - 2
            tv.setSelectedRange(NSRange(location: start, length: end - start))
            settle(host)
            guard let lm = tv.layoutManager as? LuftigLayoutManager, let plain = lineRect(tv, containing: "Plain line"), let code = lineRect(tv, containing: "Hxgy"), let other = lineRect(tv, containing: "unselected") else { t.check(false, "\(s.id): setup failed"); continue }
            // the layout manager asks the Palette: the fill it returns for the system's selection colours is the scheme's
            let ap = tv.effectiveAppearance
            let variant = Palette.variant(for: ap)
            LuftigLayoutManager.simulateActiveSelection = false
            let inactive = lm.selectionFillColor(.unemphasizedSelectedTextBackgroundColor, charRange: NSRange(location: start, length: 5))
            LuftigLayoutManager.simulateActiveSelection = true
            let active = lm.selectionFillColor(.selectedTextBackgroundColor, charRange: NSRange(location: start, length: 5))
            let nonSelection = lm.selectionFillColor(.selectedTextBackgroundColor, charRange: NSRange(location: ns.length - 3, length: 2))
            t.check(active === Palette.selectionFill(variant, active: true) && inactive === Palette.selectionFill(variant, active: false) && nonSelection == nil,
                    "\(s.id): the layout manager paints the Palette's selection fills (active, inactive), and nothing for a range that is not selected")
            let o = tv.textContainerOrigin
            let x = o.x + tv.textContainer!.size.width - 30
            func lum(_ c: (r: Int, g: Int, b: Int)) -> Int { (c.r * 3 + c.g * 6 + c.b) / 10 }
            var shots: [(label: String, plain: (r: Int, g: Int, b: Int), code: (r: Int, g: Int, b: Int))] = []
            var page = (r: 0, g: 0, b: 0), band = (r: 0, g: 0, b: 0)
            for activeSelection in [true, false] {
                LuftigLayoutManager.simulateActiveSelection = activeSelection
                tv.needsDisplay = true
                guard let px = ViewPixels(tv) else { t.check(false, "\(s.id): no pixels"); continue }
                page = px.rgb(4, 4); band = px.rgb(x, other.midY)
                shots.append((activeSelection ? "active" : "inactive", px.rgb(x, plain.midY), px.rgb(x, code.midY)))
            }
            LuftigLayoutManager.simulateActiveSelection = false
            let bandDelta = max(abs(band.r - page.r), abs(band.g - page.g), abs(band.b - page.b))
            var problems: [String] = []
            for shot in shots {
                let vis = max(abs(shot.plain.r - page.r), abs(shot.plain.g - page.g), abs(shot.plain.b - page.b))
                if vis < 6 { problems.append("\(shot.label) selection differs from the page by only \(vis) levels") }
                let through = max(abs(shot.plain.r - shot.code.r), abs(shot.plain.g - shot.code.g), abs(shot.plain.b - shot.code.b))
                if shot.label == "active" && through < 2 { problems.append("the band does not show through the active selection (\(through) levels)") }
                if lum(shot.plain) == lum(page) { problems.append("\(shot.label): selection pixel == page pixel") }
            }
            if shots.count == 2, max(abs(shots[0].plain.r - shots[1].plain.r), abs(shots[0].plain.g - shots[1].plain.g), abs(shots[0].plain.b - shots[1].plain.b)) < 3 { problems.append("active and inactive selection look the same") }
            if bandDelta < 4 { problems.append("the code band differs from the page by only \(bandDelta) levels") }
            t.check(problems.isEmpty, "\(s.id): selection on pixels: visible, band shows through, active != inactive (page \(page), band \(band), selected \(shots.map { "\($0.label) \($0.plain)/\($0.code)" })) \(problems)")
            t.close(doc)
        }
    }

    // MARK: the default scheme is unchanged

    @MainActor static func schemesDefault(_ t: SelfTest.T) async throws {
        defer { ContrastWatcher.shared.override = nil; Palette.apply(schemeID: ColorSchemes.defaultID) }
        Palette.apply(schemeID: ColorSchemes.defaultID)
        t.equal(Palette.scheme.id, "luftig", "default scheme is current")
        t.check(NSApp.appearance == nil, "the default scheme leaves the app's appearance to the system (NSApp.appearance == nil)")
        t.check(Palette.background === NSColor.textBackgroundColor && Palette.tableText === NSColor.labelColor, "the default page is the system's text background and the table text the system label colour")
        t.check(Palette.caret === Palette.accent && Palette.image === Palette.accent && Palette.listMarker === Palette.accent && Palette.codeLanguage === Palette.accent, "the default caret is the accent, as before; image / list marker / code language are the accent")
        t.check(Palette.escape === Palette.copper && Palette.inlineCode === Palette.copper && Palette.footnote === Palette.headingMuted && Palette.taskUnchecked === Palette.linkDestination, "default aliases: escape / inline code = copper, footnote = muted heading, unchecked task = link destination")
        t.check(Palette.selectionFill(.light, active: true) == nil && Palette.selectionFill(.dark, active: false) == nil, "the default scheme has no selection fill of its own (the system colour is used)")
        t.equal(Palette.selectionAlpha(.light), 0.65, "selection alpha light")
        t.equal(Palette.selectionAlpha(.dark), 0.50, "selection alpha dark")
        t.equal(Palette.selectionAlpha(.lightHC), 0.75, "selection alpha light + Increase contrast")
        t.equal(Palette.selectionAlpha(.darkHC), 0.55, "selection alpha dark + Increase contrast")
        // golden values of the baseline Palette.swift: (light, dark, light HC, dark HC) as 8-bit sRGB (+ alpha for the tints)
        typealias G = (Int, Int, Int)
        let ink: [(String, NSColor, G, G, G, G)] = [
            ("quoteText", Palette.quoteText, (74, 80, 100), (184, 188, 204), (40, 44, 60), (224, 228, 240)),
            ("struck", Palette.struck, (96, 100, 114), (162, 166, 178), (62, 66, 80), (208, 212, 222)),
            ("heading", Palette.heading, (34, 40, 118), (196, 204, 255), (20, 24, 90), (214, 220, 255)),
            ("headingMuted", Palette.headingMuted, (78, 84, 140), (162, 170, 222), (48, 54, 112), (204, 210, 246)),
            ("accent", Palette.accent, (64, 70, 196), (148, 158, 255), (40, 46, 170), (200, 206, 255)),
            ("marker", Palette.marker, (124, 128, 140), (142, 146, 158), (84, 88, 100), (190, 194, 206)),
            ("link", Palette.link, (0, 92, 200), (100, 168, 255), (0, 60, 160), (176, 214, 255)),
            ("linkDestination", Palette.linkDestination, (94, 100, 116), (158, 164, 180), (60, 66, 82), (206, 210, 222)),
            ("copper", Palette.copper, (168, 58, 0), (255, 156, 108), (116, 32, 0), (255, 204, 176)),
            ("codeText", Palette.codeText, (46, 50, 62), (222, 226, 234), (0, 0, 0), (255, 255, 255)),
            ("frontMatter", Palette.frontMatter, (76, 84, 106), (168, 176, 198), (48, 54, 72), (214, 220, 234)),
            ("html", Palette.html, (84, 94, 112), (158, 168, 186), (52, 60, 76), (210, 216, 230)),
        ]
        typealias T4 = ((Int, Int, Int), Double)
        let tints: [(String, NSColor, T4, T4, T4, T4)] = [
            ("codeBand", Palette.codeBand, ((30, 36, 60), 0.055), ((204, 219, 255), 0.085), ((30, 36, 60), 0.08), ((204, 219, 255), 0.09)),
            ("quoteBand", Palette.quoteBand, ((64, 70, 196), 0.05), ((148, 158, 255), 0.085), ((64, 70, 196), 0.07), ((148, 158, 255), 0.09)),
            ("quoteBar", Palette.quoteBar, ((64, 70, 196), 0.55), ((148, 158, 255), 0.65), ((40, 46, 170), 1.0), ((200, 206, 255), 1.0)),
            ("nestedBand", Palette.nestedBand, ((64, 70, 196), 0.04), ((148, 158, 255), 0.06), ((64, 70, 196), 0.04), ((148, 158, 255), 0.05)),
            ("inlinePill", Palette.inlinePill, ((168, 58, 0), 0.09), ((255, 156, 108), 0.15), ((168, 58, 0), 0.10), ((255, 156, 108), 0.14)),
            ("panelBand", Palette.panelBand, ((30, 36, 60), 0.035), ((204, 219, 255), 0.05), ((30, 36, 60), 0.05), ((204, 219, 255), 0.06)),
            ("tableHeaderBand", Palette.tableHeaderBand, ((30, 36, 60), 0.075), ((204, 219, 255), 0.10), ((30, 36, 60), 0.08), ((204, 219, 255), 0.10)),
            ("rule", Palette.rule, ((0, 0, 0), 0.26), ((255, 255, 255), 0.30), ((0, 0, 0), 0.60), ((255, 255, 255), 0.65)),
            ("bandBorder", Palette.bandBorder, ((0, 0, 0), 0), ((0, 0, 0), 0), ((0, 0, 0), 0.38), ((255, 255, 255), 0.42)),
        ]
        var bad: [String] = []
        let variants: [(String, NSAppearance.Name, Bool)] = [("light", .aqua, false), ("dark", .darkAqua, false), ("light HC", .aqua, true), ("dark HC", .darkAqua, true)]
        for (vi, (vname, an, hc)) in variants.enumerated() {
            ContrastWatcher.shared.override = hc
            let ap = NSAppearance(named: an)!
            func is8(_ c: RGBA, _ g: G, _ a: Double = 1) -> Bool {
                abs(c.r * 255 - Double(g.0)) < 0.51 && abs(c.g * 255 - Double(g.1)) < 0.51 && abs(c.b * 255 - Double(g.2)) < 0.51 && abs(c.a - a) < 0.0006
            }
            for row in ink {
                let g = [row.2, row.3, row.4, row.5][vi]
                if !is8(rgba(row.1, ap), g) { bad.append("\(row.0) \(vname)") }
            }
            for row in tints {
                let g = [row.2, row.3, row.4, row.5][vi]
                if !is8(rgba(row.1, ap), g.0, g.1) { bad.append("\(row.0) \(vname)") }
            }
            // body text: label colour in the normal variants, black / white with Increase contrast; the page: the system's
            let text = rgba(Palette.text, ap)
            if hc ? !(is8(text, an == .aqua ? (0, 0, 0) : (255, 255, 255))) : (abs(text.a - rgba(NSColor.labelColor, ap).a) > 0.001 || abs(text.r - rgba(NSColor.labelColor, ap).r) > 0.001) { bad.append("text \(vname)") }
            let page = rgba(Palette.background, ap), sys = rgba(NSColor.textBackgroundColor, ap)
            if abs(page.r - sys.r) + abs(page.g - sys.g) + abs(page.b - sys.b) > 0.0001 { bad.append("background \(vname)") }
            let banner = (rgba(Palette.bannerWarning, ap), rgba(Palette.bannerInfo, ap))
            let wantW: G = an == .aqua ? (255, 240, 196) : (76, 62, 22), wantI: G = an == .aqua ? (222, 236, 255) : (28, 50, 84)
            if !is8(banner.0, wantW) || !is8(banner.1, wantI) { bad.append("banner \(vname)") }
        }
        ContrastWatcher.shared.override = nil
        t.check(bad.isEmpty, "the default scheme: \(ink.count) text colours + \(tints.count) decoration colours + text + page + banners in the 4 variants equal the baseline's values \(bad.prefix(4))")
        // a scheme applied and then the default again gives the default's colour OBJECTS back
        let heading = Palette.heading, text = Palette.text
        Palette.apply(schemeID: "dracula"); Palette.apply(schemeID: ColorSchemes.defaultID)
        t.check(Palette.heading === heading && Palette.text === text && NSApp.appearance == nil, "dracula and back: the default scheme's colour objects are the same and the appearance is the system's again")
    }

    // MARK: the report (markdown for docs/color-schemes.md)

    @MainActor static func schemesReport(_ t: SelfTest.T) async throws {
        defer { Palette.apply(schemeID: ColorSchemes.defaultID) }
        var md = ""
        var summary = "| Scheme | Appearance | Roles adjusted (normal) | Roles adjusted (Increase contrast) | Largest lightness change |\n|---|---|---|---|---|\n"
        var details = ""
        for spec in SchemeSpec.all {
            let colors = ColorSchemes.colors(for: spec.scheme)
            guard let report = colors.report else { continue }
            let changed = report.rows.filter { $0.normalChanged }
            let hcChanged = report.rows.filter { ColorMath.hex($0.normal) != ColorMath.hex($0.highContrast) }
            let largest = report.rows.map { abs($0.normalDeltaL) }.max() ?? 0
            summary += "| \(spec.name) | \(spec.dark ? "dark" : "light") | \(changed.count) of \(report.rows.count) | \(hcChanged.count) of \(report.rows.count) | \(String(format: "%.1f", largest)) |\n"
            details += "\n#### \(spec.name)\n\n"
            details += "Page `\(ColorMath.hex(ColorMath.rgb(hex: spec.bg)))`.\n\n"
            details += "| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |\n|---|---|---|---|---|---|\n"
            for r in report.rows {
                let n = r.normalChanged ? String(format: "`%@` | %+.1f", ColorMath.hex(r.normal), r.normalDeltaL) : "= | -"
                let hcChanged = ColorMath.hex(r.normal) != ColorMath.hex(r.highContrast)
                let h = hcChanged ? String(format: "`%@` | %+.1f", ColorMath.hex(r.highContrast), r.highContrastDeltaL) : "= | -"
                details += "| \(r.role) | `\(ColorMath.hex(r.authentic))` | \(n) | \(h) |\n"
            }
            for n in report.notes { details += "\nNote: \(n)\n" }
        }
        md = summary + details
        if let out = SelfTest.argument("out") { try md.write(to: URL(fileURLWithPath: out), atomically: false, encoding: .utf8); t.check(true, "report written to \(out) (\(md.count) characters)") }
        else { t.info(md); t.check(true, "report printed") }
    }
}


// MARK: - schemes-import (SchemeImport: Base16 YAML files)

extension SelfTestScenarios {
    static let schemesImportScenarios: [SelfTest.Scenario] = [
        .init(name: "schemes-import", summary: "colour schemes from Base16 YAML files: both spellings parsed, the roles, light / dark, the import into Application Support, the list, the Settings popup, legibility, removal", run: { t in try await schemesImport(t) }),
    ]

    static let base16DefaultDark = """
    scheme: "Default Dark"
    author: "Chris Kempson (http://chriskempson.com)"
    base00: "181818"
    base01: "282828"
    base02: "383838"
    base03: "585858"
    base04: "b8b8b8"
    base05: "d8d8d8"
    base06: "e8e8e8"
    base07: "f8f8f8"
    base08: "ab4642"
    base09: "dc9656"
    base0A: "f7ca88"
    base0B: "a1b56c"
    base0C: "86c1b9"
    base0D: "7cafc2"
    base0E: "ba8baf"
    base0F: "a16946"

    """
    static let base16DefaultLight = """
    system: "base16"
    name: "Default Light"
    author: "Chris Kempson (http://chriskempson.com)"
    variant: "light"
    palette:
      base00: "#f8f8f8"
      base01: "#e8e8e8"
      base02: "#d8d8d8"
      base03: "#b8b8b8"
      base04: "#585858"
      base05: "#383838"
      base06: "#282828"
      base07: "#181818"
      base08: "#ab4642"
      base09: "#dc9656"
      base0A: "#f7ca88"
      base0B: "#a1b56c"
      base0C: "#86c1b9"
      base0D: "#7cafc2"
      base0E: "#ba8baf"
      base0F: "#a16946"

    """

    @MainActor static func schemesImport(_ t: SelfTest.T) async throws {
        let savedScheme = EditorPreferences.colorSchemeID
        defer {
            EditorPreferences.colorSchemeID = savedScheme
            Palette.apply(schemeID: EditorPreferences.colorSchemeID); ContrastWatcher.shared.override = nil
            SchemeImport.directoryOverride = nil; ColorSchemes.reloadImported()
        }
        // ---- parsing
        guard let dark = SchemeImport.spec(fromYAML: base16DefaultDark, id: "imported-x") else { t.check(false, "the classic Base16 spelling parses"); return }
        t.check(dark.name == "Default Dark" && dark.dark && dark.family == SchemeImport.family, "classic spelling: name, dark (base00 is dark), family Imported: \(dark.name)")
        t.check(dark.bg == 0x181818 && dark.fg == 0xd8d8d8 && dark.comment == 0x585858 && dark.heading == 0x7cafc2 && dark.accent == 0xba8baf && dark.link == 0x86c1b9 && dark.literal == 0xa1b56c && dark.warn == 0xf7ca88 && dark.info == 0x7cafc2 && dark.caret == 0xd8d8d8, "the roles: page base00, text base05, markers base03, headings base0D, accent base0E, links base0C, inline code base0B, banners base0A / base0D, caret base05")
        if case .opaque(let s) = dark.selection { t.equal(s, 0x383838, "the selection is base02") } else { t.check(false, "the selection is opaque base02") }
        guard let light = SchemeImport.spec(fromYAML: base16DefaultLight, id: "imported-y") else { t.check(false, "the newer spelling (system / name / palette:) parses"); return }
        t.check(light.name == "Default Light" && !light.dark && light.bg == 0xf8f8f8 && light.fg == 0x383838, "newer spelling: name, light (variant), # prefixes removed: \(light.name)")
        t.check(SchemeImport.spec(fromYAML: base16DefaultDark.replacingOccurrences(of: "base0F: \"a16946\"\n", with: ""), id: "i") == nil, "a missing base0F: not a scheme")
        t.check(SchemeImport.spec(fromYAML: "# just a comment\nname: x\n", id: "i") == nil && SchemeImport.spec(fromYAML: "", id: "i") == nil, "no colours: not a scheme")
        t.check(SchemeImport.spec(fromYAML: base16DefaultDark.replacingOccurrences(of: "\"181818\"", with: "\"18181\""), id: "i") == nil, "a malformed colour: not a scheme")
        t.equal(SchemeImport.hexValue("#abc"), 0xaabbcc, "rgb shorthand")
        t.equal(SchemeImport.parseYAML("base00: 181818 # the page\nkey: 'quoted value' # c\n  nested: \"#fff\"\n")["base00"], "181818", "an unquoted value ends before a comment")
        t.equal(SchemeImport.parseYAML("key: 'quoted value' # c\n")["key"], "quoted value", "a quoted value keeps its blanks")
        t.equal(SchemeImport.parseYAML("  base01: \"#fff\"\n")["base01"], "#fff", "an indented key (inside palette:) counts")
        let noName = SchemeImport.spec(fromYAML: base16DefaultDark.replacingOccurrences(of: "scheme: \"Default Dark\"\n", with: ""), id: "imported-my-theme")
        t.equal(noName?.name, "My Theme", "without a name: the file's name, capitalised")
        t.equal(SchemeImport.id(forFile: URL(fileURLWithPath: "/x/My Theme (v2).YAML")), "imported-my-theme-v2", "the id from the file's name")
        let luminanceDark = SchemeImport.spec(fromYAML: base16DefaultLight.replacingOccurrences(of: "variant: \"light\"\n", with: ""), id: "i")
        t.check(luminanceDark?.dark == false, "without a variant the page's luminance decides (f8f8f8: light)")

        // ---- the folder (a private one for the test), the import
        let dir = t.url("schemes-import")
        try? FileManager.default.removeItem(at: dir)
        SchemeImport.directoryOverride = dir
        ColorSchemes.reloadImported()
        let before = ColorSchemes.all.count
        t.check(ColorSchemes.imported.isEmpty, "set-up: no imported schemes in an empty folder")
        let src = t.write(base16DefaultDark, to: "schemes-src/default-dark.yaml")
        let id = try SchemeImport.importFile(src)
        t.equal(id, "imported-default-dark", "the imported scheme's id")
        t.check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("default-dark.yaml").path), "the file was copied into the schemes folder")
        t.equal(ColorSchemes.all.count, before + 1, "the list has one scheme more")
        let scheme = ColorSchemes.scheme(withID: id)
        t.check(scheme.id == id && scheme.name == "Default Dark" && scheme.family == "Imported" && scheme.appearance == .dark && scheme.swatch.count == 5, "... under the family Imported, dark: \(scheme.name)")
        EditorPreferences.colorSchemeID = id
        t.equal(EditorPreferences.colorSchemeID, id, "the preference accepts the imported id")
        t.equal(Palette.scheme.id, id, "the palette applied it")
        t.equal(hex(rgba(Palette.background, NSAppearance(named: .darkAqua)!)), "#181818", "the page is base00")
        // ---- legibility: the same thresholds as every built-in scheme
        for hc in [false, true] {
            ContrastWatcher.shared.override = hc
            let r = contrastOfCurrentScheme(t, label: "\(id) \(hc ? "+ Increase contrast" : "normal")", appearance: NSAppearance(named: .darkAqua)!, variant: hc ? .darkHC : .dark)
            t.check(r.failures == 0, "\(id) \(hc ? "+ Increase contrast" : "normal"): every text / surface pair legible (\(r.pairs) pairs, tightest \(r.tightest))")
        }
        ContrastWatcher.shared.override = nil
        // ---- the Settings window: the popup lists it, imports through the controller, refuses a file that is no scheme
        try await preservingSettings {
            SettingsWindowController.headless = true
            let c = SettingsWindowController.shared
            c.present()
            c.showScreen(.text)
            let src2 = t.write(base16DefaultLight, to: "schemes-src/default-light.yaml")
            t.check(c.importScheme(from: src2), "Import Scheme… with a light scheme succeeds")
            t.equal(EditorPreferences.colorSchemeID, "imported-default-light", "... and chooses it")
            t.equal(c.schemePopup.selectedItem?.representedObject as? String, "imported-default-light", "the popup shows it")
            let titles = c.schemePopup.menu?.items.map { $0.title } ?? []
            t.check(titles.contains("Imported") && titles.contains("Default Dark") && titles.contains("Default Light") && titles.contains("Import Scheme…") && titles.contains("Show Imported Schemes in Finder"), "the popup: an Imported section with both schemes, Import Scheme…, Show in Finder: \(titles.suffix(6))")
            t.check(ColorSchemes.all.filter { $0.family == "Imported" }.count == 2, "two imported schemes")
            let bad = t.write("not: a scheme\n", to: "schemes-src/bad.yaml")
            t.check(!c.importScheme(from: bad) && c.lastImportError != nil, "a file that is no scheme is refused with an error: \(c.lastImportError?.localizedDescription ?? "")")
            t.equal(EditorPreferences.colorSchemeID, "imported-default-light", "... the scheme in use stays")
            t.check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad.yaml").path), "... and nothing was copied")
            // the same file name again with another page colour: the scheme is rebuilt
            let changed = t.write(base16DefaultDark.replacingOccurrences(of: "base00: \"181818\"", with: "base00: \"202020\""), to: "schemes-src/default-dark.yaml")
            t.check(c.importScheme(from: changed), "importing a changed file of the same name")
            t.equal(ColorSchemes.all.filter { $0.family == "Imported" }.count, 2, "... replaces the scheme (still two)")
            t.equal(hex(rgba(Palette.background, NSAppearance(named: .darkAqua)!)), "#202020", "... with the new colours in use")
            // removed by hand: gone at the next look, the preference reads as the default
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("default-dark.yaml"))
            ColorSchemes.reloadImported()
            t.check(!ColorSchemes.all.contains { $0.id == "imported-default-dark" }, "a scheme whose file was deleted is gone after a reload")
            t.equal(EditorPreferences.colorSchemeID, ColorSchemes.defaultID, "... and the preference that named it reads as the default")
            EditorPreferences.colorSchemeID = "imported-default-light"
            t.equal(Palette.scheme.appearance, SchemeAppearance.light, "the light imported scheme forces the light appearance")
        }
    }
}
#endif
