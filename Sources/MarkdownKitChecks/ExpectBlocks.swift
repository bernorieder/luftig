import Foundation
import MarkdownKit

/// One expectation: input text (Swift string) and the expected run notation for the whole text.
nonisolated(unsafe) var expectCount = 0

func ex(_ input: String, _ expected: String, _ note: String = "") {
    expectCount += 1
    let t = NSString(string: input)
    let styler = MarkdownStyler()
    let runs = styler.lexAll(t)
    let actual = render(t, runs)
    Harness.expectEqual(actual, expected, "input \"\(visible(input))\" \(note)")
    // The same text must also come out identically via styleRuns on a cold styler.
    if t.length > 0 {
        let res = MarkdownStyler().styleRuns(in: NSRange(location: 0, length: t.length), of: t)
        Harness.expectEqual(render(t, res.runs), expected, "styleRuns whole text \"\(visible(input))\"")
    }
}

func runExpectationTests() {
    Harness.group("expectations: blocks")
    headingTests()
    setextAndRuleTests()
    codeTests()
    quoteTests()
    listTests()
    tableTests()
    frontMatterAndHTMLTests()
    referenceTests()
    runInlineExpectations()
    runEdgeCaseExpectations()
    print("expectation cases: \(expectCount)")
}

private func headingTests() {
    ex("# Hello\n", "[h1·marker:# ][h1:Hello⏎]")
    ex("###### Six\n", "[h6·marker:###### ][h6:Six⏎]")
    ex("####### Seven\n", "[:####### Seven⏎]")
    ex("#nospace\n", "[:#nospace⏎]")
    ex("# \n", "[h1·marker:# ][h1:⏎]")
    ex("#\n", "[h1·marker:#][h1:⏎]")
    ex("## T ##\n", "[h2·marker:## ][h2:T ][h2·marker:##][h2:⏎]")
    ex("# a # b\n", "[h1·marker:# ][h1:a # b⏎]")
    ex("# foo#\n", "[h1·marker:# ][h1:foo#⏎]")
    ex("# **b** and *i*\n", "[h1·marker:# ][h1·bold·marker:**][h1·bold:b][h1·bold·marker:**][h1: and ][h1·italic·marker:*][h1·italic:i][h1·italic·marker:*][h1:⏎]")
    ex("   ### Indented\n", "[h3:   ][h3·marker:### ][h3:Indented⏎]")
    ex("    # code\n", "[codeblock:    # code⏎]")
    ex("# a\n## b\ntext\n", "[h1·marker:# ][h1:a⏎][h2·marker:## ][h2:b⏎][:text⏎]")
    ex("text\n# interrupts\n", "[:text⏎][h1·marker:# ][h1:interrupts⏎]")
    ex("# no newline at end", "[h1·marker:# ][h1:no newline at end]")
}

private func setextAndRuleTests() {
    ex("Title\n=====\n", "[h1:Title⏎][h1·marker:=====][h1:⏎]")
    ex("Sub\n---\n", "[h2:Sub⏎][h2·marker:---][h2:⏎]")
    ex("Multi\nline\n===\n", "[h1:Multi⏎line⏎][h1·marker:===][h1:⏎]")
    ex("a\n-\n", "[:a⏎-⏎]", "single dash is not a setext underline (deliberate)")
    ex("a\n=\n", "[:a⏎=⏎]", "single = is not a setext underline (deliberate)")
    ex("a\n--\n", "[h2:a⏎][h2·marker:--][h2:⏎]")
    ex("*em* title\n---\n", "[h2·italic·marker:*][h2·italic:em][h2·italic·marker:*][h2: title⏎][h2·marker:---][h2:⏎]")
    ex("> quote\n---\n", "[q1·marker:> ][q1:quote⏎][hr:---⏎]", "underline cannot be a lazy continuation")
    ex("para\n\n---\n", "[:para⏎⏎][hr:---⏎]")
    ex("***\n", "[hr:***⏎]")
    ex("___\n", "[hr:___⏎]")
    ex("- - -\n", "[hr:- - -⏎]")
    ex("* * *\n", "[hr:* * *⏎]")
    ex("--\n", "[:--⏎]")
    ex("text\n***\n", "[:text⏎][hr:***⏎]")
    ex("- a\n---\n", "[list:- ][:a⏎][hr:---⏎]")
    ex("- a\n  ---\n", "[list:- ][h2:a⏎][:  ][h2·marker:---][h2:⏎]")
}

private func codeTests() {
    ex("```\ncode\n```\n", "[fence:```⏎][codeblock:code⏎][fence:```⏎]")
    ex("```swift\nx\n```\n", "[fence:```][fence·lang:swift][fence:⏎][codeblock:x⏎][fence:```⏎]")
    ex("~~~\na\n~~~\n", "[fence:~~~⏎][codeblock:a⏎][fence:~~~⏎]")
    ex("```\na\nb", "[fence:```⏎][codeblock:a⏎b]", "an unclosed fence runs to the end")
    ex("```\n\n\n", "[fence:```⏎][codeblock:⏎⏎]")
    ex("```\na\n`````\nafter", "[fence:```⏎][codeblock:a⏎][fence:`````⏎][:after]", "a longer closing fence closes")
    ex("````\na\n```\nb\n````\n", "[fence:````⏎][codeblock:a⏎```⏎b⏎][fence:````⏎]", "a shorter fence does not close")
    ex("```\na\n~~~\nb\n```\n", "[fence:```⏎][codeblock:a⏎~~~⏎b⏎][fence:```⏎]", "other fence char does not close")
    ex("``` a`b\nx\n", "[:``` a`b⏎x⏎]", "backtick fence info may not contain backticks")
    ex("~~~ a`b\nx\n~~~\n", "[fence:~~~ ][fence·lang:a`b][fence:⏎][codeblock:x⏎][fence:~~~⏎]")
    ex("```   swift extra\nx\n```\n", "[fence:```   ][fence·lang:swift][fence: extra⏎][codeblock:x⏎][fence:```⏎]")
    ex("  ```\n  x\n  ```\n", "[fence:  ```⏎][codeblock:  x⏎][fence:  ```⏎]")
    ex("    ```\n", "[codeblock:    ```⏎]", "4 spaces is an indented code block, not a fence")
    ex("text\n```\ncode\n```\ntext\n", "[:text⏎][fence:```⏎][codeblock:code⏎][fence:```⏎][:text⏎]", "fences interrupt paragraphs")
    ex("```\n# not heading\n> not quote\n- not list\n```\n", "[fence:```⏎][codeblock:# not heading⏎> not quote⏎- not list⏎][fence:```⏎]")
    ex("```\ncode\n``` x\n", "[fence:```⏎][codeblock:code⏎``` x⏎]", "closing fence may not have an info string")
    ex("```\ncode\n```   \n", "[fence:```⏎][codeblock:code⏎][fence:```   ⏎]")
    ex("    code\n", "[codeblock:    code⏎]")
    ex("\tcode\n", "[codeblock:⇥code⏎]")
    ex("    a\n    b\n", "[codeblock:    a⏎    b⏎]")
    // CHANGED (review round, verified against cmark-gfm on 10 real documents): blank lines BETWEEN indented code lines belong to the
    // block (CommonMark 4.4); the lexer used to paint them plain. Trailing blank lines still end the block.
    ex("    a\n\n    b\n", "[codeblock:    a⏎⏎    b⏎]", "blank lines between indented code lines belong to the block")
    ex("    a\n  \n\t\n    b\n", "[codeblock:    a⏎  ⏎⇥⏎    b⏎]", "blank lines with spaces / tabs too")
    ex("    a\n\n\n    b\n\npara\n", "[codeblock:    a⏎⏎⏎    b⏎][:⏎para⏎]", "trailing blank lines are not code")
    ex("    a\n\n", "[codeblock:    a⏎][:⏎]", "a blank line after the last code line is not code")
    ex(">     a\n>\n>     b\n\nx", "[q1·marker:> ][q1·codeblock:    a⏎][q1·marker:>][q1·codeblock:⏎][q1·marker:> ][q1·codeblock:    b⏎][:⏎x]", "in a quote")
    ex("para\n    still para\n", "[:para⏎    still para⏎]")
    ex("# h\n    code\n", "[h1·marker:# ][h1:h⏎][codeblock:    code⏎]")
    // CHANGED (review round, verified against cmark-gfm): indented code inside a list item (content column + 4), as in the Swift
    // compiler's diagnostics docs. It used to be shown as a continuation paragraph (inline syntax coloured inside code).
    ex("- item\n\n      deeper\n", "[list:- ][:item⏎⏎  ][codeblock:    deeper⏎]", "indented code inside a list item")
    ex("- item\n\n    para\n", "[list:- ][:item⏎⏎    para⏎]", "content column + 2 is a continuation paragraph, not code")
    ex("1. x\n\n       code\n\n   para\n", "[list:1. ][:x⏎⏎   ][codeblock:    code⏎][:⏎   para⏎]", "ordered item: column 3 + 4")
    ex("- [x] done\n\n      code\n", "[list:- ][task·checked:[x]][: done⏎⏎  ][codeblock:    code⏎]", "task item")
    ex("- [ ]      text\n", "[list:- ][task:[ ]][:      text⏎]", "text after a checkbox is paragraph text however far it is indented")
    ex("[^1]:      text\n", "[marker·fn:[^][fn:1][marker·fn:]:][:      text⏎]", "same for a footnote definition's first line")
    ex("- a\n  ```\n  x\n  ```\n", "[list:- ][:a⏎  ][fence:```⏎][:  ][codeblock:x⏎][:  ][fence:```⏎]")
    ex("> ```\n> x\n> ```\n", "[q1·marker:> ][q1·fence:```⏎][q1·marker:> ][q1·codeblock:x⏎][q1·marker:> ][q1·fence:```⏎]")
    ex("> ```\n> x\ny\n", "[q1·marker:> ][q1·fence:```⏎][q1·marker:> ][q1·codeblock:x⏎][:y⏎]", "leaving the quote closes the fence")
    ex("- ```\n  x\ny\n", "[list:- ][fence:```⏎][:  ][codeblock:x⏎][:y⏎]", "dedent closes the fence")
    ex("`````\n", "[fence:`````⏎]")
    ex("``\nx\n", "[:``⏎x⏎]", "two backticks are no fence; an unclosed code span opener degrades to plain")
}

private func quoteTests() {
    ex("> a\n> b\n", "[q1·marker:> ][q1:a⏎][q1·marker:> ][q1:b⏎]")
    ex(">no space\n", "[q1·marker:>][q1:no space⏎]")
    ex("> > two\n", "[q1·marker:> ][q2·marker:> ][q2:two⏎]")
    ex(">>> three\n", "[q1·marker:>][q2·marker:>][q3·marker:> ][q3:three⏎]")
    ex("> > > > four\n", "[q1·marker:> ][q2·marker:> ][q3·marker:> > ][q3:four⏎]", "depth saturates at 3")
    ex("> a\nlazy\n", "[q1·marker:> ][q1:a⏎lazy⏎]")
    ex("> a\n\nb\n", "[q1·marker:> ][q1:a⏎][:⏎b⏎]")
    ex(">\n", "[q1·marker:>][q1:⏎]")
    ex("> a\n>\n> b\n", "[q1·marker:> ][q1:a⏎][q1·marker:>][q1:⏎][q1·marker:> ][q1:b⏎]")
    ex("> # H\n", "[q1·marker:> ][h1·q1·marker:# ][h1·q1:H⏎]")
    ex("> - a\n", "[q1·marker:> ][q1·list:- ][q1:a⏎]")
    ex("   > indented\n", "[:   ][q1·marker:> ][q1:indented⏎]")
    ex("    > code\n", "[codeblock:    > code⏎]")
    ex("> a\n> > b\n> c\n", "[q1·marker:> ][q1:a⏎][q1·marker:> ][q2·marker:> ][q2:b⏎][q1·marker:> ][q2:c⏎]", "c is a lazy continuation of the inner quote paragraph")
    ex("> a\n- b\n", "[q1·marker:> ][q1:a⏎][list:- ][:b⏎]")
    ex("> a\n# b\n", "[q1·marker:> ][q1:a⏎][h1·marker:# ][h1:b⏎]")
    ex("> `code` and *em*\n", "[q1·marker:> ][q1·code·marker:`][q1·code:code][q1·code·marker:`][q1: and ][q1·italic·marker:*][q1·italic:em][q1·italic·marker:*][q1:⏎]")
}

private func listTests() {
    ex("- a\n- b\n", "[list:- ][:a⏎][list:- ][:b⏎]")
    ex("* a\n+ b\n", "[list:* ][:a⏎][list:+ ][:b⏎]")
    ex("1. a\n2. b\n", "[list:1. ][:a⏎][list:2. ][:b⏎]")
    ex("1) a\n", "[list:1) ][:a⏎]")
    ex("-a\n", "[:-a⏎]")
    ex("1.a\n", "[:1.a⏎]")
    ex("12345678901. a\n", "[:12345678901. a⏎]")
    ex("- a\n  - b\n", "[list:- ][:a⏎  ][list:- ][:b⏎]")
    ex("- a\n    - b\n      - c\n", "[list:- ][:a⏎    ][list:- ][:b⏎      ][list:- ][:c⏎]")
    ex("- [ ] t\n", "[list:- ][task:[ ]][: t⏎]")
    ex("- [x] d\n", "[list:- ][task·checked:[x]][: d⏎]")
    ex("* [X] D\n", "[list:* ][task·checked:[X]][: D⏎]")
    ex("- [ ]x\n", "[list:- ][:[ ]x⏎]")
    ex("- [ ]\n", "[list:- ][task:[ ]][:⏎]")
    ex("1. [x] ordered task\n", "[list:1. ][task·checked:[x]][: ordered task⏎]")
    ex("-\n", "[list:-][:⏎]")
    ex("- \n  text\n", "[list:-][: ⏎  text⏎]")
    ex("para\n1. x\n", "[:para⏎][list:1. ][:x⏎]")
    ex("para\n2. x\n", "[:para⏎2. x⏎]", "only 1. can interrupt a paragraph")
    ex("para\n- x\n", "[:para⏎][list:- ][:x⏎]")
    ex("para\n-\n", "[:para⏎-⏎]")
    ex("- a\n\n  b\n", "[list:- ][:a⏎⏎  b⏎]")
    ex("- a\nlazy\n", "[list:- ][:a⏎lazy⏎]")
    ex("- a\n\nb\n", "[list:- ][:a⏎⏎b⏎]")
    ex("- *em* **b**\n", "[list:- ][italic·marker:*][italic:em][italic·marker:*][: ][bold·marker:**][bold:b][bold·marker:**][:⏎]")
    ex("- # h\n", "[list:- ][h1·marker:# ][h1:h⏎]")
    ex("- > q\n", "[list:- ][q1·marker:> ][q1:q⏎]")
    ex("-\ttab\n", "[list:-⇥][:tab⏎]")
    ex("\t- x\n", "[codeblock:⇥- x⏎]")
    ex("   - three\n", "[:   ][list:- ][:three⏎]")
    ex("- a\n * b\n", "[list:- ][:a⏎ ][list:* ][:b⏎]")
}

private func tableTests() {
    let basic = "[table·thead·tdelim:|][table·thead: a ][table·thead·tdelim:|][table·thead: b ][table·thead·tdelim:|][table·thead:⏎]" +
        "[table·tdelim:|---|---|⏎|][table: 1 ][table·tdelim:|][table: 2 ][table·tdelim:|][table:⏎]"
    ex("| a | b |\n|---|---|\n| 1 | 2 |\n", basic)
    ex("a | b\n--- | ---\n1 | 2\n",
       "[table·thead:a ][table·thead·tdelim:|][table·thead: b⏎][table·tdelim:--- | ---⏎][table:1 ][table·tdelim:|][table: 2⏎]")
    ex("| a | b |\n|---|\n", "[:| a | b |⏎|---|⏎]", "header / delimiter column counts must match")
    ex("| a |\n|---|\n| b |\n\ntext\n",
       "[table·thead·tdelim:|][table·thead: a ][table·thead·tdelim:|][table·thead:⏎][table·tdelim:|---|⏎|][table: b ][table·tdelim:|][table:⏎][:⏎text⏎]")
    ex("| *x* | `y` |\n|:-:|--:|\n",
       "[table·thead·tdelim:|][table·thead: ][italic·marker·table·thead:*][italic·table·thead:x][italic·marker·table·thead:*][table·thead: ][table·thead·tdelim:|][table·thead: ][code·marker·table·thead:`][code·table·thead:y][code·marker·table·thead:`][table·thead: ][table·thead·tdelim:|][table·thead:⏎][table·tdelim:|:-:|--:|⏎]")
    ex("| a \\| b |\n|---|\n", "[table·thead·tdelim:|][table·thead: a ][table·thead·esc:\\|][table·thead: b ][table·thead·tdelim:|][table·thead:⏎][table·tdelim:|---|⏎]")
    ex("text\n| a | b |\n|---|---|\n",
       "[:text⏎][table·thead·tdelim:|][table·thead: a ][table·thead·tdelim:|][table·thead: b ][table·thead·tdelim:|][table·thead:⏎][table·tdelim:|---|---|⏎]", "a table can interrupt a paragraph")
    ex("| a |\n|---|\n# h\n",
       "[table·thead·tdelim:|][table·thead: a ][table·thead·tdelim:|][table·thead:⏎][table·tdelim:|---|⏎][h1·marker:# ][h1:h⏎]", "another block ends the table")
    ex("|---|---|\n", "[:|---|---|⏎]", "no header row")
    ex("a\n|---|\n", "[table·thead:a⏎][table·tdelim:|---|⏎]", "one-column table")
    ex("> | a |\n> |---|\n> | b |\n",
       "[q1·marker:> ][q1·table·thead·tdelim:|][q1·table·thead: a ][q1·table·thead·tdelim:|][q1·table·thead:⏎][q1·marker:> ][q1·table·tdelim:|---|⏎][q1·marker:> ][q1·table·tdelim:|][q1·table: b ][q1·table·tdelim:|][q1·table:⏎]")
}

private func frontMatterAndHTMLTests() {
    ex("---\ntitle: x\n---\n# H\n", "[marker·fm:---⏎][fm:title: x⏎][marker·fm:---⏎][h1·marker:# ][h1:H⏎]")
    ex("---\na: b\n...\ntext\n", "[marker·fm:---⏎][fm:a: b⏎][marker·fm:...⏎][:text⏎]")
    ex("---\n---\n", "[hr:---⏎---⏎]", "empty front matter is two rules")
    ex("---\n\ntitle: x\n---\n", "[marker·fm:---⏎][fm:⏎title: x⏎][marker·fm:---⏎]", "a blank line before the first key is fine")
    ex("---\n# a comment\ntitle: x\n---\n", "[marker·fm:---⏎][fm:# a comment⏎title: x⏎][marker·fm:---⏎]", "a YAML comment first")
    ex("---\nlayout-2.x: post\n---\n", "[marker·fm:---⏎][fm:layout-2.x: post⏎][marker·fm:---⏎]", "a key with digits, hyphens and dots")
    ex("---\ntitle:no blank\n---\n", "[hr:---⏎][h2:title:no blank⏎][h2·marker:---][h2:⏎]", "a colon not followed by a blank is no key (a rule, then a setext heading)")
    ex("---\nSome prose.\n\n---\n\n# H\n", "[hr:---⏎][:Some prose.⏎⏎][hr:---⏎][:⏎][h1·marker:# ][h1:H⏎]", "a document that opens with a rule and prose: two rules, not front matter")
    ex("---\nunclosed\n", "[hr:---⏎][:unclosed⏎]", "unclosed front matter is an hr")
    ex("\n---\na: b\n---\n", "[:⏎][hr:---⏎][h2:a: b⏎][h2·marker:---][h2:⏎]", "front matter only at the very start")
    ex("---\nkey: v\n*not em*\n# not heading\n---\n", "[marker·fm:---⏎][fm:key: v⏎*not em*⏎# not heading⏎][marker·fm:---⏎]", "inside front matter nothing is Markdown")
    ex("---\n*not em*\n# not heading\n---\n", "[hr:---⏎][italic·marker:*][italic:not em][italic·marker:*][:⏎][h1·marker:# ][h1:not heading⏎][hr:---⏎]", "not YAML: a rule, a paragraph, a heading, a rule")
    ex("--- \nx: y\n---  \n", "[marker·fm:--- ⏎][fm:x: y⏎][marker·fm:---  ⏎]")
    ex("<div>\ntext\n</div>\n\nafter\n", "[html:<div>⏎text⏎</div>⏎][:⏎after⏎]")
    ex("<!-- a\nb -->\nafter\n", "[html:<!-- a⏎b -->⏎][:after⏎]")
    ex("<!-- a\nb\n", "[html:<!-- a⏎b⏎]", "an unclosed comment runs to the end")
    ex("<!-- x -->\ntext", "[html:<!-- x -->⏎][:text]")
    ex("<pre>\n*x*\n</pre>\ntext\n", "[html:<pre>⏎*x*⏎</pre>⏎][:text⏎]")
    ex("<span>text</span>\n", "[html:<span>][:text][html:</span>][:⏎]", "type 7 needs the whole line to be one tag")
    ex("<br>\ntext\n\nafter\n", "[html:<br>⏎text⏎][:⏎after⏎]", "type 7 block runs to the blank line")
    ex("para\n<br>\n", "[:para⏎][html:<br>][:⏎]", "type 7 cannot interrupt a paragraph")
    ex("para\n<div>\nx\n", "[:para⏎][html:<div>⏎x⏎]", "type 6 can interrupt a paragraph")
    ex("<?php\necho 1;\n?>\nx\n", "[html:<?php⏎echo 1;⏎?>⏎][:x⏎]")
    ex("<![CDATA[\nx\n]]>\ny\n", "[html:<![CDATA[⏎x⏎]]>⏎][:y⏎]")
    ex("> <div>\n> x\n\ny\n", "[q1·marker:> ][q1·html:<div>⏎][q1·marker:> ][q1·html:x⏎][:⏎y⏎]")
    ex("<script>\n*x*\n</script>\n", "[html:<script>⏎*x*⏎</script>⏎]")
}

private func referenceTests() {
    ex("[r]: http://x.com\n", "[marker·ref:[][ref:r][marker·ref:]:][: ][dest:http://x.com][:⏎]")
    ex("[r]: <u v> 'title'\n", "[marker·ref:[][ref:r][marker·ref:]:][: ][dest:<u v>][: ][dest:'title'][:⏎]")
    ex("[bad]: x y z\n", "[:[bad]: x y z⏎]")
    ex("[r]:\n", "[:[r]:⏎]")
    ex("para\n[r]: http://x.com\n", "[:para⏎[r]: ][auto:http://x.com][:⏎]", "a definition cannot interrupt a paragraph")
    ex("[^1]: footnote text\n", "[marker·fn:[^][fn:1][marker·fn:]:][: footnote text⏎]")
    ex("[^1]: a\n    more\n", "[marker·fn:[^][fn:1][marker·fn:]:][: a⏎    more⏎]", "continuation indented 4 spaces belongs to the footnote")
    ex("[^1]:\n", "[marker·fn:[^][fn:1][marker·fn:]:][:⏎]")
}
