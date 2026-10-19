#if LUFTIG_SELFTEST
// SelfTestSettingsMigration.swift - the one-time copy of the settings of the app's previous name (Scribe, local.scribe.Scribe).
// The migration logic is tested in memory (EditorPreferences.migrated): no throwaway preference domains, which cfprefsd would write
// to ~/Library/Preferences after the process exits whatever the test deletes. The thin I/O wrapper is run once against this self-test
// bundle's own private domain, and the marker it writes is removed again.

import AppKit

extension SelfTestScenarios {
    @MainActor static func settingsMigration(_ t: SelfTest.T) async throws {
        typealias P = EditorPreferences
        // the old app's settings (the user's configuration at the time of the rename, minus the code font)
        let legacy: [String: Any] = ["ScribeFontSize": 14.0, "ScribeColorScheme": "github-dark", "ScribeBodyFontFamily": "Fira Code",
                                     "ScribeLineHeightFactor": 1.1, "ScribeColumnWidth": 900.0, "ScribeReadableWidth": false]

        t.equal(P.legacyDomain, "local.scribe.Scribe", "the legacy domain is the old app's bundle id")
        t.check(Set(P.legacyKeys.map { $0.new }).isSubset(of: Set(P.allKeys)), "every legacy key maps to a Settings key (the panes' keys are newer than the rename: nothing to copy for them)")

        guard let r = P.migrated(current: [:], legacy: legacy) else { t.check(false, "first migration ran"); return }
        let new = r.domain
        t.equal(r.copied, 6, "6 legacy values copied (the code font was never set)")
        t.equal(new[P.fontSizeKey] as? Double, 14, "font size copied")
        t.equal(new[P.colorSchemeKey] as? String, "github-dark", "colour scheme copied")
        t.equal(new[P.bodyFontFamilyKey] as? String, "Fira Code", "text font copied")
        t.check(new[P.codeFontFamilyKey] == nil, "code font: nothing to copy, nothing invented")
        t.equal(new[P.lineHeightFactorKey] as? Double, 1.1, "line spacing copied")
        t.equal(new[P.columnWidthKey] as? Double, 900, "column width copied")
        t.equal(new[P.readableWidthKey] as? Bool, false, "readable-width flag copied: false stays false")
        t.equal(new[P.migratedKey] as? Bool, true, "the migration marks itself as done")
        t.equal(new.count, 7, "nothing else is written: 6 values and the marker")

        t.check(P.migrated(current: new, legacy: legacy.merging(["ScribeFontSize": 30.0]) { $1 }) == nil, "a second run does nothing")

        if let r2 = P.migrated(current: [P.fontSizeKey: 20.0], legacy: legacy) {
            t.equal(r2.copied, 5, "with a value already stored, the other 5 are copied")
            t.equal(r2.domain[P.fontSizeKey] as? Double, 20, "a stored value wins over the legacy one")
        } else { t.check(false, "migration with a stored value ran") }

        if let r3 = P.migrated(current: [:], legacy: [:]) {
            t.equal(r3.copied, 0, "no old app: nothing copied")
            t.equal(r3.domain[P.migratedKey] as? Bool, true, "no old app: marked done all the same")
        } else { t.check(false, "migration without an old app ran") }

        // The I/O wrapper, against this self-test bundle's own private domain. Registered defaults (the app registers some of these keys)
        // must not look like stored values: the wrapper reads the stored domain, not UserDefaults lookups.
        let ud = UserDefaults.standard
        let id = Bundle.main.bundleIdentifier ?? ""
        t.check(id.hasSuffix(".selftest"), "this run is a self-test bundle")
        t.check(ud.persistentDomain(forName: id)?[P.migratedKey] == nil, "the self-test bundle did not run the migration at launch")
        ud.register(defaults: [P.readableWidthKey: true])
        let before = ud.persistentDomain(forName: id) ?? [:]
        let copiedFromNothing = P.migrateLegacySettings(oldDomain: "local.luftig.selftest.no-such-domain", newDomain: id)
        t.equal(copiedFromNothing, 0, "wrapper: a missing old domain copies nothing")
        t.equal(ud.persistentDomain(forName: id)?[P.migratedKey] as? Bool, true, "wrapper: writes the marker into the stored domain")
        t.equal(P.migrateLegacySettings(oldDomain: "local.luftig.selftest.no-such-domain", newDomain: id), 0, "wrapper: once only")
        ud.setPersistentDomain(before, forName: id)                 // leave this bundle's preferences as they were
        t.check(ud.persistentDomain(forName: id)?[P.migratedKey] == nil, "the marker is removed again")

        // the placeholder bundle id (local.luftig.luftig -> com.bernorieder.luftig): every Luftig… key, once, never over a value of the new domain
        if let r = P.migratedSameKeys(current: ["LuftigFontSize": 18.0, "NSWindow Frame x": "keep"], legacy: ["LuftigFontSize": 12.0, "LuftigPaddingPoints": 30.0, "LuftigShowOutline": false, "NSWindow Frame x": "old", P.migratedKey: true]) {
            t.equal(r.copied, 2, "placeholder id: the Luftig keys the new domain lacks are copied (padding, outline), not the font size it has, not the system's keys, not the Scribe marker")
            t.equal(r.domain["LuftigPaddingPoints"] as? Double, 30.0, "placeholder id: the padding came over")
            t.equal(r.domain["LuftigFontSize"] as? Double, 18.0, "placeholder id: the new domain's font size stays")
            t.check(r.domain[P.migratedKey] == nil && r.domain[P.migratedFromPlaceholderKey] as? Bool == true, "placeholder id: its own marker, not Scribe's")
            t.check(P.migratedSameKeys(current: r.domain, legacy: ["LuftigFontSize": 9.0]) == nil, "placeholder id: once only")
        } else { t.check(false, "placeholder id: the migration ran") }
        t.equal(P.migratePlaceholderSettings(oldDomain: "local.luftig.selftest.no-such-domain", newDomain: id), 0, "placeholder id wrapper: a missing old domain copies nothing")
        ud.setPersistentDomain(before, forName: id)
    }
}
#endif
