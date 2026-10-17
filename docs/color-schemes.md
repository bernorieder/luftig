# Colour schemes

luftig has 16 colour schemes: its own default and 15 colour themes of well-known code editors (Solarized, GitHub, One, Gruvbox, Dracula, Nord,
Monokai, Tomorrow Night, Catppuccin, Tokyo Night). A scheme is chosen in the Settings window (luftig > Settings…, ⌘,; see the README) and applies to
every window at once. This document says what a scheme is made of, how a theme's palette becomes Markdown colours, what was changed to keep every
scheme legible (and by how much), where every colour comes from (sources, dates, licences), and how it is tested.

![All schemes: lists, quotes, code](screenshots/schemes/contact-sheet.png)
![All schemes: code blocks, tables](screenshots/schemes/contact-sheet-code.png)

(`docs/screenshots/schemes/<id>.png` are the full-size renders of `docs/showcase.md` from "## Lists" on, with an active selection across a quote; the second contact
sheet shows the "## Code" page (code blocks, tables) of every scheme; `regenerate.sh` makes all of them with the self-test build. The images were looked at one by one: hierarchy, harmony, code bands, quote bars, selection.)

| id | Name | Kind | Family |
|---|---|---|---|
| `luftig` | luftig (the default) | follows the system (light, dark, Increase contrast) | luftig |
| `solarized-light` | Solarized Light | light | Solarized |
| `solarized-dark` | Solarized Dark | dark | Solarized |
| `github-light` | GitHub Light | light | GitHub |
| `github-dark` | GitHub Dark | dark | GitHub |
| `one-light` | One Light | light | One |
| `one-dark` | One Dark | dark | One |
| `gruvbox-light` | Gruvbox Light | light | Gruvbox |
| `gruvbox-dark` | Gruvbox Dark | dark | Gruvbox |
| `dracula` | Dracula | dark | Dracula |
| `nord` | Nord | dark | Nord |
| `monokai` | Monokai | dark | Monokai |
| `tomorrow-night` | Tomorrow Night | dark | Tomorrow |
| `catppuccin-latte` | Catppuccin Latte | light | Catppuccin |
| `catppuccin-mocha` | Catppuccin Mocha | dark | Catppuccin |
| `tokyo-night` | Tokyo Night | dark | Tokyo Night |

## 1. The default scheme is unchanged

`luftig` is exactly the palette luftig had before there were schemes: the same values, the system's page, label and selection colours, the system's
light / dark / Increase-contrast behaviour. The renders of `docs/showcase.md` with the default scheme (24 images: light, dark, Increase contrast, selection
active and inactive, banner) are byte for byte the renders of the build before this change, and the `schemes-default` self-test holds the golden values
of every colour in the four variants. Every other scheme is a *fixed* light or dark look.

## 2. How it is wired

```
Sources/luftig/ColorSchemesData.swift    the authentic palettes (hex values) and which colour plays which Markdown role
Sources/luftig/ColorSchemesBuild.swift   roles -> tints -> surfaces -> the legibility step -> SchemeColors (the colours the editor uses)
Sources/luftig/ColorSchemesMath.swift    WCAG contrast, OKLab / OKLCH, ColorMath.fit (the adjustment)
Sources/luftig/ColorSchemes.swift        the public contract, SchemeColors, and the default scheme
Sources/luftig/Palette.swift             what the rest of the app reads: Palette.heading, ... (from the CURRENT scheme), Palette.apply(schemeID:)
```

```swift
enum SchemeAppearance { case system, light, dark }
struct ColorScheme { let id, name, family: String; let appearance: SchemeAppearance; let swatch: [NSColor] }   // swatch: page, text, heading, link, code
enum ColorSchemes { static let defaultID: String /* "luftig" */; static let all: [ColorScheme]; static func scheme(withID id: String) -> ColorScheme /* unknown -> default */ }
extension Palette { static var scheme: ColorScheme { get }; static func apply(schemeID: String) }
```

* `Palette.apply(schemeID:)` makes the scheme current, forces `NSApp.appearance` (Aqua for a light scheme, Dark Aqua for a dark one, `nil` = follow the
  system for the default), and, when the scheme really changed, posts `Palette.didChangeNotification` and marks the text views of the open windows
  for redisplay. Repeating the call with the current id does nothing. Main thread.
* The static accessors (`Palette.text`, `.heading`, `.codeBand`, ...) keep their names and types. They are plain loads of `NSColor` objects that were
  created ONCE per scheme (on first use: ~0.2 ms for a theme; switching back and forth builds nothing). Measured: `Palette.apply` median 0.2 ms; 300
  switches with a new Theme and a restyle each leave the process 1 MB bigger.
* A `LuftigEditorTextView` listens to `didChangeNotification` and sets its page colour, the scroll view's page colour and the insertion point colour
  (`LuftigEditorFactory.applySchemeColors`); the banner repaints. The decoration colours of the draw path are cached per (scheme, variant)
  (`DecorationDrawing.Colors`: the cache key contains `Palette.serial`, which is constant per scheme), so nothing stale can be drawn.
* **The colours of the TEXT are attributes** (`Theme` caches `NSColor` objects in its attribute dictionaries). After `apply` an editor must build a new
  `Theme` and restyle, exactly like after a font size change (`EditorViewController.rebuildTheme`). The order matters: `Palette.apply` first, then post
  `EditorPreferences.didChange` (the editors rebuild). A fixed scheme never depends on the window's appearance: a window whose `appearance` was forced to the
  other kind still draws the scheme's colours.
* Colours of a fixed scheme are dynamic only for the system's "Increase contrast" switch (`ContrastWatcher`), as before.

## 3. From a theme to luftig's Markdown roles

A good editor theme gives a handful of colours: page, text, comment, a title colour, an accent, link blue, a string colour. luftig maps them like this
(`ColorSchemesData.swift` lists the colours of every theme; the mixes are made in OKLab):

| luftig role | Used for | From the theme |
|---|---|---|
| background | the page | editor background |
| text, table text, code text | body text, tables, code | default foreground |
| heading | headings 1 - 4 | the theme's title / heading / keyword colour |
| headingMuted | headings 5, 6, footnote labels | heading mixed 40 % towards the text |
| accent | list markers, checked tasks, code-language label, image alt text, quote bar and tint | a second structural colour of the theme |
| link | link text (always underlined) | link / blue |
| copper (inline code, escapes) | inline code, backslash escapes | the string / inline-code / orange colour |
| marker | `#`, `*`, `` ` ``, `>`, fences, pipes | the comment colour |
| quote text | text of block quotes | text and comment, half and half |
| struck | ~~struck~~ text | text 25 %, comment 75 % |
| link destination, unchecked task | `(https://...)`, `[ ]` | text 35 %, comment 65 % |
| front matter | front matter | text and comment, half and half |
| html | HTML, comments | text 15 %, comment 85 % |
| caret | the insertion point | the theme's cursor colour |
| selection | the selected text | the theme's selection colour (below) |

The translucent decorations are the theme's OWN colours at the alphas of the default scheme (one table for every theme, no per-theme numbers):
code band, table / front matter panel, table header row and the rule are the text colour (the rule: 60 % towards black or white) at 5.5 / 8.5 %,
3.5 / 5 %, 7.5 / 10 % and 26 / 30 % (light / dark); the quote band, bar and nested quotes are the accent at 5 / 8.5 %, 55 / 65 % and 4 / 6 %; the
inline-code pill is the inline-code colour at 9 / 15 %; with Increase contrast the alphas of the default scheme's high-contrast variants and a hairline
around bands. They are derived from the AUTHENTIC colours, so the surfaces that text sits on do not move while text is adjusted.
The warning and information banners are the theme's yellow / orange and blue at up to 24 % / 20 % over the page.

**Selection and caret.** The selection is the theme's selection colour `Sel` (where the theme has none: one of its colours at an alpha, see the table). It
is painted TRANSLUCENT: a paint colour C at alpha a (0.5, 0.55 with Increase contrast) with `a*C + (1-a)*page = Sel`, so over the page it looks like the
theme and a code band, a quote band or an inline-code pill below it stays visible (the default scheme does the same with the system colour). The selection of
a window that is not key is the same colour desaturated to a third and 35 % closer to the page. A selection that is fainter than 1.22:1 against the page is
strengthened; one that would not leave body text 4.5:1 (or what the text has on the page) is weakened, never below that 1.22:1.

## 4. Legibility: the same thresholds for every scheme

The default scheme's self-test (`visual-contrast`) demands, on every surface a colour can sit on (page, code band, quote tint, nested quote tint, code in
a quote, inline-code pill, pill in a quote, table / front matter panel, table header): text colours >= 4.5:1, syntax markers >= 3:1; with Increase contrast
7:1 and 4.5:1; the caret >= 3:1; the quote bar against its tint 1.8:1 (3:1); body text >= 4.5:1 (7:1) and coloured text >= 3:1 on the selection; the
selection >= 1.08:1 against the page with the band still visible through it. Every scheme x both variants of its kind runs through the SAME tables
(`ColorSchemes.contrastRules` is the one table the builder fits to and the test checks), plus the text on the two banners and on the inactive selection.

Authentic theme colours often fail this (Solarized's own body text is 4.1:1 on its page; Nord's comments are 1.9:1). `ColorMath.fit` adjusts them,
deterministically, at the time the scheme is built:

1. A colour that already meets every requirement is used as it is (quantized to 8 bits).
2. Otherwise it moves in OKLCH, keeping HUE and CHROMA (reduced only where the sRGB gamut ends), and only its LIGHTNESS changes: towards black on a light
   scheme, towards white on a dark one, by the LEAST that satisfies every surface at once (binary search, 24 steps, on the 8-bit colour that is drawn).
3. The Increase-contrast variant starts from the colour in use and is pushed further the same way until 7:1 (markers 4.5:1). Colours that did not need to
   move for the normal variant but need to for 7:1 are listed under "Increase contrast" below.

Nothing is hand-tuned. The numbers below are generated by `luftig-SelfTest --selftest schemes-report --out report.md`. "Change" is the change of the OKLCH
lightness in points of 100 (negative: darker). A role that is not listed as changed is the theme's colour to the digit.

### What the legibility step changed

| Scheme | Appearance | Roles adjusted (normal) | Roles adjusted (Increase contrast) | Largest lightness change |
|---|---|---|---|---|
| Solarized Light | light | 12 of 13 | 12 of 13 | 16.5 |
| Solarized Dark | dark | 12 of 13 | 12 of 13 | 15.2 |
| GitHub Light | light | 1 of 13 | 7 of 13 | 1.5 |
| GitHub Dark | dark | 1 of 13 | 8 of 13 | 2.2 |
| One Light | light | 8 of 13 | 11 of 13 | 14.4 |
| One Dark | dark | 10 of 13 | 12 of 13 | 20.1 |
| Gruvbox Light | light | 7 of 13 | 12 of 13 | 11.7 |
| Gruvbox Dark | dark | 7 of 13 | 12 of 13 | 10.7 |
| Dracula | dark | 6 of 13 | 11 of 13 | 15.7 |
| Nord | dark | 9 of 13 | 12 of 13 | 27.7 |
| Monokai | dark | 6 of 13 | 10 of 13 | 15.2 |
| Tomorrow Night | dark | 3 of 13 | 12 of 13 | 0.6 |
| Catppuccin Latte | light | 10 of 13 | 13 of 13 | 17.5 |
| Catppuccin Mocha | dark | 1 of 13 | 11 of 13 | 1.9 |
| Tokyo Night | dark | 5 of 13 | 12 of 13 | 15.9 |



Reading the table: the GitHub themes, Tomorrow Night and Catppuccin Mocha are essentially authentic (largest change 2.2 points of lightness or less). Where a theme
moves, it is mostly the DIM roles, derived from the comment colour (syntax markers, struck text, link destinations, HTML / comments), which the themes keep at
2:1 - 3:1 and which must reach 3:1 - 4.5:1 here: Nord moves most (its comment colour is 1.9:1 on its page: markers +24, HTML +28 points), then One Dark (+17 to +20), Solarized
(about 15 either way), Dracula and Tokyo Night (+16). The only COLOURFUL roles that move by more than 10 points are Catppuccin Latte's peach accent
(`#fe640b` -> `#ad4000`, -17.5: pastel orange on a light page) and Monokai's pink accent (`#f92672` -> `#ff99ad`, +15: it has to stay 4.5:1 on its own pink
quote tint and 3:1 on the selection). With Increase contrast nearly every role moves (7:1).

### The worst case per scheme

Tightest text / surface pair, worst marker, worst caret and worst body text on the selection, as printed by `schemes-contrast` (a pair that is exactly at its
threshold - 4.50, 3.00, 7.00 - is where the adjustment stopped, by design):

```
scheme            variant      pairs  tightest pair (ratio)                           markers  caret  selection body
solarized-light   normal        66   link on nestedQuote 4.51                          3.02   4.32    4.50
solarized-light   increased     66   html / comment on nestedQuote 7.00                4.51   4.22    7.07
solarized-dark    normal        66   syntax marker on pillInQuote 3.00                 3.00   4.55    4.51
solarized-dark    increased     66   heading on nestedQuote 7.00                       4.52   4.50    7.00
github-light      normal        66   link on tableHeader 4.50                          4.92   4.21   11.18
github-light      increased     66   link destination / unchecked task on tableHead    4.70   4.00   10.98
github-dark       normal        66   link on tableHeader 4.51                          4.19   4.15    9.43
github-dark       increased     66   syntax marker on pillInQuote 4.50                 4.50   4.03    9.50
one-light         normal        66   quote text on nestedQuote 4.50                    3.01   3.26    7.85
one-light         increased     66   accent / list marker / image on nestedQuote 7.    4.55   3.12    7.72
one-dark          normal        66   front matter on panel 4.50                        3.01   3.24    4.60
one-dark          increased     66   link on tableHeader 7.00                          4.51   3.19    7.01
gruvbox-light     normal        66   accent / list marker / image on tableHeader 4.    3.00   8.52    6.41
gruvbox-light     increased     66   quote text on nestedQuote 7.00                    4.51   8.24    7.02
gruvbox-dark      normal        66   link destination / unchecked task on nestedQuo    3.02   6.91    5.70
gruvbox-dark      increased     66   strikethrough on nestedQuote 7.00                 4.51   7.01    7.05
dracula           normal        66   strikethrough on tableHeader 4.50                 3.01   8.55    7.49
dracula           increased     66   syntax marker on pillInQuote 4.50                 4.50   8.30    7.54
nord              normal        66   syntax marker on pillInQuote 3.00                 3.00   6.32    5.70
nord              increased     66   syntax marker on tableHeader 4.50                 4.50   6.17    7.03
monokai           normal        66   strikethrough on tableHeader 4.50                 3.00   8.90    5.70
monokai           increased     66   footnote label on tableHeader 7.00                4.53   8.65    7.95
tomorrow-night    normal        66   accent / list marker / image on tableHeader 4.    3.66   7.04    5.98
tomorrow-night    increased     66   inline code / escape (copper) on pillInQuote 7    4.53   6.88    7.75
catppuccin-latte  normal        66   quote text on nestedQuote 4.51                    3.02   3.01    5.48
catppuccin-latte  increased     66   heading on nestedQuote 7.00                       4.52   3.00    7.03
catppuccin-mocha  normal        66   html / comment on nestedQuote 4.52                3.37   8.44    6.54
catppuccin-mocha  increased     66   footnote label on nestedQuote 7.00                4.54   8.60    7.09
tokyo-night       normal        66   syntax marker on pillInQuote 3.01                 3.01   7.38    6.76
tokyo-night       increased     66   heading on nestedQuote 7.00                       4.51   7.36    7.53
1980 text / surface pairs checked over 15 schemes x 2 variants
```

### The authentic palettes and what each colour is used for

| Scheme | page | text | comment | heading | accent | link | inline code | selection | caret |
|---|---|---|---|---|---|---|---|---|---|
| Solarized Light | `#fdf6e3` | `#657b83` | `#93a1a1` | `#cb4b16` | `#6c71c4` | `#268bd2` | `#2aa198` | `#268bd2` at 22 % | `#586e75` |
| Solarized Dark | `#002b36` | `#839496` | `#586e75` | `#cb4b16` | `#6c71c4` | `#268bd2` | `#2aa198` | `#268bd2` at 35 % | `#93a1a1` |
| GitHub Light | `#ffffff` | `#1f2328` | `#59636e` | `#0550ae` | `#6639ba` | `#0969da` | `#953800` | `#0969da` at 20 % | `#0969da` |
| GitHub Dark | `#0d1117` | `#f0f6fc` | `#9198a1` | `#79c0ff` | `#d2a8ff` | `#4493f8` | `#ffa657` | `#4493f8` at 30 % | `#4493f8` |
| One Light | `#fafafa` | `#383a42` | `#a0a1a7` | `#e45649` | `#a626a4` | `#4078f2` | `#50a14f` | `#e5e5e6` | `#526fff` |
| One Dark | `#282c34` | `#abb2bf` | `#5c6370` | `#e06c75` | `#c678dd` | `#61afef` | `#98c379` | `#3e4451` | `#528bff` |
| Gruvbox Light | `#fbf1c7` | `#3c3836` | `#928374` | `#79740e` | `#b57614` | `#076678` | `#af3a03` | `#d5c4a1` | `#3c3836` |
| Gruvbox Dark | `#282828` | `#ebdbb2` | `#928374` | `#b8bb26` | `#fabd2f` | `#83a598` | `#fe8019` | `#504945` | `#ebdbb2` |
| Dracula | `#282a36` | `#f8f8f2` | `#6272a4` | `#bd93f9` | `#ff79c6` | `#8be9fd` | `#50fa7b` | `#44475a` | `#f8f8f2` |
| Nord | `#2e3440` | `#d8dee9` | `#4c566a` | `#88c0d0` | `#b48ead` | `#81a1c1` | `#a3be8c` | `#434c5e` | `#d8dee9` |
| Monokai | `#272822` | `#f8f8f2` | `#88846f` | `#a6e22e` | `#f92672` | `#66d9ef` | `#fd971f` | `#878b91` at 50 % | `#f8f8f0` |
| Tomorrow Night | `#1d1f21` | `#c5c8c6` | `#969896` | `#de935f` | `#b294bb` | `#81a2be` | `#b5bd68` | `#373b41` | `#c5c8c6` |
| Catppuccin Latte | `#eff1f5` | `#4c4f69` | `#7c7f93` | `#8839ef` | `#fe640b` | `#1e66f5` | `#40a02b` | `#7c7f93` at 20 % | `#dc8a78` |
| Catppuccin Mocha | `#1e1e2e` | `#cdd6f4` | `#9399b2` | `#cba6f7` | `#fab387` | `#89b4fa` | `#a6e3a1` | `#9399b2` at 25 % | `#f5e0dc` |
| Tokyo Night | `#1a1b26` | `#c0caf5` | `#565f89` | `#7aa2f7` | `#bb9af7` | `#7dcfff` | `#ff9e64` | `#283457` | `#c0caf5` |

(The banner colours `warn` / `info` are in the source file.) Where the theme defines no selection, the selection is one of its colours at the alpha shown:
Solarized (blue), GitHub (its accent blue; the VS Code theme uses the same blue at a low alpha), Monokai (`#878b91` at 50 %, as in VS Code's Monokai), Catppuccin
(overlay2 at 20 / 25 %: "Selection Background: Overlay 2, 20% - 30% Opacity" in the style guide). Dracula's `#44475A`, Tomorrow Night's `#373b41`, One's
`@syntax-selection-color` and Tokyo Night's `bg_visual` are the themes' own; Gruvbox's (bg2) and Nord's (nord2) are our choice from the palette.

### Adjustments in detail

Per scheme, role by role: the colour the role would have without any adjustment ("authentic": the theme's colour or the mix described above), the colour in use,
and the Increase-contrast colour. `=` means unchanged.

#### Solarized Light

Page `#fdf6e3`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#657b83` | `#4e646b` | -8.0 | `#2f444b` | -11.6 |
| quote text | `#7c8e92` | `#596a6e` | -12.1 | `#3c4c50` | -10.7 |
| strikethrough | `#879799` | `#5b6a6c` | -15.3 | `#3e4c4e` | -10.7 |
| heading | `#cb4b16` | `#b93d00` | -4.8 | `#872900` | -11.2 |
| heading h5/h6, footnote | `#a8654f` | `#975641` | -5.2 | `#753824` | -10.7 |
| accent (list marker, checked task, code language, image, quote bar) | `#6c71c4` | `#5c5fb1` | -5.9 | `#41408f` | -10.6 |
| link | `#268bd2` | `#006cac` | -10.1 | `#004d7c` | -10.8 |
| link destination, unchecked task | `#839496` | `#5a6a6d` | -14.0 | `#3d4c4f` | -10.7 |
| inline code, escape | `#2aa198` | `#00746d` | -14.0 | `#00524d` | -10.8 |
| front matter | `#7c8e92` | `#607175` | -9.7 | `#435357` | -10.6 |
| html / comment | `#8c9b9c` | `#5c6a6c` | -16.5 | `#3f4c4e` | -10.7 |
| syntax marker | `#93a1a1` | `#798687` | -8.8 | `#5b6869` | -10.3 |
| insertion point | `#586e75` | = | - | = | - |

Note: the selection colour is weakened towards the page (1 steps of 12 %, now #d4e1e0 over the page) so that the text keeps its contrast on it (normal variant)

#### Solarized Dark

Page `#002b36`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#839496` | `#95a7a9` | +6.1 | `#d8ecee` | +21.4 |
| quote text | `#6d8185` | `#8da1a5` | +10.6 | `#b2c7cb` | +12.0 |
| strikethrough | `#63777d` | `#8ca1a7` | +13.9 | `#b4cad0` | +13.0 |
| heading | `#cb4b16` | `#fb7648` | +13.5 | `#ffb095` | +11.1 |
| heading h5/h6, footnote | `#b46f55` | `#d48c71` | +9.7 | `#ffb497` | +12.7 |
| accent (list marker, checked task, code language, image, quote bar) | `#6c71c4` | `#8f97ed` | +12.3 | `#bac2ff` | +12.4 |
| link | `#268bd2` | `#44a4ec` | +7.9 | `#8eccff` | +12.8 |
| link destination, unchecked task | `#677b80` | `#8ca1a6` | +12.6 | `#b4cacf` | +13.0 |
| inline code, escape | `#2aa198` | `#46b7ad` | +6.9 | `#71dfd4` | +12.3 |
| front matter | `#6d8185` | `#81969a` | +7.0 | `#a7bdc1` | +12.5 |
| html / comment | `#5e747a` | `#8ba1a8` | +15.2 | `#b3cad1` | +13.0 |
| syntax marker | `#586e75` | `#738991` | +9.2 | `#92a9b1` | +10.4 |
| insertion point | `#93a1a1` | = | - | = | - |

Note: the selection colour is weakened towards the page (6 steps of 12 %, now #043b4f over the page) so that the text keeps its contrast on it (normal variant)

#### GitHub Light

Page `#ffffff`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#1f2328` | = | - | = | - |
| quote text | `#3b424a` | = | - | = | - |
| strikethrough | `#4a525b` | = | - | `#424a53` | -2.9 |
| heading | `#0550ae` | = | - | `#00469f` | -3.5 |
| heading h5/h6, footnote | `#193f76` | = | - | = | - |
| accent (list marker, checked task, code language, image, quote bar) | `#6639ba` | = | - | `#5a29ab` | -4.6 |
| link | `#0969da` | `#0064d5` | -1.5 | `#004699` | -11.4 |
| link destination, unchecked task | `#444b54` | = | - | `#434a52` | -0.4 |
| inline code, escape | `#953800` | = | - | `#7f2e00` | -5.2 |
| front matter | `#3b424a` | = | - | = | - |
| html / comment | `#505963` | = | - | `#424a54` | -5.4 |
| syntax marker | `#59636e` | = | - | = | - |
| insertion point | `#0969da` | = | - | = | - |

#### GitHub Dark

Page `#0d1117`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#f0f6fc` | = | - | = | - |
| quote text | `#bfc6ce` | = | - | = | - |
| strikethrough | `#a8afb7` | = | - | `#bcc3cb` | +6.3 |
| heading | `#79c0ff` | = | - | `#7cc2ff` | +0.6 |
| heading h5/h6, footnote | `#aad6ff` | = | - | = | - |
| accent (list marker, checked task, code language, image, quote bar) | `#d2a8ff` | = | - | `#d7b4ff` | +2.6 |
| link | `#4493f8` | `#4b9aff` | +2.2 | `#99c5ff` | +12.9 |
| link destination, unchecked task | `#b1b8c0` | = | - | `#bcc3cb` | +3.5 |
| inline code, escape | `#ffa657` | = | - | `#ffb372` | +2.7 |
| front matter | `#bfc6ce` | = | - | = | - |
| html / comment | `#9fa6ae` | = | - | `#bcc3cb` | +9.2 |
| syntax marker | `#9198a1` | = | - | `#959da6` | +1.6 |
| insertion point | `#4493f8` | = | - | = | - |

#### One Light

Page `#fafafa`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#383a42` | = | - | = | - |
| quote text | `#6a6b73` | `#65666e` | -1.8 | `#47474f` | -11.1 |
| strikethrough | `#84868c` | `#65666d` | -10.8 | `#47474e` | -11.1 |
| heading | `#e45649` | `#be3229` | -10.6 | `#950003` | -11.2 |
| heading h5/h6, footnote | `#9e4f4a` | = | - | `#7b2f2d` | -11.0 |
| accent (list marker, checked task, code language, image, quote bar) | `#a626a4` | = | - | `#830082` | -9.6 |
| link | `#4078f2` | `#295ed6` | -8.1 | `#0a3bb2` | -10.7 |
| link destination, unchecked task | `#7a7b82` | `#65666d` | -7.2 | `#47474e` | -11.1 |
| inline code, escape | `#50a14f` | `#217524` | -14.3 | `#005407` | -10.8 |
| front matter | `#6a6b73` | = | - | `#505058` | -9.5 |
| html / comment | `#8f9097` | `#65666d` | -14.4 | `#47474e` | -11.1 |
| syntax marker | `#a0a1a7` | `#828288` | -10.1 | `#636268` | -10.9 |
| insertion point | `#526fff` | = | - | = | - |

Note: selection colour strengthened towards the text colour (1 steps of 5 %) to be visible against the page: #dbdcdd

#### One Dark

Page `#282c34`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#abb2bf` | = | - | `#dce4f1` | +15.5 |
| quote text | `#828997` | `#a3abb8` | +10.9 | `#cad2df` | +12.3 |
| strikethrough | `#6f7683` | `#a3abb9` | +17.5 | `#cdd6e4` | +13.4 |
| heading | `#e06c75` | `#fe878e` | +8.6 | `#ffc3c4` | +11.5 |
| heading h5/h6, footnote | `#cf8b93` | `#dd989f` | +4.2 | `#ffc7cb` | +13.1 |
| accent (list marker, checked task, code language, image, quote bar) | `#c678dd` | `#db8cf2` | +6.4 | `#f2c6ff` | +12.5 |
| link | `#61afef` | `#62b1f1` | +0.6 | `#aedaff` | +13.4 |
| link destination, unchecked task | `#777e8b` | `#a3abb8` | +14.8 | `#cdd6e3` | +13.4 |
| inline code, escape | `#98c379` | = | - | `#c0eca0` | +12.5 |
| front matter | `#828997` | `#939aa8` | +5.5 | `#bbc3d1` | +13.0 |
| html / comment | `#676e7b` | `#a3abb9` | +20.1 | `#cdd6e4` | +13.4 |
| syntax marker | `#5c6370` | `#8c94a1` | +16.6 | `#acb5c2` | +10.6 |
| insertion point | `#528bff` | = | - | = | - |

Note: the selection colour is weakened towards the page (2 steps of 12 %, now #393e4a over the page) so that the text keeps its contrast on it (normal variant)

#### Gruvbox Light

Page `#fbf1c7`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#3c3836` | = | - | `#34312f` | -2.9 |
| quote text | `#655c54` | = | - | `#4f463e` | -8.0 |
| strikethrough | `#7b6f64` | `#6b6054` | -5.5 | `#4c4136` | -11.3 |
| heading | `#79740e` | `#6c6700` | -4.4 | `#4d4900` | -10.6 |
| heading h5/h6, footnote | `#5f5c2b` | = | - | `#484412` | -8.6 |
| accent (list marker, checked task, code language, image, quote bar) | `#b57614` | `#895700` | -11.7 | `#603b00` | -11.3 |
| link | `#076678` | = | - | `#004a59` | -9.3 |
| link destination, unchecked task | `#72685d` | `#6a6056` | -2.7 | `#4b4138` | -11.3 |
| inline code, escape | `#af3a03` | `#ae3a02` | -0.2 | `#7c2500` | -11.4 |
| front matter | `#655c54` | = | - | `#534a43` | -6.5 |
| html / comment | `#84776a` | `#6c5f53` | -8.4 | `#4d4136` | -11.0 |
| syntax marker | `#928374` | `#8a7b6d` | -2.7 | `#6b5d50` | -10.5 |
| insertion point | `#3c3836` | = | - | = | - |

#### Gruvbox Dark

Page `#282828`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#ebdbb2` | = | - | `#faeac0` | +4.5 |
| quote text | `#beae92` | `#c1b195` | +1.0 | `#e9d9bc` | +12.4 |
| strikethrough | `#a89883` | `#c0b19b` | +7.9 | `#e8d8c2` | +12.2 |
| heading | `#b8bb26` | = | - | `#dde258` | +11.8 |
| heading h5/h6, footnote | `#ccc86b` | = | - | `#e2df81` | +7.0 |
| accent (list marker, checked task, code language, image, quote bar) | `#fabd2f` | = | - | `#ffd582` | +5.9 |
| link | `#83a598` | `#98bbad` | +7.0 | `#bee3d4` | +12.3 |
| link destination, unchecked task | `#b0a189` | `#c0b198` | +5.1 | `#e8d9bf` | +12.4 |
| inline code, escape | `#fe8019` | `#ff9a58` | +4.8 | `#ffd2b7` | +11.7 |
| front matter | `#beae92` | = | - | `#cfbfa2` | +5.3 |
| html / comment | `#9f907d` | `#c0b19d` | +10.7 | `#e8d8c3` | +12.2 |
| syntax marker | `#928374` | `#9e8f7f` | +4.0 | `#bfaf9e` | +10.4 |
| insertion point | `#ebdbb2` | = | - | = | - |

Note: the selection colour is weakened towards the page (1 steps of 12 %, now #4b4541 over the page) so that the text keeps its contrast on it (Increase contrast variant)

#### Dracula

Page `#282a36`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#f8f8f2` | = | - | = | - |
| quote text | `#aab3cc` | = | - | `#cad4ed` | +10.2 |
| strikethrough | `#8592b8` | `#a7b6dd` | +11.4 | `#dae5ff` | +14.4 |
| heading | `#bd93f9` | `#c399ff` | +1.9 | `#decbff` | +11.4 |
| heading h5/h6, footnote | `#d4bcf8` | = | - | `#ece0ff` | +9.0 |
| accent (list marker, checked task, code language, image, quote bar) | `#ff79c6` | `#ff94cf` | +4.1 | `#ffdced` | +13.2 |
| link | `#8be9fd` | = | - | `#aaf0ff` | +3.1 |
| link destination, unchecked task | `#94a0c0` | `#aab6d7` | +7.2 | `#dbe5ff` | +14.4 |
| inline code, escape | `#50fa7b` | = | - | `#7eff96` | +3.0 |
| front matter | `#aab3cc` | = | - | `#bdc7e0` | +6.2 |
| html / comment | `#7785b0` | `#a6b6e3` | +15.7 | `#dbe5ff` | +14.3 |
| syntax marker | `#6272a4` | `#8597cb` | +12.2 | `#a5b8ee` | +10.5 |
| insertion point | `#f8f8f2` | = | - | = | - |

#### Nord

Page `#2e3440`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#d8dee9` | = | - | `#e8effa` | +5.1 |
| quote text | `#8f97a7` | `#acb5c6` | +9.6 | `#d5def0` | +12.8 |
| strikethrough | `#6d7688` | `#b2bdd0` | +23.2 | `#e1ecff` | +14.5 |
| heading | `#88c0d0` | = | - | `#ade7f7` | +11.9 |
| heading h5/h6, footnote | `#a9ccda` | = | - | `#cef1ff` | +11.3 |
| accent (list marker, checked task, code language, image, quote bar) | `#b48ead` | `#d8b1d1` | +11.3 | `#ffe4fa` | +14.3 |
| link | `#81a1c1` | `#9fc0e1` | +9.8 | `#dceeff` | +14.6 |
| link destination, unchecked task | `#7a8395` | `#b3bdcf` | +18.8 | `#e1ecff` | +14.4 |
| inline code, escape | `#a3be8c` | `#acc895` | +3.1 | `#d7f5c0` | +13.6 |
| front matter | `#8f97a7` | `#9ea7b7` | +5.1 | `#c8d2e2` | +13.5 |
| html / comment | `#5f697c` | `#b2bdd2` | +27.7 | `#e1ecff` | +14.4 |
| syntax marker | `#4c566a` | `#919cb3` | +23.9 | `#b3bfd6` | +11.1 |
| insertion point | `#d8dee9` | = | - | = | - |

Note: the selection colour is weakened towards the page (1 steps of 12 %, now #40495a over the page) so that the text keeps its contrast on it (Increase contrast variant)

#### Monokai

Page `#272822`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#f8f8f2` | = | - | = | - |
| quote text | `#bebcae` | = | - | `#c3c1b2` | +1.5 |
| strikethrough | `#a3a08e` | `#b6b3a1` | +6.2 | `#e4e1ce` | +14.3 |
| heading | `#a6e22e` | = | - | = | - |
| heading h5/h6, footnote | `#c7ec8f` | = | - | `#c7ed8f` | +0.2 |
| accent (list marker, checked task, code language, image, quote bar) | `#f92672` | `#ff99ad` | +15.2 | `#ffd7dd` | +12.1 |
| link | `#66d9ef` | = | - | `#97eeff` | +7.3 |
| link destination, unchecked task | `#aeab9b` | `#b6b3a3` | +2.6 | `#e4e1d0` | +14.3 |
| inline code, escape | `#fd971f` | `#ffa13f` | +2.1 | `#ffdab9` | +12.3 |
| front matter | `#bebcae` | = | - | `#c5c3b4` | +2.2 |
| html / comment | `#989582` | `#b7b39f` | +9.9 | `#e5e1cc` | +14.3 |
| syntax marker | `#88846f` | `#96917c` | +4.4 | `#bbb6a0` | +11.9 |
| insertion point | `#f8f8f0` | = | - | = | - |

Note: the selection colour is weakened towards the page (4 steps of 12 %, now #434543 over the page) so that the text keeps its contrast on it (Increase contrast variant)

#### Tomorrow Night

Page `#1d1f21`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#c5c8c6` | = | - | `#dee2e0` | +7.9 |
| quote text | `#adb0ae` | = | - | `#c2c5c3` | +6.6 |
| strikethrough | `#a2a4a2` | = | - | `#c7cac7` | +11.9 |
| heading | `#de935f` | = | - | `#ffb480` | +10.2 |
| heading h5/h6, footnote | `#d6a98a` | = | - | `#eec0a0` | +7.2 |
| accent (list marker, checked task, code language, image, quote bar) | `#b294bb` | `#b495bd` | +0.5 | `#dfbee8` | +13.2 |
| link | `#81a2be` | `#82a4c0` | +0.6 | `#aaceeb` | +13.2 |
| link destination, unchecked task | `#a6a9a7` | = | - | `#c6cac7` | +10.3 |
| inline code, escape | `#b5bd68` | = | - | `#ced781` | +8.0 |
| front matter | `#adb0ae` | = | - | `#b1b5b2` | +1.5 |
| html / comment | `#9d9f9d` | `#9ea09e` | +0.3 | `#c7cac7` | +13.2 |
| syntax marker | `#969896` | = | - | `#a6a9a6` | +5.4 |
| insertion point | `#c5c8c6` | = | - | = | - |

#### Catppuccin Latte

Page `#eff1f5`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#4c4f69` | = | - | `#3c3e58` | -6.2 |
| quote text | `#63677e` | `#61647c` | -0.9 | `#44465d` | -10.8 |
| strikethrough | `#707388` | `#606278` | -5.7 | `#424458` | -11.0 |
| heading | `#8839ef` | `#8432e9` | -1.6 | `#6500bd` | -10.6 |
| heading h5/h6, footnote | `#6f4ab8` | = | - | `#552c98` | -9.6 |
| accent (list marker, checked task, code language, image, quote bar) | `#fe640b` | `#ad4000` | -17.5 | `#7b2b00` | -11.4 |
| link | `#1e66f5` | `#0d57e5` | -4.5 | `#003aac` | -11.0 |
| link destination, unchecked task | `#6b6e84` | `#606278` | -4.0 | `#424458` | -11.0 |
| inline code, escape | `#40a02b` | `#1c7300` | -13.9 | `#105100` | -10.6 |
| front matter | `#63677e` | = | - | `#484b61` | -10.0 |
| html / comment | `#75788d` | `#606277` | -7.4 | `#424458` | -10.9 |
| syntax marker | `#7c7f93` | `#7c7e92` | -0.3 | `#5f6074` | -10.3 |
| insertion point | `#dc8a78` | `#b96a5a` | -10.5 | `#b76858` | -0.6 |

#### Catppuccin Mocha

Page `#1e1e2e`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#cdd6f4` | = | - | `#d4defc` | +2.4 |
| quote text | `#b0b7d3` | = | - | `#c6cdea` | +6.9 |
| strikethrough | `#a1a8c2` | = | - | `#c6cee9` | +11.9 |
| heading | `#cba6f7` | = | - | `#ddc3ff` | +7.2 |
| heading h5/h6, footnote | `#ccbaf6` | = | - | `#d7c5ff` | +3.3 |
| accent (list marker, checked task, code language, image, quote bar) | `#fab387` | = | - | `#ffc19a` | +3.4 |
| link | `#89b4fa` | = | - | `#b2d0ff` | +8.5 |
| link destination, unchecked task | `#a7aec9` | = | - | `#c6cee9` | +10.0 |
| inline code, escape | `#a6e3a1` | = | - | `#adeba8` | +2.4 |
| front matter | `#b0b7d3` | = | - | = | - |
| html / comment | `#9ba2bc` | `#a1a8c1` | +1.9 | `#c6cee7` | +11.9 |
| syntax marker | `#9399b2` | = | - | `#aab1ca` | +7.6 |
| insertion point | `#f5e0dc` | = | - | = | - |

#### Tokyo Night

Page `#1a1b26`.

| Role | Authentic | In use | Change (OKLCH L) | Increase contrast | Change |
|---|---|---|---|---|---|
| body text / code text | `#c0caf5` | = | - | `#cbd4ff` | +3.2 |
| quote text | `#8993be` | `#949ec9` | +3.6 | `#b8c3ef` | +11.7 |
| strikethrough | `#6f78a3` | `#939eca` | +12.3 | `#b9c5f2` | +12.3 |
| heading | `#7aa2f7` | = | - | `#a8c4ff` | +10.2 |
| heading h5/h6, footnote | `#96b2f7` | = | - | `#aec6ff` | +6.0 |
| accent (list marker, checked task, code language, image, quote bar) | `#bb9af7` | = | - | `#d2bcff` | +8.5 |
| link | `#7dcfff` | = | - | `#7ed0ff` | +0.3 |
| link destination, unchecked task | `#7983ae` | `#939eca` | +8.8 | `#b9c5f2` | +12.3 |
| inline code, escape | `#ff9e64` | = | - | `#ffc09c` | +7.0 |
| front matter | `#8993be` | = | - | `#a5afdb` | +9.1 |
| html / comment | `#656e99` | `#939ecb` | +15.9 | `#b9c5f3` | +12.3 |
| syntax marker | `#565f89` | `#7984b0` | +12.6 | `#98a3d1` | +10.2 |
| insertion point | `#c0caf5` | = | - | = | - |


## 5. Sources, dates and licences

All palettes were read from their authors' own sites or repositories (read-only, 2026-10-16; page content was treated as data). The colour values are
facts; the names belong to their authors. Where a repository states a licence, it is given; luftig contains the hex values only, no code or files of these
projects.

| Scheme | Source of the values (read 2026-10-16) | Licence of the source |
|---|---|---|
| Solarized | https://ethanschoonover.com/solarized/ ; the 16-colour table of https://github.com/altercation/solarized (README.md) | MIT, Copyright (c) 2011 Ethan Schoonover (LICENSE) |
| GitHub Light / Dark | `@primer/primitives` 10.4.0: `dist/css/functional/themes/light.css` and `dark.css` (https://unpkg.com/@primer/primitives@10.4.0/dist/css/functional/themes/) - fgColor, bgColor, borderColor, `--color-prettylights-syntax-*` | MIT, Copyright (c) 2018 GitHub Inc. (https://github.com/primer/primitives) |
| One Light / One Dark | Atom's `one-light-syntax` / `one-dark-syntax` `styles/colors.less` and `syntax-variables.less` (https://github.com/atom/atom/tree/master/packages): HSL values converted to sRGB by us, `@syntax-selection-color`, `@syntax-accent` | MIT, Copyright (c) 2011-2022 GitHub Inc. (atom/atom LICENSE.md) |
| Gruvbox Light / Dark | https://github.com/morhetz/gruvbox `colors/gruvbox.vim` (`light0`, `dark0`, `faded_*`, `bright_*`, `gray`) | "MIT/X11" as stated on the repository page; the copyright line of its LICENSE file could not be read (the raw URL gave 404) |
| Dracula | https://draculatheme.com/contribute (the official palette: Background, Selection `#44475A`, Foreground, Comment, Red ... Pink). The page lists "Current Line" as `#6272A4`; Selection `#44475A` is used | MIT, Copyright (c) 2023 Dracula Theme (https://github.com/dracula/dracula-theme LICENSE) |
| Nord | https://www.nordtheme.com/docs/colors-and-palettes (nord0 - nord15) | MIT, Copyright (c) 2016-present Sven Greb (repository page https://github.com/nordtheme/nord; nordtheme.com: (c) 2016-2020 Arctic Ice Studio & Sven Greb) |
| Monokai | VS Code's Monokai theme: https://github.com/microsoft/vscode `extensions/theme-monokai/themes/monokai-color-theme.json` (editor colours, `markup.heading`, `markup.inline.raw`, comment `#88846f`). After Wimer Hazenberg's Monokai | MIT, Copyright (c) 2015 - present Microsoft Corporation (vscode LICENSE.txt) |
| Tomorrow Night | https://github.com/chriskempson/tomorrow-theme `vim/colors/Tomorrow-Night.vim` | MIT, Copyright (C) 2011 Chris Kempson (LICENSE.md) |
| Catppuccin Latte / Mocha | https://github.com/catppuccin/palette `palette.json`; the usage rules (cursor = Rosewater, comments = Overlay 2, links = Blue, selection = Overlay 2 at 20 - 30 %) from https://github.com/catppuccin/catppuccin `docs/style-guide.md` | MIT, Copyright (c) 2021 Catppuccin (palette LICENSE) |
| Tokyo Night | https://github.com/folke/tokyonight.nvim `extras/lua/tokyonight_night.lua` (bg, fg, comment, blue, cyan, magenta, orange, `bg_visual`) | Apache-2.0 (the neovim port that was read; the original theme is by enkia, whose licence was not read) |

Which colour plays which Markdown role (heading, accent, inline code, link) is luftig's choice. Of the sources above only VS Code's Monokai defines Markdown colours
(`markup.heading` green, `markup.inline.raw` orange, used here) and the Catppuccin style guide names links (blue); the other themes' roles follow their usual syntax colours
(strings, keywords, functions, headings of their editors' UIs) and were not checked against each theme's own Markdown syntax definitions.

## 6. Tests

`luftig-SelfTest --selftest schemes-roles,schemes-contrast,schemes-apply,schemes-selection,schemes-default` (all in `all`; `visual-contrast` runs the
scheme table too):

* `schemes-roles` (111 checks): 16 schemes, unique ids / names, 11 families, the requested themes exist, dark / light classification, an unknown id gives
  the default; for every scheme all 35 colour roles are defined, in range, with the right alpha, in both variants; heading / text / accent / link / copper are five
  different colours; the accessors return the same objects every time.
* `schemes-contrast` (30 checks, 1,980 text / surface pairs): every scheme x both variants of its kind x every surface, the thresholds above, caret, quote bar,
  hairline, selection (active and inactive), banners, "a fixed scheme resolves the same under either appearance"; prints the table of section 4.
* `schemes-apply` (12 checks): 60 switches in random order through all 16 schemes: `NSApp.appearance` is forced (nil for the default), page / caret / decoration colours
  of an OPEN window are the new scheme's without a rebuild, a new `Theme` holds the new colour objects, a window that lived through the switches is pixel-identical to a fresh
  one (every sixth switch, both ends), one notification per real switch and none for a repeat, 300 more switches with a restyle each leave RSS +1 MB, building the 15 schemes
  from scratch takes 3 ms, a read of `Palette.x` is a load, a window whose `appearance` is forced to the other kind draws a fixed scheme identically.
* `schemes-selection` (30 checks): on pixels, for each of the 15 schemes: the selection is visible against the page, the band shows through it, active and inactive differ,
  the layout manager paints exactly `Palette.selectionFill`.
* `schemes-default` (12 checks): the default scheme's 12 text colours, 9 decoration colours, text, page and banners in the four variants equal the values of the build
  before schemes; the default colour objects come back after another scheme.
* `render --scheme <id>` renders the real editor window with a scheme; `regenerate.sh` in `docs/screenshots/schemes/` makes all the images.
* `matrix-visual` (partial redraw == full draw, no stale rows, the selection), `matrix-indent`, `matrix-preview` and `matrix-print` run the schemes together with other fonts, sizes, line spacings and column widths
  (the pixel scenarios `visual-bands` and the quote-bar checks assume the default look: a white page and the default bar colour).

## 7. Adding a scheme

Add a `SchemeSpec` to `SchemeSpec.all` in `ColorSchemesData.swift` (page, text, comment, heading, accent, link, inline code, banner colours, caret, selection), add its id
to `requiredSchemeIDs` and to `regenerate.sh`, run `schemes-roles,schemes-contrast,schemes-selection`. The legibility step makes it pass the tables; look at the render.

## 8. Not verified

* The look in a real key window (the active selection is simulated in the offscreen renders, as before) and with the real "Increase contrast" switch (the self-test overrides the
  flag). The Settings window and its live switching are covered by the `settings-*` and `matrix-*` scenarios (headless: the controls are driven with `sendAction`, nothing was dragged with a real mouse).
* The role choices (which theme colour is the heading, the accent, the inline code) are a taste decision, looked at on the renders, not checked against each theme's Markdown rules.
* Printing: `MarkdownDocument.printOperation` prints plain text in its own view and does not use the scheme. `matrix-print` prints to PDF under the default scheme, a dark scheme, a dark system
  appearance and a light scheme on a dark system: always dark text on a white page.
