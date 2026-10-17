---
title: luftig showcase
author: The luftig team
tags: [markdown, editor, "visual source"]
draft: false
---

# luftig showcase

This document exercises **every construct** the Markdown lexer knows, so you can judge
the colours, the spacing and the decorations at a glance. It is also the manual test
document: open it, resize the window, switch between light and dark, press ⌘+ and ⌘−,
and type into it.

Setext heading, level one
=========================

Setext heading, level two
-------------------------

## Headings

### Third level heading

#### Fourth level heading

##### Fifth level heading

###### Sixth level heading

A heading may contain *emphasis*, `code` and a [link](https://example.com) and still
looks like a heading:

## A heading with **bold**, *italic*, `code` and a [link](https://example.com/heading)

## Emphasis and friends

Plain text, **strong text**, *emphasised text*, ***strong and emphasised***, ~~struck
through~~, and `inline code` in one line, also **`strong code`** and *`emphasised code`*. Underscores work as well: __strong__ and
_emphasis_, but snake_case_words stay untouched, and 2 * 3 * 4 is arithmetic.
Backslash escapes keep punctuation literal: \*not emphasis\*, \# not a heading, 1\.
not a list. Entities such as &amp; and &copy; and &#169; are styled too. A hard line
break ends this line with two spaces  
and continues here. A very long paragraph wraps inside the readable column, and the
text stays readable because the line length is limited to roughly 75 characters: lorem
ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut
labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation
ullamco laboris nisi ut aliquip ex ea commodo consequat.

Words that cannot break wrap at the column edge: Pneumonoultramicroscopicsilicovolcanoconiosis_and_an_identifier_without_any_space_that_has_to_wrap_somewhere,
and so does a long address: https://example.com/a/very/long/path/that/never/ends/and/keeps/going/until/it/wraps/around/the/readable/column

## Links, images and references

An [inline link](https://example.com/path?query=1 "with a title"), a [reference link][ref], a [collapsed reference][],
an autolink <https://example.com/auto>, a bare URL https://example.com/bare and an email <someone@example.com>.
An image: ![Alt text for the image](images/diagram.png "Image title") and a linked image
[![badge](https://img.example.com/badge.svg)](https://example.com).

A footnote reference[^1] and another one[^note] sit in the text.

[ref]: https://example.com/reference "Reference title"
[collapsed]: https://example.com/collapsed
[^1]: The first footnote, with *emphasis*.
[^note]: A second footnote with `code`.

## Lists

- A bullet item
- Another bullet item with **bold** text
  - A nested item
  - Another nested item
    - Nesting can go deeper
- Back at the top level

1. First ordered item
2. Second ordered item
   1. Nested ordered item
   2. Another nested ordered item
3. Third ordered item

* Asterisk bullets
+ and plus bullets are bullets too

### Task lists

- [ ] An open task
- [x] A finished task
- [X] Another finished task, with `code` and a [link](https://example.com)
  - [ ] A nested open task

## Block quotes

> A block quote is marked with a bar at the left edge. Its text is muted but still easy to read, and
> a quote may span several lines, with **bold**, *italic* and `code` inside.
>
> > A nested quote gets a second bar and a deeper indent.
> > > And a third level, for good measure.
>
> Back to the first level, with a list:
>
> - one item in the quote
> - another item in the quote
>
> ```swift
> let quoted = "code inside a quote"
> ```
>
> A heading and a rule belong to the quote too:
>
> ### Heading in a quote
>
> ---
>
> and the bar runs on through all of it.

Two quotes in a row, separated by a blank line, and a quote right after a block of code:

> The first quote.

> The second quote, with a deeper one:
> > nested, and nested again
> > > three levels

```
code, then a quote directly below
```
> A quote after the code.

## Code

An inline `code span`, a `span with `` backticks inside`, and a command like `swift
build -c release`.

```swift
import AppKit

/// A fenced code block: a tinted band, dim fences, a coloured language label.
struct Greeter {
    let name: String

    func greet(times: Int = 1) -> String {
        (0..<times).map { _ in "Hello, \(name)!" }.joined(separator: "\n")
    }
}

print(Greeter(name: "luftig").greet(times: 2))   // a trailing comment
```

~~~json
{ "tilde": "fences work too", "numbers": [1, 2, 3], "nested": { "ok": true } }
~~~

```
A fence without a language.
    Indentation is kept, and so are trailing spaces.   
```

An indented code block needs a blank line before it:

    $ git status
    On branch main
    nothing to commit, working tree clean

## Tables

| Left aligned | Centered | Right aligned | With `code` |
|:-------------|:--------:|--------------:|-------------|
| one          |   two    |         three | `x = 1`     |
| **bold**     |  *ital*  |      ~~gone~~ | [link](#)   |
| a longer cell value | b |             c | d           |

| Key | Value |
|-----|-------|
| Pipes align | because tables use a monospaced font |

## Rules

Three kinds of horizontal rules follow.

---

***

___

## HTML and comments

<!-- A comment is dimmed and coloured, so it does not shout. -->

<div class="note">
  <p>An HTML block is shown as-is, in its own colour.</p>
</div>

Inline HTML such as <kbd>⌘</kbd> + <kbd>B</kbd> and <span style="color: red">spans</span> is
recognised as well, and an inline comment <!-- like this --> is dimmed with the rest.

## Other scripts

日本語のテキストもここにあります。中文文本也在这里。한국어 텍스트도 있습니다。
Emoji work, too: 😀 🎉 👩‍💻 🇩🇪, and so do accents: Größenänderung, café, naïve, Ångström.

مرحبا بكم في luftig — هذا نص عربي من اليمين إلى اليسار.
שלום עולם — טקסט בעברית.

- عنصر قائمة بالعربية
- פריט ברשימה

> اقتباس بالعربية: the marker and the bar stay on the left

## Long list items

A list item that wraps hangs: its second and following lines start under the first character of the item's text, not under the marker. Narrow the window to see more of it.

- A bullet item whose text is long enough to wrap around the window more than once, so that the continuation lines can show where they start: under the "A", not under the dash.
- A second bullet with `inline code`, **bold text**, *emphasis* and a [link with a rather long address](https://example.com/a/rather/long/address/that/goes/on) inside a long sentence that wraps as well.
  - A nested item, indented by two spaces, whose long text also wraps and lines up with its own first character, not with that of its parent.
    - A third level, indented by four spaces, again with enough words in it to need more than a single line of the window.
	- A tab-indented item: the tab is measured like any other character, so this one lines up as well, however long its text is.

1. An ordered item with a long text that wraps around the window, so that the lines after the first one start under the "A" and not under the number.
9. Nine has one digit, and the long text that follows it wraps in the same way as that of every other item in the list.
10. Ten has two digits, so its text starts further to the right, and the wrapped lines follow it there.
100. A hundred has three digits; the text starts further to the right still, and so do the lines that wrap.

- [ ] An open task with a long text that wraps around the window: the wrapped lines start after the task marker, under the first letter of the text.
- [x] A finished task with a long text that wraps around the window in just the same way as that of the open task above it.

> - A quoted bullet with a long text that wraps around the window, next to the bar of the quote, under the first letter of its text.
> 1. A quoted ordered item with a long text that wraps around the window and keeps its bar, its band and its alignment all together.
> > 1. A doubly quoted ordered item with a long text that wraps around the window, one level deeper than the item above it.

- A hard-wrapped item, whose first line is short
  and whose second line is long enough to wrap by itself: it hangs by its own two spaces of indentation, so the wrapped part lines up with the line it belongs to.

## The end

The last paragraph ends the document.
