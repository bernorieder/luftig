import AppKit

/// User preferences that apply to ALL open editor windows (font size, fonts, line spacing, readable column, colour scheme). Stored in
/// UserDefaults; every change is broadcast so every window rebuilds its theme / column. The Settings window (SettingsWindowController)
/// and the View menu are two views of the same values.
///
/// Every value read from UserDefaults is VALIDATED: a hostile or stale value (a string where a number belongs, NaN, a size from the
/// future, a colour scheme this version does not know) never crashes and never leaves the allowed range; it reads as the default or as
/// the nearest allowed value, and is NOT written back (the saved value stays until the user chooses something else). Every setter clamps
/// and ignores what is not finite, writes only when the value changes, and posts `didChange` once.
enum EditorPreferences {
    static let fontSizeKey = "LuftigFontSize"
    static let readableWidthKey = "LuftigReadableWidth"
    static let colorSchemeKey = "LuftigColorScheme"
    static let bodyFontFamilyKey = "LuftigBodyFontFamily"
    static let codeFontFamilyKey = "LuftigCodeFontFamily"
    static let lineHeightFactorKey = "LuftigLineHeightFactor"
    static let columnWidthKey = "LuftigColumnWidth"
    /// The three elements around the text (outline, word count, syntax bar): their font family (nil = the text font), size and opacity (Settings window).
    static let paneFontFamilyKey = "LuftigPaneFontFamily"
    static let paneFontSizeKey = "LuftigPaneFontSize"
    static let paneOpacityKey = "LuftigPaneOpacity"
    static let outlineWrapsKey = "LuftigOutlineWraps"
    /// Settings > Layout > Padding: ONE number of points for every gap in the editor (window frame, between the panels, inside the text's panel): what makes it luftig.
    static let paddingKey = "LuftigPaddingPoints"
    /// Settings > General: new documents open as tabs of the front window (NSWindow.tabbingMode .preferred) instead of windows of their own (.disallowed).
    static let openInTabsKey = "LuftigOpenInTabs"
    /// Settings > General: Return on a list item / quote line continues it; Tab / Shift-Tab nest and un-nest items (ListEditing.swift).
    static let continueListsKey = "LuftigContinueLists"
    /// Settings > General: what happens when another program changes the open file (MarkdownDocument+ExternalChanges.swift).
    static let reloadBehaviorKey = "LuftigReloadBehavior"
    /// Settings > Layout > Outline spacing: the height of an outline row as a multiple of its font's height.
    static let outlineLineHeightKey = "LuftigOutlineLineHeight"
    /// Every key the Settings window controls (Restore Defaults removes them all).
    static let allKeys = [fontSizeKey, readableWidthKey, colorSchemeKey, bodyFontFamilyKey, codeFontFamilyKey, lineHeightFactorKey, columnWidthKey, paneFontFamilyKey, paneFontSizeKey, paneOpacityKey, outlineWrapsKey, paddingKey, openInTabsKey, outlineLineHeightKey, continueListsKey, reloadBehaviorKey]
    /// The three elements around the text (View menu), not part of the Settings window.
    static let showOutlineKey = "LuftigShowOutline"
    static let showWordCountKey = "LuftigShowWordCount"
    static let showSyntaxBarKey = "LuftigShowSyntaxBar"
    /// View > Show Reading Time: in the word count's row (the row is shown when either is on).
    static let showReadingTimeKey = "LuftigShowReadingTime"
    /// View > Typewriter Mode (the caret's line stays in the middle of the window).
    static let typewriterModeKey = "LuftigTypewriterMode"
    /// The View menu's switches (not part of the Settings window's Restore Defaults).
    static let chromeKeys = [showOutlineKey, showWordCountKey, showSyntaxBarKey, showReadingTimeKey, typewriterModeKey]

    // MARK: one-time migration from the app's previous name

    /// luftig was called Scribe before (bundle id local.scribe.Scribe, keys "Scribe…"). Its settings are copied ONCE, the first time luftig
    /// starts; the old domain is only read, never written. Values are copied as they are: the getters below validate everything anyway.
    static let legacyDomain = "local.scribe.Scribe"
    static let legacyKeys: [(old: String, new: String)] = [
        ("ScribeFontSize", fontSizeKey), ("ScribeReadableWidth", readableWidthKey), ("ScribeColorScheme", colorSchemeKey),
        ("ScribeBodyFontFamily", bodyFontFamilyKey), ("ScribeCodeFontFamily", codeFontFamilyKey),
        ("ScribeLineHeightFactor", lineHeightFactorKey), ("ScribeColumnWidth", columnWidthKey),
    ]
    static let migratedKey = "LuftigMigratedFromScribe"

    /// Copies the legacy settings from the domain `oldDomain` into the domain `newDomain` unless that was done before, never overwriting a
    /// value the new domain already has. Works on the STORED domains (persistentDomain), not on UserDefaults lookups: a lookup also sees
    /// registered defaults (process-wide) and the global domain, which would make a key look already set. Returns the number of values copied.
    @discardableResult
    static func migrateLegacySettings(oldDomain: String = legacyDomain, newDomain: String) -> Int {
        let ud = UserDefaults.standard
        guard let result = migrated(current: ud.persistentDomain(forName: newDomain) ?? [:],
                                    legacy: ud.persistentDomain(forName: oldDomain) ?? [:]) else { return 0 }
        ud.setPersistentDomain(result.domain, forName: newDomain)
        return result.copied
    }

    /// luftig's bundle identifier was the placeholder `local.luftig.luftig` until the first public release (com.bernorieder.luftig): every `Luftig…` key
    /// of that domain is copied ONCE, the same way, never over a value the new domain has.
    static let placeholderDomain = "local.luftig.luftig"
    static let migratedFromPlaceholderKey = "LuftigMigratedFromPlaceholderID"

    @discardableResult
    static func migratePlaceholderSettings(oldDomain: String = placeholderDomain, newDomain: String) -> Int {
        let ud = UserDefaults.standard
        guard let result = migratedSameKeys(current: ud.persistentDomain(forName: newDomain) ?? [:],
                                            legacy: ud.persistentDomain(forName: oldDomain) ?? [:]) else { return 0 }
        ud.setPersistentDomain(result.domain, forName: newDomain)
        return result.copied
    }

    /// The copy of every `Luftig…` key (the settings and the View menu's switches; nothing of the system's), without any I/O; nil when done before.
    static func migratedSameKeys(current: [String: Any], legacy: [String: Any]) -> (domain: [String: Any], copied: Int)? {
        guard current[migratedFromPlaceholderKey] as? Bool != true else { return nil }
        var domain = current
        var copied = 0
        for (key, value) in legacy where key.hasPrefix("Luftig") && key != migratedKey && key != migratedFromPlaceholderKey && domain[key] == nil {
            domain[key] = value; copied += 1
        }
        domain[migratedFromPlaceholderKey] = true
        return (domain, copied)
    }

    /// The migration itself, without any I/O: the new domain's stored values after the copy, and how many values were copied;
    /// nil when the migration was done before (nothing to write).
    static func migrated(current: [String: Any], legacy: [String: Any]) -> (domain: [String: Any], copied: Int)? {
        guard current[migratedKey] as? Bool != true else { return nil }
        var domain = current
        var copied = 0
        for (oldKey, newKey) in legacyKeys where domain[newKey] == nil {
            if let v = legacy[oldKey] { domain[newKey] = v; copied += 1 }
        }
        domain[migratedKey] = true
        return (domain, copied)
    }

    static let defaultFontSize: CGFloat = 16
    static let fontSizeRange: ClosedRange<CGFloat> = 9...40
    /// The line-height slider (a multiple of the font size). The automatic curve (1.3 ... 1.5) lies inside it.
    static let lineHeightFactorRange: ClosedRange<CGFloat> = 1.1...2.0
    /// The text column of "Wrap to Readable Width", in points. 760 is what it always was.
    static let defaultColumnWidth: CGFloat = 760
    static let columnWidthRange: ClosedRange<CGFloat> = 480...1400
    /// Posted (object = nil) after any preference changed.
    static let didChange = Notification.Name("LuftigEditorPreferencesDidChange")

    private static var defaults: UserDefaults { .standard }

    // MARK: broadcasting (immediate, or bounded while a slider / stepper is being dragged)

    /// The least time between two broadcasts while a drag is in progress, and how long the main thread must have left over: after a broadcast that took
    /// `cost` seconds the next one waits `max(minimumAdjustingInterval, adjustingCostFactor * cost)`, so the drag itself (mouse events, the Settings preview,
    /// the labels) always has about half of the main thread (a 10 MB document costs ~70 ms per broadcast: one per ~140 ms, not one per mouse event).
    static let minimumAdjustingInterval = 0.040
    static let adjustingCostFactor = 1.0
    /// True between `beginAdjusting()` and `endAdjusting()`: a control is being dragged. Editors whose window nobody can see skip the broadcasts of this period
    /// (the last one, `endAdjusting()`, reaches every window).
    private(set) static var isAdjusting = false
    /// Broadcasts actually sent since launch (tests count them: a drag of many events must send few).
    private(set) static var broadcastCount = 0
    private static var pendingBroadcast = false
    private static var nextBroadcastAt = 0.0
    private static var coalescingTimer: Timer?

    private static func now() -> Double { CFAbsoluteTimeGetCurrent() }

    private static func post() {
        guard isAdjusting else { send(); return }
        let t = now()
        if t >= nextBroadcastAt { send() }
        else if !pendingBroadcast {
            pendingBroadcast = true
            // common modes: a drag runs the run loop in the event-tracking mode, where a default-mode timer would not fire until the mouse is released
            let timer = Timer(fireAt: Date(timeIntervalSinceReferenceDate: nextBroadcastAt), interval: 0, target: BroadcastTimerTarget.shared, selector: #selector(BroadcastTimerTarget.fire), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            coalescingTimer = timer
        }
    }

    /// Posts `didChange` now (what every change did before drags were coalesced) and works out when the next one may go out while a drag lasts.
    private static func send() {
        pendingBroadcast = false
        coalescingTimer?.invalidate(); coalescingTimer = nil
        let start = now()
        broadcastCount += 1
        NotificationCenter.default.post(name: didChange, object: nil)
        nextBroadcastAt = start + max(minimumAdjustingInterval, adjustingCostFactor * (now() - start))
    }

    fileprivate static func timerFired() {
        guard isAdjusting, pendingBroadcast else { return }
        send()                                     // reads the CURRENT preference values: a newer value is never replaced by an older one
    }

    /// A slider or stepper drag begins: from now on a change is broadcast at once if the last broadcast is old enough, else a little later (the newest
    /// values then), and editors in windows nobody can see wait for the end.
    static func beginAdjusting() {
        guard !isAdjusting else { return }
        isAdjusting = true
        pendingBroadcast = false
        nextBroadcastAt = 0
    }

    /// The drag is over: the FINAL values are broadcast now, to every editor (also those that skipped the drag because their window was not visible).
    /// Always one broadcast, also when nothing changed since the last one (editors compare and do nothing then).
    static func endAdjusting() {
        guard isAdjusting else { return }
        isAdjusting = false
        send()
    }

    // MARK: font size

    static var fontSize: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: fontSizeKey)
            return saved >= fontSizeRange.lowerBound ? min(CGFloat(saved), fontSizeRange.upperBound) : defaultFontSize
        }
        set {
            let v = min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, newValue))
            guard v != fontSize else { return }
            UserDefaults.standard.set(Double(v), forKey: fontSizeKey)
            post()
        }
    }

    // MARK: readable width

    /// "Wrap to Readable Width": centred column of at most `columnWidth` points. Default on.
    static var readableWidth: Bool {
        get { UserDefaults.standard.object(forKey: readableWidthKey) as? Bool ?? true }
        set {
            guard newValue != readableWidth else { return }
            UserDefaults.standard.set(newValue, forKey: readableWidthKey)
            post()
        }
    }

    /// Width of the centred column, `columnWidthRange`, default 760. Only in effect while `readableWidth` is on.
    static var columnWidth: CGFloat {
        get {
            guard let n = number(forKey: columnWidthKey), n.isFinite else { return defaultColumnWidth }
            return min(columnWidthRange.upperBound, max(columnWidthRange.lowerBound, CGFloat(n)))
        }
        set {
            guard newValue.isFinite else { return }
            let v = min(columnWidthRange.upperBound, max(columnWidthRange.lowerBound, newValue.rounded()))
            guard v != columnWidth else { return }
            defaults.set(Double(v), forKey: columnWidthKey)
            post()
        }
    }

    // MARK: the elements around the text (all on by default; anything stored that is not a Bool reads as the default)

    /// View > Show Outline: the headings of the document on the left.
    static var showOutline: Bool {
        get { flag(forKey: showOutlineKey, default: true) }
        set { setFlag(newValue, forKey: showOutlineKey, current: showOutline) }
    }
    /// View > Show Word Count: the number of words at the top right.
    static var showWordCount: Bool {
        get { flag(forKey: showWordCountKey, default: true) }
        set { setFlag(newValue, forKey: showWordCountKey, current: showWordCount) }
    }
    /// View > Show Syntax Bar: the Markdown elements at the bottom, inserted with a click.
    static var showSyntaxBar: Bool {
        get { flag(forKey: showSyntaxBarKey, default: true) }
        set { setFlag(newValue, forKey: showSyntaxBarKey, current: showSyntaxBar) }
    }
    /// View > Show Reading Time: "6 min read" (200 words a minute) next to the word count, or alone. Default off.
    static var showReadingTime: Bool {
        get { flag(forKey: showReadingTimeKey, default: false) }
        set { setFlag(newValue, forKey: showReadingTimeKey, current: showReadingTime) }
    }
    /// View > Typewriter Mode: the line with the caret is kept in the middle of the window. Default off.
    static var typewriterMode: Bool {
        get { flag(forKey: typewriterModeKey, default: false) }
        set { setFlag(newValue, forKey: typewriterModeKey, current: typewriterMode) }
    }

    // MARK: the panes' look (Settings window)

    static let defaultPaneFontSize: CGFloat = 12
    static let paneFontSizeRange: ClosedRange<CGFloat> = 9...20
    static let paneOpacityRange: ClosedRange<CGFloat> = 0.25...1.0

    /// Family of the panes' font; nil = the text font of the editor.
    static var paneFontFamily: String? {
        get { familyName(forKey: paneFontFamilyKey) }
        set { setFamily(newValue, forKey: paneFontFamilyKey, current: paneFontFamily) }
    }
    /// Size of the panes' text, `paneFontSizeRange`, default 12.
    static var paneFontSize: CGFloat {
        get {
            guard let n = number(forKey: paneFontSizeKey), n.isFinite else { return defaultPaneFontSize }
            return min(paneFontSizeRange.upperBound, max(paneFontSizeRange.lowerBound, CGFloat(n)))
        }
        set {
            guard newValue.isFinite else { return }
            let v = min(paneFontSizeRange.upperBound, max(paneFontSizeRange.lowerBound, (newValue * 2).rounded() / 2))
            guard v != paneFontSize else { return }
            defaults.set(Double(v), forKey: paneFontSizeKey)
            post()
        }
    }
    /// Opacity of the panes' text, `paneOpacityRange`, default 1 (the scheme's dim colour as it is; less = fainter).
    static var paneOpacity: CGFloat {
        get {
            guard let n = number(forKey: paneOpacityKey), n.isFinite else { return 1 }
            return min(paneOpacityRange.upperBound, max(paneOpacityRange.lowerBound, CGFloat(n)))
        }
        set {
            guard newValue.isFinite else { return }
            let v = min(paneOpacityRange.upperBound, max(paneOpacityRange.lowerBound, (newValue * 100).rounded() / 100))
            guard v != paneOpacity else { return }
            defaults.set(Double(v), forKey: paneOpacityKey)
            post()
        }
    }

    static let paddingRange: ClosedRange<CGFloat> = 0...50
    static let defaultPadding: CGFloat = 20
    /// The padding in points, `paddingRange`, default 20; 0 = everything touches. Every gap in `Padding` is this value.
    static var padding: CGFloat {
        get {
            guard let n = number(forKey: paddingKey), n.isFinite else { return defaultPadding }
            return min(paddingRange.upperBound, max(paddingRange.lowerBound, CGFloat(n).rounded()))
        }
        set {
            guard newValue.isFinite else { return }
            let v = min(paddingRange.upperBound, max(paddingRange.lowerBound, newValue.rounded()))
            guard v != padding else { return }
            defaults.set(Double(v), forKey: paddingKey)
            post()
        }
    }

    static let outlineLineHeightRange: ClosedRange<CGFloat> = 1.0...2.5
    static let defaultOutlineLineHeight: CGFloat = 1.4
    /// The outline's row height as a multiple of its font's height (ascent + descent), `outlineLineHeightRange`, default 1.4 (the look it always had).
    static var outlineLineHeight: CGFloat {
        get {
            guard let n = number(forKey: outlineLineHeightKey), n.isFinite else { return defaultOutlineLineHeight }
            return min(outlineLineHeightRange.upperBound, max(outlineLineHeightRange.lowerBound, CGFloat(n)))
        }
        set {
            guard newValue.isFinite else { return }
            let v = min(outlineLineHeightRange.upperBound, max(outlineLineHeightRange.lowerBound, (newValue * 20).rounded() / 20))     // steps of 0.05
            guard v != outlineLineHeight else { return }
            defaults.set(Double(v), forKey: outlineLineHeightKey)
            post()
        }
    }

    /// Settings > General > Open files in tabs. Default off: every document gets a window of its own (the system's "Prefer tabs" setting is not consulted).
    static var openInTabs: Bool {
        get { flag(forKey: openInTabsKey, default: false) }
        set { setFlag(newValue, forKey: openInTabsKey, current: openInTabs) }
    }
    /// The tabbing mode for the editor windows.
    static var tabbingMode: NSWindow.TabbingMode { openInTabs ? .preferred : .disallowed }

    /// Settings > General > Continue lists on Return. Default on.
    static var continueLists: Bool {
        get { flag(forKey: continueListsKey, default: true) }
        set { setFlag(newValue, forKey: continueListsKey, current: continueLists) }
    }

    /// Settings > General > When the file changes on disk.
    enum ReloadBehavior: String, CaseIterable {
        /// A clean document reloads silently, a dirty one merges (the look luftig always had).
        case automatic
        /// A banner offers Reload from Disk / Keep My Version; nothing is applied by itself.
        case ask
        /// The change is not shown; saving over it asks first (the overwrite sheet).
        case never
        var title: String {
            switch self {
            case .automatic: return "Reload automatically"
            case .ask: return "Ask first"
            case .never: return "Never reload"
            }
        }
        var note: String {
            switch self {
            case .automatic: return "Changes made by other programs appear at once (merged with yours when both edited)."
            case .ask: return "A banner offers to reload or to keep your version."
            case .never: return "The file is left alone; saving over a changed file asks first."
            }
        }
    }
    /// What happens when another program changes the open file. Default: reload automatically; an unknown stored value reads as the default.
    static var reloadBehavior: ReloadBehavior {
        get { (defaults.object(forKey: reloadBehaviorKey) as? String).flatMap { ReloadBehavior(rawValue: $0) } ?? .automatic }
        set {
            guard newValue != reloadBehavior else { return }
            defaults.set(newValue.rawValue, forKey: reloadBehaviorKey)
            post()
        }
    }

    /// Settings > Layout > Outline: long headings wrap onto further lines instead of being cut off. Default off.
    static var outlineWraps: Bool {
        get { flag(forKey: outlineWrapsKey, default: false) }
        set { setFlag(newValue, forKey: outlineWrapsKey, current: outlineWraps) }
    }

    private static func flag(forKey key: String, default d: Bool) -> Bool {
        guard let v = defaults.object(forKey: key), CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { return d }
        return (v as? Bool) ?? d
    }
    private static func setFlag(_ new: Bool, forKey key: String, current: Bool) {
        guard new != current else { return }
        defaults.set(new, forKey: key)
        post()
    }

    // MARK: fonts and line spacing

    /// Family of the text font; nil = the system font. May name a family that is not installed any more (the theme then uses the system font
    /// and the saved name stays, so the font is back when it is installed again).
    static var bodyFontFamily: String? {
        get { familyName(forKey: bodyFontFamilyKey) }
        set { setFamily(newValue, forKey: bodyFontFamilyKey, current: bodyFontFamily) }
    }

    /// Family of the code font (code blocks, inline code, tables, front matter); nil = the system monospaced font.
    static var codeFontFamily: String? {
        get { familyName(forKey: codeFontFamilyKey) }
        set { setFamily(newValue, forKey: codeFontFamilyKey, current: codeFontFamily) }
    }

    /// Body line box as a multiple of the font size, `lineHeightFactorRange`; nil = automatic (`Theme.lineHeightRatio`, the look luftig always had).
    static var lineHeightFactor: CGFloat? {
        get {
            guard let n = number(forKey: lineHeightFactorKey), n.isFinite, n > 0 else { return nil }
            return min(lineHeightFactorRange.upperBound, max(lineHeightFactorRange.lowerBound, CGFloat(n)))
        }
        set {
            var v: CGFloat?
            if let n = newValue { guard n.isFinite else { return }; v = min(lineHeightFactorRange.upperBound, max(lineHeightFactorRange.lowerBound, (n * 100).rounded() / 100)) }
            guard v != lineHeightFactor else { return }
            if let v { defaults.set(Double(v), forKey: lineHeightFactorKey) } else { defaults.removeObject(forKey: lineHeightFactorKey) }
            post()
        }
    }

    /// Everything a `Theme` is built from.
    static var themeSettings: ThemeSettings {
        ThemeSettings(baseSize: fontSize, bodyFamily: bodyFontFamily, codeFamily: codeFontFamily, lineHeightFactor: lineHeightFactor)
    }

    // MARK: colour scheme

    /// The id of the colour scheme (`ColorSchemes.all`); an id this version does not know reads as the default. Setting it applies the scheme
    /// to the palette BEFORE the notification goes out, so every editor that rebuilds finds the new colours.
    static var colorSchemeID: String {
        get {
            guard let id = defaults.object(forKey: colorSchemeKey) as? String, ColorSchemes.all.contains(where: { $0.id == id }) else { return ColorSchemes.defaultID }
            return id
        }
        set {
            let v = ColorSchemes.all.contains(where: { $0.id == newValue }) ? newValue : ColorSchemes.defaultID
            guard v != colorSchemeID else { return }
            defaults.set(v, forKey: colorSchemeKey)
            Palette.apply(schemeID: v)
            post()
        }
    }

    // MARK: all at once

    /// The imported schemes were read again (an import, the Settings window opening): the scheme in use is applied afresh - it may have been rebuilt
    /// from a changed file, or its file may be gone (the default then) - and every window follows. The setter alone would not do it: the id is unchanged.
    static func colorSchemesReloaded() {
        Palette.apply(schemeID: activeSchemeID)
        post()
    }

    /// The scheme the editors show: the draft of Settings > Colors while there is one (never stored), else the chosen scheme.
    static var activeSchemeID: String { ColorSchemes.draft != nil ? CustomScheme.draftID : colorSchemeID }

    /// Settings > Colors changed or dropped the draft: the editors follow (the palette switches, every window rebuilds).
    static func schemeDraftChanged() {
        Palette.apply(schemeID: activeSchemeID)
        post()
    }

    /// Settings > Restore Defaults: every preference of the Settings window back to its default, ONE notification.
    static func restoreDefaults() {
        for key in allKeys { defaults.removeObject(forKey: key) }
        Palette.apply(schemeID: ColorSchemes.defaultID)
        post()
    }

    // MARK: validated reading

    /// A number stored as a number or as a numeric string; nil for anything else (a Bool, an array, text, nothing).
    private static func number(forKey key: String) -> Double? {
        guard let v = defaults.object(forKey: key) else { return nil }
        if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// A family name worth keeping: a non-empty string without control characters, of sane length. Anything else is "no choice" (nil).
    static func sanitizedFamily(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.utf16.count <= 120,
              !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0xFFFD }) else { return nil }
        return t
    }

    private static func familyName(forKey key: String) -> String? { sanitizedFamily(defaults.object(forKey: key) as? String) }

    private static func setFamily(_ new: String?, forKey key: String, current: String?) {
        let v = sanitizedFamily(new)
        guard v != current else { return }
        if let v { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
        post()
    }
}

/// Target of the coalescing timer (a `Timer` needs an Objective-C target; the enum has none).
private final class BroadcastTimerTarget: NSObject {
    static let shared = BroadcastTimerTarget()
    @objc func fire() { EditorPreferences.timerFired() }
}
