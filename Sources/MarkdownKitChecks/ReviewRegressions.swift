import Foundation
import MarkdownKit

// Regression tests added by the lexer review round. Every group says what was wrong before (all of them FAIL on the pre-review
// lexer except the ones marked "intermediate", which guard defects of a draft fix that never shipped).

/// Does the style at UTF-16 offset `loc` of `text` (fresh lexAll) contain `facet`?
private func hasFacet(_ runs: [MDRun], _ loc: Int, _ facet: MDStyle) -> Bool {
    for r in runs where loc >= r.range.location && loc < r.range.location + r.range.length { return r.style.contains(facet) }
    return false
}

private func scenarioConfigs() -> [FuzzConfig] {
    var tiny = FuzzConfig(); tiny.stride = 1; tiny.maxLines = 2; tiny.maxUnits = 40; tiny.chunk = 3; tiny.slideMin = 0; tiny.slideLow = 4; tiny.poison = true
    var small = FuzzConfig(); small.stride = 8; small.maxLines = 3; small.poison = true
    var mid = FuzzConfig(); mid.stride = 32; mid.maxLines = 12; mid.chunk = 16
    return [FuzzConfig(), tiny, small, mid]
}

/// Runs the same scripted edits under several internal configurations; every update / query is compared with a fresh lex and with
/// a model of the app (attributes applied only inside the returned regions).
private func scenario(_ name: String, _ initial: String, _ steps: [Step]) {
    for c in scenarioConfigs() {
        if let (idx, msg) = runScenario(initial: initial, config: c, steps: steps) {
            Harness.fail("scenario \"\(name)\" step \(idx) [\(c.text)]: \(msg)")
        } else {
            Harness.checks += 1
        }
    }
}

func runReviewRegressions() {
    Harness.group("review regressions")

    // 1. Blank lines between indented code lines belong to the block, so the line that follows them restyles the blank lines
    //    before it (was: plain). Incremental behaviour of that "pending blank lines" state, scripted.
    scenario("append a code line after blank lines", "    a\n\n\n", [.edit(loc: 8, len: 0, repl: "    b\n", budget: 0), .query(loc: 0, len: 4)])
    scenario("delete the code line after blank lines", "    a\n\n\n    b\n", [.edit(loc: 8, len: 6, repl: "", budget: 0), .query(loc: 0, len: 20)])
    scenario("a paragraph line ends the block", "    a\n\n    b\n", [.edit(loc: 6, len: 0, repl: "x", budget: 0), .edit(loc: 6, len: 1, repl: "", budget: 0)])
    scenario("blank becomes whitespace-only / text", "    a\n\n\n    b\n", [.edit(loc: 6, len: 0, repl: "  ", budget: 0), .edit(loc: 6, len: 2, repl: "z", budget: 0), .edit(loc: 6, len: 1, repl: "", budget: 0)])
    scenario("indented code in a quote", ">     a\n>\n>     b\n", [.edit(loc: 9, len: 1, repl: "", budget: 0), .edit(loc: 9, len: 0, repl: ">", budget: 0), .edit(loc: 0, len: 0, repl: "x\n\n", budget: 0)])
    scenario("indented code in a list", "- a\n\n      one\n\n\n      two\n- b\n", [.edit(loc: 11, len: 0, repl: "\n", budget: 0), .edit(loc: 20, len: 6, repl: "", budget: 0), .edit(loc: 0, len: 2, repl: "1. ", budget: 0), .query(loc: 0, len: 40)])
    scenario("blank lines at the very end", "    a\n\n\n", [.edit(loc: 8, len: 0, repl: "\n", budget: 0), .edit(loc: 0, len: 6, repl: "", budget: 0), .query(loc: 0, len: 2)])
    scenario("blank run longer than the cap", "    a\n" + String(repeating: "\n", count: 20) + "    b\n", [.edit(loc: 10, len: 0, repl: " ", budget: 0), .edit(loc: 8, len: 0, repl: "\n\n\n", budget: 0), .edit(loc: 0, len: 6, repl: "", budget: 0), .query(loc: 0, len: 12)])

    // 2. (intermediate) An endless run of blank lines after indented code used to be pending as a whole: one 16-byte entry per
    //    blank line, no checkpoint inside the run, so a keystroke in it re-lexed the entire run (5.6 ms for 1M lines, 46 ms for 8M).
    //    A run of maxPendLines (256) blank lines now ends the block: the blank lines stay plain.
    do {
        let few = "    a\n" + String(repeating: "\n", count: 10) + "    b\n"
        let fr = MarkdownStyler().lexAll(few as NSString)
        Harness.expect(hasFacet(fr, 6, .codeBlock) && hasFacet(fr, 15, .codeBlock), "10 blank lines between code lines are part of the block")
        let many = "    a\n" + String(repeating: "\n", count: 300) + "    b\n"
        let mr = MarkdownStyler().lexAll(many as NSString)
        Harness.expect(!hasFacet(mr, 6, .codeBlock) && !hasFacet(mr, 200, .codeBlock) && !hasFacet(mr, 296, .codeBlock), "300 blank lines end the code block (work cap): none of them is code")
        Harness.expect(hasFacet(mr, 0, .codeBlock) && hasFacet(mr, (many as NSString).length - 3, .codeBlock), "the code lines around the run are still code")

        let big = "    a\n" + String(repeating: "\n", count: 300_000) + "    b\n"
        let d = IncDoc(big, "blank run")
        d.style(0, d.length)
        Harness.expect(d.styler.debugCheckpointCount >= 100, "checkpoints must continue inside a long blank run, got \(d.styler.debugCheckpointCount)")
        let mid = d.length / 2
        let r = d.edit(mid, 0, " ")
        Harness.expect(r.range.length < 20_000, "a keystroke inside a 300,000-line blank run re-lexed \(r.range.length) units")
        let r2 = d.edit(d.length, 0, "    c\n")
        Harness.expect(r2.range.length < 20_000, "appending a code line after the run re-lexed \(r2.range.length) units")
    }

    // 3. A line break right after an opening delimiter belongs to the span (was: plain - the extent search used the end of the line
    //    content instead of the end including the break): code spans and link text that start at the end of a line.
    Harness.expectEqual(renderAll("`\nx`"), "[code·marker:`][code:⏎x][code·marker:`]", "code span opened at the end of a line")
    Harness.expectEqual(renderAll("[\nfoo](/u)"), "[marker·link:[][link:⏎foo][marker·link:]][marker·dest:(][dest:/u][marker·dest:)]", "link text opened at the end of a line")
    Harness.expectEqual(renderAll("> `\n> x`\n"), "[q1·marker:> ][q1·code·marker:`][q1·code:⏎][q1·marker:> ][q1·code:x][q1·code·marker:`][q1:⏎]", "the same inside a quote")
    Harness.expectEqual(renderAll("- `\n  x`\n"), "[list:- ][code·marker:`][code:⏎][:  ][code:x][code·marker:`][:⏎]", "the same inside a list item")

    // 4. A table is not a paragraph (GFM): every block start ends it, also the ones that cannot interrupt a paragraph.
    Harness.expectEqual(renderAll("| a |\n|---|\n| b |\n    c\n"), "[table·thead·tdelim:|][table·thead: a ][table·thead·tdelim:|][table·thead:⏎][table·tdelim:|---|⏎|][table: b ][table·tdelim:|][table:⏎][codeblock:    c⏎]", "indented code after a table")
    Harness.expectEqual(renderAll("| a |\n|---|\n| b |\n2. x\n"), "[table·thead·tdelim:|][table·thead: a ][table·thead·tdelim:|][table·thead:⏎][table·tdelim:|---|⏎|][table: b ][table·tdelim:|][table:⏎][list:2. ][:x⏎]", "`2.` after a table starts a list")
    Harness.expectEqual(renderAll("| a |\n|---|\n| b |\n-\n"), "[table·thead·tdelim:|][table·thead: a ][table·thead·tdelim:|][table·thead:⏎][table·tdelim:|---|⏎|][table: b ][table·tdelim:|][table:⏎][list:-][:⏎]", "an empty list item after a table")

    // 5. Numeric character references: at most 7 decimal / 6 hexadecimal digits (CommonMark 6.2).
    Harness.expectEqual(renderAll("&#1234567; &#12345678; &#x10FFFF; &#x1234567;"), "[esc:&#1234567;][: &#12345678; ][esc:&#x10FFFF;][: &#x1234567;]", "entity digit limits")

    // 6. E-mail autolinks must look like e-mail addresses; CDATA ends at ]]>.
    Harness.expectEqual(renderAll("<a@b.co> <a@> <@b.co> <a b@c.de> <a@b..c> <a@-b.c>"), "[marker·auto:<][auto:a@b.co][marker·auto:>][: <a@> <@b.co> <a b@c.de> <a@b..c> <a@-b.c>]", "e-mail autolink validation")
    Harness.expectEqual(renderAll("x <![CDATA[a>b]]> y"), "[:x ][html:<![CDATA[a>b]]>][: y]", "CDATA section")

    // 7. Bare http(s):// URLs: any non-letter may precede them (as in cmark-gfm), but not inside link text; www. keeps the GFM rule.
    Harness.expectEqual(renderAll("\"http://a.org/x\" 'https://b.org' k=http://c.org/y ,http://d.org"), "[:\"][auto:http://a.org/x][:\" '][auto:https://b.org][:' k=][auto:http://c.org/y][: ,][auto:http://d.org]", "URL after quote / equals / comma")
    Harness.expectEqual(renderAll("[http://t.org](http://u.org) xhttp://n.org \"www.q.org\""), "[marker·link:[][link:http://t.org][marker·link:]][marker·dest:(][dest:http://u.org][marker·dest:)][: xhttp://n.org \"www.q.org\"]", "no autolink inside link text, after a letter, or for www. after a quote")

    // 9. HTML block type 7 (a lone complete tag on a line, e.g. `<br>`) cannot interrupt a paragraph, and a lazy continuation line is
    //    paragraph continuation text (was: the line after an unindented list / quote paragraph started an HTML block that swallowed
    //    the rest of the paragraph and closed the container). Types 1-6 still interrupt.
    Harness.expectEqual(renderAll("- item\n<br>\n* x\n"), "[list:- ][:item⏎][html:<br>][:⏎][list:* ][:x⏎]", "<br> on a lazy line after a list item is inline HTML")
    Harness.expectEqual(renderAll("> foo\n<custom-tag>\nbar\n"), "[q1·marker:> ][q1:foo⏎][q1·html:<custom-tag>][q1:⏎bar⏎]", "a custom tag on a lazy line after a quote")
    Harness.expectEqual(renderAll("- foo\n</pre>\n*x*\n"), "[list:- ][:foo⏎][html:</pre>][:⏎][italic·marker:*][italic:x][italic·marker:*][:⏎]", "</pre> on a lazy line")
    Harness.expectEqual(renderAll("> a\n> <br>\n> b\n"), "[q1·marker:> ][q1:a⏎][q1·marker:> ][q1·html:<br>][q1:⏎][q1·marker:> ][q1:b⏎]", "the same with the quote marker present")
    Harness.expectEqual(renderAll("foo\n<div>\nbar\n"), "[:foo⏎][html:<div>⏎bar⏎]", "a type 6 block still interrupts a paragraph")
    Harness.expectEqual(renderAll("- foo\n<div>\nbar\n"), "[list:- ][:foo⏎][html:<div>⏎bar⏎]", "... also on a lazy line")
    Harness.expectEqual(renderAll("- a\n\n<br>\n*x*\n"), "[list:- ][:a⏎⏎][html:<br>⏎*x*⏎]", "after a blank line the tag starts an HTML block again")
    scenario("tag on a lazy line", "- item\n<br>\n* x\n", [.edit(loc: 6, len: 0, repl: "\n", budget: 0), .edit(loc: 7, len: 1, repl: "", budget: 0), .edit(loc: 0, len: 2, repl: "", budget: 0), .query(loc: 0, len: 20)])

    // 10. A list item can begin with at most one blank line: a blank line right after an empty item (`-`, `1.`) ends it, so what follows
    //     is no longer inside the item (was: indented code after it showed as a continuation paragraph).
    Harness.expectEqual(renderAll("-\n\n    code\n"), "[list:-][:⏎⏎][codeblock:    code⏎]", "indented code after an empty item and a blank line")
    Harness.expectEqual(renderAll("1.\n\n      - six\n"), "[list:1.][:⏎⏎][codeblock:      - six⏎]", "ordered item")
    Harness.expectEqual(renderAll("-\n    code\n"), "[list:-][:⏎    code⏎]", "without the blank line the next line is the item's content")
    Harness.expectEqual(renderAll("-\n\n  text\n"), "[list:-][:⏎⏎  text⏎]", "plain text after the blank line stays plain")
    Harness.expectEqual(renderAll("> -\n>\n>     code\n"), "[q1·marker:> ][q1·list:-][q1:⏎][q1·marker:>][q1:⏎][q1·marker:> ][q1·codeblock:    code⏎]", "inside a quote")
    Harness.expectEqual(renderAll("- a\n\n  -\n\n      code\n"), "[list:- ][:a⏎⏎  ][list:-][:⏎⏎  ][codeblock:    code⏎]", "nested empty item: the outer item stays open")
    Harness.expectEqual(renderAll("- x\n  -\n\n    code\n"), "[list:- ][:x⏎  -⏎⏎    code⏎]", "`-` inside a paragraph is not an item, nothing closes")
    scenario("empty item then blank then code", "-\n\n    code\n", [.edit(loc: 1, len: 0, repl: " x", budget: 0), .edit(loc: 1, len: 2, repl: "", budget: 0), .edit(loc: 2, len: 1, repl: "", budget: 0), .edit(loc: 2, len: 0, repl: "\n", budget: 0), .query(loc: 0, len: 20)])
    scenario("blank line typed after an empty item", "1.\n    a\n    b\n", [.edit(loc: 3, len: 0, repl: "\n", budget: 0), .edit(loc: 3, len: 1, repl: "", budget: 0), .query(loc: 0, len: 30)])
    scenario("empty item in a quote", "> -\n>\n>     code\n", [.edit(loc: 4, len: 0, repl: " ", budget: 0), .edit(loc: 5, len: 1, repl: "", budget: 0), .edit(loc: 0, len: 2, repl: "", budget: 0), .query(loc: 0, len: 30)])

    // The empty-item flag is part of the block state compared for re-convergence: `-` and `- # h` leave the same container stack and
    // no open paragraph, so only the flag tells them apart (the next blank line closes the first item but not the second).
    scenario("empty item vs. heading item (state equality)", "-\n\n    code\n", [.query(loc: 0, len: 20), .edit(loc: 1, len: 0, repl: " # h", budget: 0), .query(loc: 0, len: 30), .edit(loc: 1, len: 4, repl: "", budget: 0), .query(loc: 0, len: 30)])
    scenario("empty item vs. heading item, other way round", "- # h\n\n    code\n", [.query(loc: 0, len: 20), .edit(loc: 1, len: 4, repl: "", budget: 0), .query(loc: 0, len: 30), .edit(loc: 1, len: 0, repl: " # h", budget: 0), .query(loc: 0, len: 30)])

    // 11. GFM extended autolinks: a trailing `;` that ends something resembling an entity reference leaves out the whole `&letters;`
    //     (was: only the `;`, so `&hl` stayed in the link); other trailing `;` are dropped as before.
    Harness.expectEqual(renderAll("www.google.com/search?q=commonmark&hl;"), "[auto:www.google.com/search?q=commonmark][esc:&hl;]", "GFM example: &hl; is not part of the autolink")
    Harness.expectEqual(renderAll("www.google.com/search?q=commonmark&hl=en"), "[auto:www.google.com/search?q=commonmark&hl=en]", "... but &hl=en is")
    Harness.expectEqual(renderAll("http://x.org/a&amp; http://x.org/a&#35; http://x.org;"), "[auto:http://x.org/a][esc:&amp;][: ][auto:http://x.org/a&#35][:; ][auto:http://x.org][:;]", "entity names (letters only) vs numeric references vs a plain `;`")
    Harness.expectEqual(renderAll("http://x.org/&a;;"), "[auto:http://x.org/][esc:&a;][:;]", "`;;`: the second is dropped, then the entity-like `&a;`")
    scenario("autolink before an entity", "http://x.org/a&hl;\n", [.query(loc: 0, len: 30), .edit(loc: 18, len: 1, repl: "", budget: 0), .edit(loc: 17, len: 0, repl: ";", budget: 0), .query(loc: 0, len: 30)])

    // 12. CommonMark 0.31: `<!-->` and `<!--->` are complete (empty) HTML comments (was: the search for `-->` started after them, so
    //     the "comment" ran to the next `-->` or - without one - was plain).
    Harness.expectEqual(renderAll("a <!--> b *c* <!---> d"), "[:a ][html:<!-->][: b ][italic·marker:*][italic:c][italic·marker:*][: ][html:<!--->][: d]", "empty comments")
    Harness.expectEqual(renderAll("a <!----> b <!-- x --> c <!--> d --> e"), "[:a ][html:<!---->][: b ][html:<!-- x -->][: c ][html:<!-->][: d --> e]", "other comments are unchanged")
    Harness.expectEqual(renderAll("<!-->\n*x*\n"), "[html:<!-->⏎][italic·marker:*][italic:x][italic·marker:*][:⏎]", "as a block it ended on its own line already")

    // 13. No bare URL while a `[` / `![` is still waiting for its `]` (cmark-gfm: it may turn out to be link text; also after an inner
    //     link has deactivated the opener). A closed bracket does not matter.
    Harness.expectEqual(renderAll("w[ www.q.org/p"), "[:w[ www.q.org/p]", "unclosed [ before a www. URL")
    Harness.expectEqual(renderAll("![ http://x.org"), "[:![ http://x.org]", "unclosed ![ before an http URL")
    Harness.expectEqual(renderAll("[a [b](c) www.x.org d](e)"), "[:[a ][marker·link:[][link:b][marker·link:]][marker·dest:(][dest:c][marker·dest:)][: www.x.org d](e)]", "inside an outer opener that an inner link deactivated")
    Harness.expectEqual(renderAll("[x] http://x.org and [a](b) www.y.org"), "[:[x] ][auto:http://x.org][: and ][marker·link:[][link:a][marker·link:]][marker·dest:(][dest:b][marker·dest:)][: ][auto:www.y.org]", "closed brackets do not matter")
    scenario("bracket before a URL", "[ www.q.org/p\n", [.query(loc: 0, len: 30), .edit(loc: 1, len: 0, repl: "]", budget: 0), .edit(loc: 1, len: 1, repl: "", budget: 0), .query(loc: 0, len: 30)])

    // 14. Flanking uses CommonMark's real definition of "Unicode punctuation" (categories P and S) and "Unicode whitespace" (Zs): the lexer used
    //     hand-written ranges that missed the punctuation of most scripts (danda, Armenian, Hebrew, Arabic, Thai, Tibetan ...) and counted
    //     superscripts, fractions and letterlike symbols (`m²`, `½`, `ℕ`) as punctuation.
    Harness.expectEqual(renderAll("x*।*y"), "[:x*।*y]", "a Devanagari danda is punctuation: `*` between a letter and punctuation does not open")
    Harness.expectEqual(renderAll("x*־*y"), "[:x*־*y]", "Hebrew maqaf (Pd)")
    Harness.expectEqual(renderAll("x*؟*y"), "[:x*؟*y]", "Arabic question mark (Po)")
    Harness.expectEqual(renderAll("x*𝄞*y"), "[:x*𝄞*y]", "an astral symbol (musical G clef, So)")
    Harness.expectEqual(renderAll("*m²*s"), "[italic·marker:*][italic:m²][italic·marker:*][:s]", "superscript two is a number, not punctuation")
    Harness.expectEqual(renderAll("*ℕ*x"), "[italic·marker:*][italic:ℕ][italic·marker:*][:x]", "a letterlike symbol (Lu) is a letter")
    Harness.expectEqual(renderAll("*½*x"), "[italic·marker:*][italic:½][italic·marker:*][:x]", "a vulgar fraction (No) is a number")
    Harness.expectEqual(renderAll("*€*x"), "[:*€*x]", "a currency symbol is punctuation: the closing `*` between punctuation and a letter does not close")
    Harness.expectEqual(renderAll("*€* x"), "[italic·marker:*][italic:€][italic·marker:*][: x]", "... but it does before a space")
    Harness.expectEqual(renderAll("*\u{2009}x*"), "[:*\u{2009}x*]", "a thin space (Zs) is whitespace: the opening `*` is not left-flanking")
    let classMismatches = runUnicodeClassCheck(quiet: true)
    Harness.expect(classMismatches == 0, "the lexer's class of every assigned scalar of planes 0-2 equals its general category (P / S: punctuation, Zs: whitespace); \(classMismatches) differ (mdkit-checks --unicode-class lists them)")

    // 8. Indented code inside list items / quotes, and text after a task checkbox or footnote label that is indented 4+ columns.
    Harness.expectEqual(renderAll("- [ ]      text\n"), "[list:- ][task:[ ]][:      text⏎]", "text after a checkbox is paragraph text")
    Harness.expectEqual(renderAll("* a\n\n      code <T> *x*\n"), "[list:* ][:a⏎⏎  ][codeblock:    code <T> *x*⏎]", "no inline styling inside indented code in a list")
}
