#if LUFTIG_SELFTEST
// SelfTestSettingsPrefs.swift - settings-prefs: the preferences behind the Settings window (EditorPreferences).

import AppKit

extension SelfTestScenarios {

    @MainActor static func settingsPrefs(_ t: SelfTest.T) async throws {
        await preservingSettings {
            let ud = UserDefaults.standard
            let P = EditorPreferences.self

            // ---- the key names are part of the contract (they are what `defaults read` shows and what an older / newer build finds)
            t.equal(P.colorSchemeKey, "LuftigColorScheme", "key: colour scheme")
            t.equal(P.bodyFontFamilyKey, "LuftigBodyFontFamily", "key: text font family")
            t.equal(P.codeFontFamilyKey, "LuftigCodeFontFamily", "key: code font family")
            t.equal(P.lineHeightFactorKey, "LuftigLineHeightFactor", "key: line-height factor")
            t.equal(P.columnWidthKey, "LuftigColumnWidth", "key: column width")
            t.equal(P.fontSizeKey, "LuftigFontSize", "key: font size (unchanged)")
            t.equal(P.readableWidthKey, "LuftigReadableWidth", "key: readable width flag (unchanged)")

            // ---- defaults: nothing stored
            t.equal(P.colorSchemeID, ColorSchemes.defaultID, "default colour scheme is the luftig scheme (\"luftig\")")
            t.equal(ColorSchemes.defaultID, "luftig", "the default scheme id is \"luftig\"")
            t.check(P.bodyFontFamily == nil && P.codeFontFamily == nil, "default fonts: the system fonts (nil)")
            t.check(P.lineHeightFactor == nil, "default line spacing: automatic (nil)")
            t.equal(P.columnWidth, 760, "default column width 760 pt (what it always was)")
            t.check(P.readableWidth, "default: the column is on")
            t.equal(P.themeSettings, ThemeSettings(baseSize: 16, bodyFamily: nil, codeFamily: nil, lineHeightFactor: nil), "default theme settings")
            t.equal(P.columnWidthRange, 480...1400, "column width range 480...1400")
            t.equal(P.lineHeightFactorRange, 1.1...2.0, "line spacing range 1.1...2.0")

            // ---- round trips: persisted under the exact key, read back, ONE notification per change, none for a no-op
            let n = NoteCounter()
            let other = ColorSchemes.all.first { $0.id != ColorSchemes.defaultID }
            t.check(other != nil, "set-up: the scheme list has a scheme besides the default (\(ColorSchemes.all.count) in all)")
            if let other {
                var seenAtPost: String?
                let probe = NotificationCenter.default.addObserver(forName: P.didChange, object: nil, queue: nil) { _ in seenAtPost = Palette.scheme.id }
                defer { NotificationCenter.default.removeObserver(probe) }
                let c0 = n.count
                P.colorSchemeID = other.id
                t.equal(P.colorSchemeID, other.id, "colour scheme round trip")
                t.equal(ud.string(forKey: "LuftigColorScheme"), other.id, "... stored as a string under LuftigColorScheme")
                t.equal(n.count - c0, 1, "... one notification")
                t.equal(seenAtPost, other.id, "... and the palette already had the scheme when the notification went out")
                P.colorSchemeID = other.id
                t.equal(n.count - c0, 1, "... setting the same scheme again posts nothing")
                P.colorSchemeID = "no-such-scheme"
                t.equal(P.colorSchemeID, ColorSchemes.defaultID, "an unknown scheme id falls back to the default")
                t.equal(Palette.scheme.id, ColorSchemes.defaultID, "... and the palette follows")
                P.colorSchemeID = ColorSchemes.defaultID
                t.equal(n.count - c0, 2, "... (two changes so far: to the scheme, back to the default)")
            }

            var c = n.count
            P.bodyFontFamily = "Georgia"
            t.equal(P.bodyFontFamily, "Georgia", "text font round trip")
            t.equal(ud.string(forKey: "LuftigBodyFontFamily"), "Georgia", "... stored as a string under LuftigBodyFontFamily")
            t.equal(n.count - c, 1, "... one notification")
            P.bodyFontFamily = "Georgia"
            t.equal(n.count - c, 1, "... the same value again posts nothing")
            P.bodyFontFamily = "  Palatino \n"
            t.equal(P.bodyFontFamily, "Palatino", "a family name is trimmed")
            P.bodyFontFamily = nil
            t.check(P.bodyFontFamily == nil && ud.object(forKey: "LuftigBodyFontFamily") == nil, "nil removes the key (back to the system font)")
            P.bodyFontFamily = "Georgia"
            P.bodyFontFamily = ""
            t.check(P.bodyFontFamily == nil && ud.object(forKey: "LuftigBodyFontFamily") == nil, "an empty name is no choice")
            P.bodyFontFamily = "Georgia"
            P.bodyFontFamily = String(repeating: "x", count: 500)
            t.check(P.bodyFontFamily == nil, "a 500-character 'family' is refused (no choice)")
            P.bodyFontFamily = nil

            c = n.count
            P.codeFontFamily = "Menlo"
            t.equal(P.codeFontFamily, "Menlo", "code font round trip")
            t.equal(ud.string(forKey: "LuftigCodeFontFamily"), "Menlo", "... stored under LuftigCodeFontFamily")
            t.equal(n.count - c, 1, "... one notification")
            P.codeFontFamily = nil
            t.check(P.codeFontFamily == nil && ud.object(forKey: "LuftigCodeFontFamily") == nil, "code font: nil removes the key")

            c = n.count
            P.lineHeightFactor = 1.5
            t.equal(P.lineHeightFactor, 1.5, "line spacing round trip")
            t.equal(ud.double(forKey: "LuftigLineHeightFactor"), 1.5, "... stored as a number under LuftigLineHeightFactor")
            t.equal(n.count - c, 1, "... one notification")
            P.lineHeightFactor = 1.5
            t.equal(n.count - c, 1, "... the same value again posts nothing")
            P.lineHeightFactor = 1.456
            t.equal(P.lineHeightFactor, 1.46, "line spacing is kept to two decimals (the slider's resolution)")
            P.lineHeightFactor = 0.2
            t.equal(P.lineHeightFactor, 1.1, "line spacing 0.2 clamps to 1.1")
            P.lineHeightFactor = 7
            t.equal(P.lineHeightFactor, 2.0, "line spacing 7 clamps to 2.0")
            P.lineHeightFactor = -3
            t.equal(P.lineHeightFactor, 1.1, "line spacing -3 clamps to 1.1")
            c = n.count
            P.lineHeightFactor = .nan
            P.lineHeightFactor = .infinity
            P.lineHeightFactor = -.infinity
            t.check(P.lineHeightFactor == 1.1 && n.count == c, "NaN / infinity are ignored (value stays \(P.lineHeightFactor ?? 0), no notification)")
            P.lineHeightFactor = nil
            t.check(P.lineHeightFactor == nil && ud.object(forKey: "LuftigLineHeightFactor") == nil, "nil = automatic removes the key")

            c = n.count
            P.columnWidth = 900
            t.equal(P.columnWidth, 900, "column width round trip")
            t.equal(ud.double(forKey: "LuftigColumnWidth"), 900, "... stored as a number under LuftigColumnWidth")
            t.equal(n.count - c, 1, "... one notification")
            P.columnWidth = 900
            t.equal(n.count - c, 1, "... the same value again posts nothing")
            P.columnWidth = 777.6
            t.equal(P.columnWidth, 778, "column width is whole points")
            P.columnWidth = 10
            t.equal(P.columnWidth, 480, "column width 10 clamps to 480")
            P.columnWidth = 1e9
            t.equal(P.columnWidth, 1400, "column width 1e9 clamps to 1400")
            c = n.count
            P.columnWidth = .nan
            P.columnWidth = .infinity
            t.check(P.columnWidth == 1400 && n.count == c, "NaN / infinity are ignored (value stays \(P.columnWidth), no notification)")

            // ---- the theme settings gather them
            P.fontSize = 19
            P.bodyFontFamily = "Georgia"
            P.codeFontFamily = "Menlo"
            P.lineHeightFactor = 1.7
            t.equal(P.themeSettings, ThemeSettings(baseSize: 19, bodyFamily: "Georgia", codeFamily: "Menlo", lineHeightFactor: 1.7), "themeSettings = size + both families + factor")

            // ---- Restore Defaults: everything back, ONE notification
            P.readableWidth = false
            if let other { P.colorSchemeID = other.id }
            c = n.count
            P.restoreDefaults()
            t.equal(n.count - c, 1, "restoreDefaults posts one notification")
            let persistent = ud.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]       // what is STORED (registered defaults do not count)
            t.check(EditorPreferences.allKeys.allSatisfy { persistent[$0] == nil }, "... and leaves no preference behind: \(EditorPreferences.allKeys.filter { persistent[$0] != nil })")
            t.check(P.themeSettings == ThemeSettings(baseSize: 16) && P.columnWidth == 760 && P.readableWidth && P.colorSchemeID == ColorSchemes.defaultID, "... every value is the default again")
            t.equal(Palette.scheme.id, ColorSchemes.defaultID, "... and the palette is the default scheme")

            // ---- hostile stored values: nothing crashes, nothing escapes the allowed range, nothing is written back
            let numbers: [(String, Any)] = [("string", "abc"), ("numeric string", "800"), ("zero", 0.0), ("negative", -5.0), ("tiny", 1e-9), ("huge", 1e300), ("+inf", Double.infinity),
                                            ("-inf", -Double.infinity), ("NaN", Double.nan), ("array", [1, 2]), ("dict", ["a": 1]), ("bool true", true), ("bool false", false),
                                            ("data", Data([1, 2, 3])), ("date", Date()), ("in range", 1.33)]
            for (label, value) in numbers {
                ud.set(value, forKey: P.columnWidthKey)
                let w = P.columnWidth
                t.check(w.isFinite && P.columnWidthRange.contains(w), "column width default '\(label)' -> \(w) stays inside \(P.columnWidthRange)")
                ud.set(value, forKey: P.lineHeightFactorKey)
                let f = P.lineHeightFactor
                t.check(f == nil || (f!.isFinite && P.lineHeightFactorRange.contains(f!)), "line spacing default '\(label)' -> \(f.map { "\($0)" } ?? "automatic") is automatic or inside \(P.lineHeightFactorRange)")
                let theme = Theme(settings: P.themeSettings)
                t.check(theme.baseAttributes[.font] != nil && theme.bodyLineHeight > 0, "a Theme can be built from them")
            }
            ud.set(Double.nan, forKey: P.columnWidthKey)
            t.check(ud.object(forKey: P.columnWidthKey) != nil, "a hostile value is read as a default but not written back (the stored value stays)")
            let strings: [(String, Any)] = [("number", 42), ("empty", ""), ("spaces", "   "), ("NUL inside", "Foo\u{0}Bar"), ("newline", "Foo\nBar"), ("500 characters", String(repeating: "x", count: 500)),
                                            ("array", ["Georgia"]), ("dict", ["a": "b"]), ("emoji", "😀"), ("replacement character", "\u{FFFD}"), ("bool", true), ("path-like", "../../etc/passwd"), ("not installed", "No Such Family 12345")]
            for (label, value) in strings {
                for key in [P.bodyFontFamilyKey, P.codeFontFamilyKey] {
                    ud.set(value, forKey: key)
                    let f = key == P.bodyFontFamilyKey ? P.bodyFontFamily : P.codeFontFamily
                    t.check(f == nil || (f!.utf16.count <= 120 && !f!.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }), "\(key == P.bodyFontFamilyKey ? "text" : "code") font default '\(label)' -> \(f.map { "\"\($0)\"" } ?? "none") is none or a sane name")
                }
                let theme = Theme(settings: P.themeSettings)
                t.check(theme.baseAttributes[.font] != nil && (theme.bodyFont.pointSize == 16), "a Theme can be built from them (\(theme.bodyFamily ?? "system font") / \(theme.codeFamily ?? "system mono"))")
            }
            let schemes: [(String, Any)] = [("number", 42), ("empty", ""), ("unknown", "nope"), ("array", ["luftig"]), ("wrong case", "SCRIBE"), ("bool", true), ("dict", ["a": 1])]
            for (label, value) in schemes {
                ud.set(value, forKey: P.colorSchemeKey)
                t.check(ColorSchemes.all.contains { $0.id == P.colorSchemeID }, "colour scheme default '\(label)' -> \"\(P.colorSchemeID)\" is a scheme this build has")
            }
            ud.set("luftig", forKey: P.colorSchemeKey)
            t.check(ud.object(forKey: P.colorSchemeKey) != nil, "a stale scheme id stays stored (it may be a scheme of another build)")
        }
    }

    // MARK: settings-launch

    /// What the real AppDelegate does at launch: the stored colour scheme is in force before any window exists, the defaults are registered, the menu has Settings….
    /// (The in-process runner has its own delegate; this calls the real one's `applicationWillFinishLaunching` and puts the menu back.)
    @MainActor static func settingsLaunch(_ t: SelfTest.T) async throws {
        await preservingSettings {
            let ud = UserDefaults.standard
            let menu = NSApp.mainMenu, services = NSApp.servicesMenu, windows = NSApp.windowsMenu, help = NSApp.helpMenu
            defer { NSApp.mainMenu = menu; NSApp.servicesMenu = services; NSApp.windowsMenu = windows; NSApp.helpMenu = help }
            guard let other = ColorSchemes.all.first(where: { $0.id != ColorSchemes.defaultID }) else { t.check(false, "no second scheme"); return }
            ud.set(other.id, forKey: EditorPreferences.colorSchemeKey)          // stored by an earlier session, the palette still has the default
            Palette.apply(schemeID: ColorSchemes.defaultID)
            t.equal(Palette.scheme.id, ColorSchemes.defaultID, "set-up: the palette starts with the default scheme")
            AppDelegate().applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            t.equal(Palette.scheme.id, other.id, "launch: the stored colour scheme (\(other.id)) is applied to the palette in applicationWillFinishLaunching, before any window exists")
            let registered = ud.volatileDomain(forName: UserDefaults.registrationDomain)
            t.equal(registered[EditorPreferences.colorSchemeKey] as? String, ColorSchemes.defaultID, "launch: the default colour scheme is registered")
            t.equal(registered[EditorPreferences.columnWidthKey] as? Double, Double(EditorPreferences.defaultColumnWidth), "launch: the default column width is registered")
            t.equal(registered[EditorPreferences.readableWidthKey] as? Bool, true, "launch: the readable-width default is still registered")
            t.check(NSApp.mainMenu?.items.first?.submenu?.items.contains { $0.title == "Settings…" && $0.keyEquivalent == "," } == true, "launch: the menu the delegate installs has Settings… (⌘,)")
            ud.set("no-such-scheme", forKey: EditorPreferences.colorSchemeKey)
            AppDelegate().applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            t.equal(Palette.scheme.id, ColorSchemes.defaultID, "launch: a stored scheme this build does not know starts the default scheme (and the stored value stays)")
            t.equal(ud.string(forKey: EditorPreferences.colorSchemeKey), "no-such-scheme", "... it is not overwritten")
        }
    }
}
#endif
