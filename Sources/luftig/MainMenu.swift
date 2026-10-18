// MainMenu.swift
//
// The complete main menu, built in code (no nib/storyboard). Every item has target == nil (First Responder) so
// that AppKit's responder chain does the routing AND the enabling/validation:
//   text view -> ... -> EditorViewController -> NSWindow -> EditorWindowController -> MarkdownDocument
//   -> NSApplication -> AppDelegate -> NSDocumentController
// Standard actions are validated by their implementers (NSTextView, NSDocument, NSWindow, NSDocumentController);
// the custom actions (LuftigEditorActions) are validated by EditorViewController.validateMenuItem.

import AppKit

enum MainMenu {

    /// Builds the menu bar and registers the special menus with NSApp (services, windows, help).
    ///
    /// Measured AppKit behaviour (macOS 27, see docs/spike-document.md):
    ///  * Install this in applicationWillFinishLaunching WITHOUT our own "Open Recent" item (the default): AppKit adds its
    ///    own "Open Recent" submenu right after "Open…" during launch. If we also add one, the File menu ends up with TWO.
    ///    (A menu installed after launch, e.g. in applicationDidFinishLaunching, needs `includeOpenRecent: true`.)
    ///  * AppKit adds/rewrites on its own: "Close All" (alternate of Close), "Revert To" submenu + "Share" submenu (File,
    ///    autosave-in-place), AutoFill / Start Dictation / Emoji & Symbols (Edit), and its version of "Enter Full Screen" (View,
    ///    key fn-F) - but only if we provide a toggleFullScreen: item; ours then ends up as a hidden alternate.
    @discardableResult
    static func install(appName: String = "luftig", includeOpenRecent: Bool = false) -> NSMenu {
        let main = NSMenu(title: "MainMenu")

        // ---- App menu
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(item("About \(appName)", #selector(AppDelegate.showAboutPanel(_:))))
        appMenu.addItem(.separator())
        // the standard place for it: after About, before Services. The action lives on the application delegate (it needs no document).
        appMenu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        add(appMenu, to: main, title: appName)

        // ---- File
        let file = NSMenu(title: "File")
        file.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        file.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        if includeOpenRecent {
            let recent = NSMenu(title: "Open Recent")
            // AppKit recognises this menu by the "Clear Menu" item with exactly this action and fills in the recent files.
            recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
            let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = recent
            file.addItem(recentItem)
        }
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        file.addItem(item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        file.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:))))
        file.addItem(item("Rename…", #selector(NSDocument.rename(_:))))
        file.addItem(item("Move To…", #selector(NSDocument.move(_:))))
        file.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))       // AppKit turns it into the Versions "Revert To" submenu
        file.addItem(item("Reload from Disk", #selector(MarkdownDocument.luftigReloadFromDisk(_:)), "r", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]))
        file.addItem(item("Print…", #selector(NSDocument.printDocument(_:)), "p"))
        add(file, to: main, title: "File")

        // ---- Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())

        let find = NSMenu(title: "Find")
        find.addItem(finder("Find…", .showFindInterface, "f"))
        find.addItem(finder("Find and Replace…", .showReplaceInterface, "f", [.command, .option]))
        find.addItem(finder("Find Next", .nextMatch, "g"))
        find.addItem(finder("Find Previous", .previousMatch, "g", [.command, .shift]))
        find.addItem(finder("Use Selection for Find", .setSearchString, "e"))
        find.addItem(item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"))
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)

        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spelling.addItem(item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))))
        spelling.addItem(item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        let spellingItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        spellingItem.submenu = spelling
        edit.addItem(spellingItem)

        let subs = NSMenu(title: "Substitutions")
        subs.addItem(item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        subs.addItem(.separator())
        subs.addItem(item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))))
        subs.addItem(item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        subs.addItem(item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        subs.addItem(item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))))
        subs.addItem(item("Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:))))
        subs.addItem(item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        let subsItem = NSMenuItem(title: "Substitutions", action: nil, keyEquivalent: "")
        subsItem.submenu = subs
        edit.addItem(subsItem)

        let transforms = NSMenu(title: "Transformations")
        transforms.addItem(item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))))
        transforms.addItem(item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))))
        transforms.addItem(item("Capitalize", #selector(NSResponder.capitalizeWord(_:))))
        let transformsItem = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        transformsItem.submenu = transforms
        edit.addItem(transformsItem)
        add(edit, to: main, title: "Edit")

        // ---- Format: the syntax bar's elements as menu items with shortcuts (EditorViewController.luftigInsertSyntax, the tag names the element)
        let format = NSMenu(title: "Format")
        for (g, group) in SyntaxElement.groups.enumerated() {
            if g > 0 { format.addItem(.separator()) }
            for e in group {
                let s = e.shortcut
                var mods: NSEvent.ModifierFlags = [.command]
                if s.shift { mods.insert(.shift) }
                if s.option { mods.insert(.option) }
                let i = item(e.menuTitle, #selector(LuftigEditorActions.luftigInsertSyntax(_:)), s.key, mods)
                i.tag = e.menuTag
                format.addItem(i)
            }
        }
        add(format, to: main, title: "Format")

        // ---- View
        let view = NSMenu(title: "View")
        view.addItem(item("Bigger", #selector(LuftigEditorActions.luftigIncreaseFontSize(_:)), "+"))
        // On a US keyboard "+" is ⇧=, and a menu item whose key is "+" does not answer ⌘= (measured, audit-shell-menu): people press
        // ⌘= and nothing happens. A hidden twin with key "=" answers it (a hidden item's key equivalent still works: measured).
        let biggerEquals = item("Bigger", #selector(LuftigEditorActions.luftigIncreaseFontSize(_:)), "=")
        biggerEquals.isHidden = true
        view.addItem(biggerEquals)
        view.addItem(item("Smaller", #selector(LuftigEditorActions.luftigDecreaseFontSize(_:)), "-"))
        view.addItem(item("Actual Size", #selector(LuftigEditorActions.luftigResetFontSize(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item("Wrap to Readable Width", #selector(LuftigEditorActions.luftigToggleReadableWidth(_:))))
        view.addItem(item("Toggle Spell Checking", #selector(LuftigEditorActions.luftigToggleSpellChecking(_:))))
        view.addItem(.separator())
        // the three elements around the text; the titles flip to "Hide …" while an element is shown (EditorViewController.validateMenuItem)
        view.addItem(item("Show Outline", #selector(LuftigEditorActions.luftigToggleOutline(_:))))
        view.addItem(item("Show Word Count", #selector(LuftigEditorActions.luftigToggleWordCount(_:))))
        view.addItem(item("Show Syntax Bar", #selector(LuftigEditorActions.luftigToggleSyntaxBar(_:))))
        view.addItem(.separator())
        view.addItem(item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))))
        view.addItem(item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:))))
        // AppKit rewrites this item: it becomes the visible "Enter Full Screen" with the system key (fn-F) and our ⌃⌘F is kept
        // as a hidden alternate. If the item is missing AppKit does NOT add one (measured).
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        add(view, to: main, title: "View")

        // ---- Window
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]))
        window.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control]))
        window.addItem(item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))))
        window.addItem(item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        add(window, to: main, title: "Window")
        NSApp.windowsMenu = window

        // ---- Help
        // Deliberately EMPTY: the bundle has no help book, and an enabled "luftig Help" item (showHelp:) only opens the modal alert
        // "Help isn't available for luftig" (measured: NSApplication.showHelp: -> NSAlert.runModal). Registering the menu as
        // `helpMenu` makes AppKit put its "Search" field into it, which is the one useful thing a Help menu can offer here.
        // If a help book is ever added (CFBundleHelpBookFolder / CFBundleHelpBookName), add the item back.
        let help = NSMenu(title: "Help")
        add(help, to: main, title: "Help")
        NSApp.helpMenu = help

        NSApp.mainMenu = main
        return main
    }

    // MARK: helpers

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { i.keyEquivalentModifierMask = mods }
        i.target = nil          // first responder
        return i
    }

    private static func finder(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                               _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, mods)
        i.tag = action.rawValue
        return i
    }

    private static func add(_ submenu: NSMenu, to main: NSMenu, title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = submenu
        main.addItem(i)
    }
}
