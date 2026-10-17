#if LUFTIG_SELFTEST
// SelfTestSettings.swift - the Settings window and everything it controls: fonts, size, line spacing, column width, colour scheme.
//
//   settings-prefs       (SelfTestSettingsPrefs.swift)   persistence round trips, clamping, hostile UserDefaults, notifications
//   settings-apply       (SelfTestSettingsEditor.swift)  every setting reaches two open windows (and one opened later), nothing is rebuilt needlessly
//   settings-oracle      (SelfTestSettingsEditor.swift)  random typing + scrolling + settings changes, then every character == fresh Theme(settings) + lexAll
//   settings-lineboxes   (SelfTestSettingsEditor.swift)  line boxes uniform and never smaller than the fonts, 12 families x 3 factors x 3 sizes
//   settings-faces       (SelfTestSettingsEditor.swift)  families without italic / bold faces, families that are not installed
//   settings-perf        (SelfTestSettingsEditor.swift)  opening, typing and a settings change with non-default settings vs the DESIGN.md budget
//   settings-launch      (SelfTestSettingsPrefs.swift)   the real AppDelegate: stored scheme applied at launch, defaults registered, menu item
//   settings-window      (SelfTestSettingsWindow.swift)  the window opens, is a singleton, its controls drive the preferences, the preview == a fresh restyle
//   settings-defaults    (SelfTestSettingsWindow.swift)  Restore Defaults brings back the default LOOK, byte for byte
//   settings-render      (internal) PNG of the Settings window: --out f.png [--appearance dark|light] [--scheme id] [--body-font F] [--code-font F]
//                        [--font-size N] [--line-spacing X] [--column-width W] [--no-readable-width] [--width W]

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let settingsScenarios: [SelfTest.Scenario] = [
        .init(name: "settings-prefs", summary: "Settings: persistence round trips, clamping, hostile UserDefaults values, one notification per change, scheme applied before it", run: { t in try await settingsPrefs(t) }),
        .init(name: "settings-apply", summary: "Settings: fonts, size, line spacing, column width, scheme reach two open windows and one opened later; nothing is rebuilt needlessly", run: { t in try await settingsApply(t) }),
        .init(name: "settings-oracle", summary: "Settings: random edits / scrolls / settings changes with a non-default family, factor and size, then every character == fresh Theme + lexAll", run: { t in try await settingsOracle(t) }),
        .init(name: "settings-lineboxes", summary: "Settings: uniform line boxes never smaller than the fonts: 12 families x 3 factors x 3 sizes (Zapfino, Menlo, ...)", run: { t in try await settingsLineBoxes(t) }),
        .init(name: "settings-faces", summary: "Settings: synthetic italic / bold for families without those faces, a family that is not installed keeps its saved name", run: { t in try await settingsFaces(t) }),
        .init(name: "settings-perf", summary: "Settings: open / typing / settings change with non-default fonts, size and spacing within the DESIGN.md budget", run: { t in try await settingsPerf(t) }),
        .init(name: "settings-window", summary: "Settings window: singleton, controls drive the preferences and every editor, preview == fresh restyle, light / dark x every scheme", run: { t in try await settingsWindow(t) }),
        .init(name: "settings-defaults", summary: "Settings: Restore Defaults brings back the default look byte for byte (attributes of the whole document, vs the baseline rules)", run: { t in try await settingsDefaults(t) }),
        .init(name: "settings-launch", summary: "Settings: the real AppDelegate applies the stored colour scheme at launch, registers the defaults and installs Settings… (⌘,)", run: { t in try await settingsLaunch(t) }),
        .init(name: "settings-migration", summary: "Settings: the one-time copy from the app's previous name (Scribe) - values, once only, never overwriting, old domain untouched, never in a self-test build", run: { t in try await settingsMigration(t) }),
        .init(name: "settings-render", summary: "(internal) PNG of the Settings window: --out f.png [--appearance dark|light] [--scheme id] [--body-font F] [--code-font F] [--font-size N] [--line-spacing X] [--column-width W] [--width W]",
              run: { t in try await settingsRender(t) }, inAll: false),
    ]

    // MARK: fixtures

    /// Every construct the Theme styles, ASCII only (the line-box scenarios measure the fonts the Theme chose, not AppKit's fallback fonts for CJK / emoji).
    static let settingsSampleBlock = """
    ---
    title: Sample
    ---

    # Heading one with `code`
    ## Heading two with *italic* and **bold**
    ### Heading three
    #### Heading four
    ##### Heading five

    Setext title
    ============

    A paragraph with **bold**, *italic*, ***both***, ~~strike~~, `inline code`, **`bold code`** and a [link](https://example.com).
    It continues on a second line, long enough to wrap in a narrow column so that the continuation lines are measured as well.

    - item one
      - nested item
    - [ ] open task
    - [x] done task
    1. first
    2. second

    > quote line one
    > > nested quote with **bold**
    > - item in a quote

    ```swift
    let x = 1
    	tabbed
    ```

        indented code

    ---

    | a | b |
    |---|---|
    | 1 | **2** |

    """

    /// The sample repeated `times` times (a long document: the lines far below the viewport are never styled or laid out until something asks).
    static func settingsDocument(times: Int) -> String { String(repeating: settingsSampleBlock + "\n", count: times) }

    /// The names that are installed on this machine, in the given order.
    static func installedFamilies(_ names: [String]) -> [String] { names.filter { FontFactory.resolve($0) != nil } }

    /// Some installed family that is neither of the two a test already uses (the machine may lack the usual ones).
    static func anyFamily(not excluded: [String?] = [], monospaced: Bool = false) -> String? {
        let all = FontFactory.installedFamilies()
        let pool = monospaced ? FontFactory.monospacedFamilies(among: all) : all
        return pool.first { !excluded.contains($0) }
    }

    /// Counts `EditorPreferences.didChange` posts.
    final class NoteCounter {
        private(set) var count = 0
        private var token: NSObjectProtocol?
        init() { token = NotificationCenter.default.addObserver(forName: EditorPreferences.didChange, object: nil, queue: nil) { [unowned self] _ in count += 1 } }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    /// Saves the preferences the Settings scenarios change and puts them back (also the Palette): a scenario leaves the domain as it found it.
    /// Starts from the defaults.
    @MainActor static func preservingSettings(_ body: @MainActor () async throws -> Void) async rethrows {
        let ud = UserDefaults.standard
        let saved = EditorPreferences.allKeys.map { ($0, ud.object(forKey: $0)) }
        for k in EditorPreferences.allKeys { ud.removeObject(forKey: k) }
        Palette.apply(schemeID: ColorSchemes.defaultID)
        defer {
            for (k, v) in saved { if let v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } }
            Palette.apply(schemeID: EditorPreferences.colorSchemeID)
            NotificationCenter.default.post(name: EditorPreferences.didChange, object: nil)
        }
        try await body()
    }

    // MARK: render

    @MainActor static func settingsRender(_ t: SelfTest.T) async throws {
        guard let out = SelfTest.argument("out") else { t.check(false, "usage: --selftest settings-render --out f.png [--appearance dark|light] [--scheme id] [--body-font F] [--code-font F] [--font-size N] [--line-spacing X] [--column-width W] [--no-readable-width] [--width W]"); return }
        try await preservingSettings {
            SettingsWindowController.headless = true
            if let id = SelfTest.argument("scheme") { EditorPreferences.colorSchemeID = id }
            if let f = SelfTest.argument("body-font") { EditorPreferences.bodyFontFamily = f }
            if let f = SelfTest.argument("code-font") { EditorPreferences.codeFontFamily = f }
            if let v = SelfTest.argument("font-size").flatMap({ Double($0) }) { EditorPreferences.fontSize = CGFloat(v) }
            if let v = SelfTest.argument("line-spacing").flatMap({ Double($0) }) { EditorPreferences.lineHeightFactor = CGFloat(v) }
            if let v = SelfTest.argument("column-width").flatMap({ Double($0) }) { EditorPreferences.columnWidth = CGFloat(v) }
            if SelfTest.flag("no-readable-width") { EditorPreferences.readableWidth = false }
            let c = SettingsWindowController.shared
            c.present()
            guard let window = c.window else { t.check(false, "no settings window"); return }
            // a fixed (light / dark) colour scheme sets the appearance of the whole app (Palette.apply): the window then inherits it, as in the real app;
            // only the system scheme follows `--appearance`
            window.appearance = Palette.isSystemScheme ? NSAppearance(named: SelfTest.appearanceName(SelfTest.argument("appearance"))) : nil
            if let w = SelfTest.argument("width").flatMap({ Double($0) }) { window.setContentSize(NSSize(width: w, height: window.contentView?.frame.height ?? 700)) }
            window.contentView?.layoutSubtreeIfNeeded()
            c.syncFromPreferences()
            await t.sleep(80)
            window.contentView?.layoutSubtreeIfNeeded()
            let tv = c.preview.textView
            _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
            guard let png = t.renderPNG(window) else { t.check(false, "could not render"); return }
            try png.write(to: URL(fileURLWithPath: out))
            t.check(true, "rendered the Settings window \(Int(window.contentView?.bounds.width ?? 0)) x \(Int(window.contentView?.bounds.height ?? 0)) pt (\(Palette.isSystemScheme ? (SelfTest.argument("appearance") ?? "light") : "scheme " + Palette.scheme.id)) -> \(out) (\(png.count / 1024) KB)")
        }
    }
}

// MARK: the oracle for arbitrary settings

extension StyleOracle {
    /// `expectedRuns(text:baseSize:)` for a Theme built from any settings: a FRESH Theme + a fresh `MarkdownStyler.lexAll`.
    static func expectedRuns(text: NSString, settings: ThemeSettings) -> (runs: [StyledRun], mdRuns: [MDRun]) {
        let theme = Theme(settings: settings)
        let md = MarkdownStyler().lexAll(text)
        return (theme.styledRuns(md, text: text), md)
    }

    /// `compare(storage:baseSize:)` for a Theme built from any settings (the same comparison, character by character).
    static func compare(storage: NSTextStorage, settings: ThemeSettings, range: NSRange? = nil, maxReport: Int = 5) -> (checkedRuns: Int, mismatches: Int, first: [Mismatch]) {
        let text = storage.string as NSString
        let (expected, md) = expectedRuns(text: text, settings: settings)
        let window = range ?? NSRange(location: 0, length: storage.length)
        var checked = 0, bad = 0
        var first: [Mismatch] = []
        func lexStyle(at loc: Int) -> MDStyle {
            var lo = 0, hi = md.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if md[mid].range.location <= loc { lo = mid } else { hi = mid - 1 } }
            return md.isEmpty ? MDStyle() : md[lo].style
        }
        for run in expected {
            let r = NSIntersectionRange(run.range, window)
            if r.length == 0 { continue }
            checked += 1
            var pos = r.location
            var ok = true
            var badActual = [NSAttributedString.Key: Any]()
            while pos < NSMaxRange(r) {
                var eff = NSRange(location: 0, length: 0)
                let a = storage.attributes(at: pos, longestEffectiveRange: &eff, in: NSRange(location: pos, length: NSMaxRange(r) - pos))
                var nonASCII = false
                for i in eff.location..<NSMaxRange(eff) where text.character(at: i) > 0x7F { nonASCII = true; break }
                if !attributesEqual(a, run.attributes, allowFontFallback: nonASCII) { ok = false; badActual = a; break }
                pos = NSMaxRange(eff)
                if eff.length == 0 { break }
            }
            if !ok {
                bad += 1
                if first.count < maxReport {
                    let sample = text.substring(with: NSRange(location: r.location, length: min(24, r.length))).debugDescription
                    first.append(Mismatch(range: r, expected: "\(lexStyle(at: r.location)) \(describe(run.attributes))", actual: "\(describe(badActual)) text=\(sample)"))
                }
            }
        }
        return (checked, bad, first)
    }
}
#endif
