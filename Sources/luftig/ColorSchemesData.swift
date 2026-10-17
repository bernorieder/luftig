import AppKit

// ColorSchemesData.swift - the AUTHENTIC palettes of the colour schemes: the hex values of well-known editor themes, as their authors publish them,
// and which of them plays which Markdown role. Nothing here is adjusted for legibility (ColorSchemesBuild.swift does that, deterministically, and
// docs/color-schemes.md lists what it changed). Sources, dates and licences: docs/color-schemes.md. Colour values are facts; the names belong to
// their authors.
//
// How a theme is mapped onto Markdown (the way a good editor theme does it):
//   bg       the theme's editor background                       -> the page
//   fg       its default foreground                              -> body text, code text
//   comment  its comment colour                                  -> syntax markers (#, *, `, >, fences), and (mixed with fg) quotes, struck text, link destinations, HTML
//   heading  its title / heading / keyword colour                -> headings
//   accent   a second structural colour of the theme             -> list markers, checked tasks, code-language label, image alt text, quote bar and tint
//   link     its link / function / blue                          -> links
//   literal  its string / inline-code / orange colour            -> inline code, backslash escapes
//   warn     its yellow / orange                                 -> the tint of the warning banner
//   info     its blue                                            -> the tint of the information banner
//   caret    its cursor colour                                   -> the insertion point
//   selection its selection colour (opaque), or a colour of the theme at an alpha (where the theme only defines it that way)

struct SchemeSpec {
    enum Selection {
        /// The colour the theme shows for selected text over the page.
        case opaque(UInt32)
        /// A theme colour at this alpha over the page.
        case over(UInt32, Double)
    }

    let id: String
    let name: String
    let family: String
    let dark: Bool
    let bg, fg, comment, heading, accent, link, literal, warn, info, caret: UInt32
    let selection: Selection

    var scheme: ColorScheme {
        func c(_ h: UInt32) -> NSColor { let v = ColorMath.rgb(hex: h); return NSColor(srgbRed: v.x, green: v.y, blue: v.z, alpha: 1) }
        return ColorScheme(id: id, name: name, family: family, appearance: dark ? .dark : .light, swatch: [c(bg), c(fg), c(heading), c(link), c(literal)])
    }

    static let all: [SchemeSpec] = [
        // Solarized, Ethan Schoonover (MIT). Light: body = base00 on base3, comments = base1. Dark: body = base0 on base03, comments = base01.
        // Headings = orange, accent = violet, link = blue, inline code = cyan (the theme's string colour): luftig's choice. Solarized defines no selection
        // colour: the blue at 22 % / 35 % over the page. Caret: base01 (light) / base1 (dark), the theme's "emphasized content" tones.
        SchemeSpec(id: "solarized-light", name: "Solarized Light", family: "Solarized", dark: false,
                   bg: 0xfdf6e3, fg: 0x657b83, comment: 0x93a1a1, heading: 0xcb4b16, accent: 0x6c71c4, link: 0x268bd2, literal: 0x2aa198,
                   warn: 0xb58900, info: 0x268bd2, caret: 0x586e75, selection: .over(0x268bd2, 0.22)),
        SchemeSpec(id: "solarized-dark", name: "Solarized Dark", family: "Solarized", dark: true,
                   bg: 0x002b36, fg: 0x839496, comment: 0x586e75, heading: 0xcb4b16, accent: 0x6c71c4, link: 0x268bd2, literal: 0x2aa198,
                   warn: 0xb58900, info: 0x268bd2, caret: 0x93a1a1, selection: .over(0x268bd2, 0.35)),

        // GitHub, @primer/primitives 10.4.0 (MIT): functional themes light / dark. Body = fgColor-default, comments = prettylights comment, headings = the
        // syntax "constant" blue (= prettylights markup-heading in the light theme), accent = prettylights entity (purple), link = fgColor-accent, inline code =
        // prettylights variable (orange). Selection: GitHub's accent blue at 20 % / 30 % (luftig's choice), caret = the accent.
        SchemeSpec(id: "github-light", name: "GitHub Light", family: "GitHub", dark: false,
                   bg: 0xffffff, fg: 0x1f2328, comment: 0x59636e, heading: 0x0550ae, accent: 0x6639ba, link: 0x0969da, literal: 0x953800,
                   warn: 0x953800, info: 0x0969da, caret: 0x0969da, selection: .over(0x0969da, 0.20)),
        SchemeSpec(id: "github-dark", name: "GitHub Dark", family: "GitHub", dark: true,
                   bg: 0x0d1117, fg: 0xf0f6fc, comment: 0x9198a1, heading: 0x79c0ff, accent: 0xd2a8ff, link: 0x4493f8, literal: 0xffa657,
                   warn: 0xf2cc60, info: 0x4493f8, caret: 0x4493f8, selection: .over(0x4493f8, 0.30)),

        // One Light / One Dark, Atom's one-light-syntax / one-dark-syntax (MIT; the HSL values of the .less files converted to sRGB). Headings = hue-5 red,
        // accent = hue-3 purple, link = hue-2 blue, inline code = hue-4 green (luftig's choice among the theme's hues). Selection = the themes'
        // @syntax-selection-color (lighten / darken of the page), caret = @syntax-accent.
        SchemeSpec(id: "one-light", name: "One Light", family: "One", dark: false,
                   bg: 0xfafafa, fg: 0x383a42, comment: 0xa0a1a7, heading: 0xe45649, accent: 0xa626a4, link: 0x4078f2, literal: 0x50a14f,
                   warn: 0xb76b01, info: 0x4078f2, caret: 0x526fff, selection: .opaque(0xe5e5e6)),
        SchemeSpec(id: "one-dark", name: "One Dark", family: "One", dark: true,
                   bg: 0x282c34, fg: 0xabb2bf, comment: 0x5c6370, heading: 0xe06c75, accent: 0xc678dd, link: 0x61afef, literal: 0x98c379,
                   warn: 0xe5c07b, info: 0x61afef, caret: 0x528bff, selection: .opaque(0x3e4451)),

        // Gruvbox, Pavel Pertsev (MIT/X11), colors/gruvbox.vim. Light: light0 page, dark1 text, faded_* accents; dark: dark0 page, light1 text, bright_*
        // accents (the colours the scheme pairs with each background). Headings = green, accent = yellow, link = blue, inline code = orange (luftig's choice).
        // Selection = bg2 of each mode (our choice from the palette).
        SchemeSpec(id: "gruvbox-light", name: "Gruvbox Light", family: "Gruvbox", dark: false,
                   bg: 0xfbf1c7, fg: 0x3c3836, comment: 0x928374, heading: 0x79740e, accent: 0xb57614, link: 0x076678, literal: 0xaf3a03,
                   warn: 0xb57614, info: 0x076678, caret: 0x3c3836, selection: .opaque(0xd5c4a1)),
        SchemeSpec(id: "gruvbox-dark", name: "Gruvbox Dark", family: "Gruvbox", dark: true,
                   bg: 0x282828, fg: 0xebdbb2, comment: 0x928374, heading: 0xb8bb26, accent: 0xfabd2f, link: 0x83a598, literal: 0xfe8019,
                   warn: 0xfabd2f, info: 0x83a598, caret: 0xebdbb2, selection: .opaque(0x504945)),

        // Dracula, draculatheme.com/contribute (MIT). Headings = purple, accent = pink, link = cyan, inline code = green (luftig's choice), selection = the
        // spec's "Selection" #44475A, caret = foreground.
        SchemeSpec(id: "dracula", name: "Dracula", family: "Dracula", dark: true,
                   bg: 0x282a36, fg: 0xf8f8f2, comment: 0x6272a4, heading: 0xbd93f9, accent: 0xff79c6, link: 0x8be9fd, literal: 0x50fa7b,
                   warn: 0xf1fa8c, info: 0x8be9fd, caret: 0xf8f8f2, selection: .opaque(0x44475a)),

        // Nord, Arctic Ice Studio / Sven Greb (MIT), nord0 ... nord15. Page nord0, text nord4, comments nord3, headings nord8 (frost), accent nord15,
        // link nord9, inline code nord14 (luftig's choice), selection nord2 (our choice from the palette), caret nord4.
        SchemeSpec(id: "nord", name: "Nord", family: "Nord", dark: true,
                   bg: 0x2e3440, fg: 0xd8dee9, comment: 0x4c566a, heading: 0x88c0d0, accent: 0xb48ead, link: 0x81a1c1, literal: 0xa3be8c,
                   warn: 0xebcb8b, info: 0x81a1c1, caret: 0xd8dee9, selection: .opaque(0x434c5e)),

        // Monokai, as VS Code ships it (microsoft/vscode extensions/theme-monokai, MIT; after Wimer Hazenberg's TextMate theme). Headings = green
        // (markup.heading), accent = pink (keyword), link = blue, inline code = orange (markup.inline.raw). Selection #878b91 at 50 %, caret #f8f8f0.
        SchemeSpec(id: "monokai", name: "Monokai", family: "Monokai", dark: true,
                   bg: 0x272822, fg: 0xf8f8f2, comment: 0x88846f, heading: 0xa6e22e, accent: 0xf92672, link: 0x66d9ef, literal: 0xfd971f,
                   warn: 0xe6db74, info: 0x66d9ef, caret: 0xf8f8f0, selection: .over(0x878b91, 0.50)),

        // Tomorrow Night, Chris Kempson (MIT), vim/colors/Tomorrow-Night.vim. Headings = orange, accent = purple, link = blue, inline code = green (strings).
        SchemeSpec(id: "tomorrow-night", name: "Tomorrow Night", family: "Tomorrow", dark: true,
                   bg: 0x1d1f21, fg: 0xc5c8c6, comment: 0x969896, heading: 0xde935f, accent: 0xb294bb, link: 0x81a2be, literal: 0xb5bd68,
                   warn: 0xf0c674, info: 0x81a2be, caret: 0xc5c8c6, selection: .opaque(0x373b41)),

        // Catppuccin Latte / Mocha (MIT), catppuccin/palette + docs/style-guide.md. Page base, text text, comments overlay2 (style guide), link blue (style guide), caret
        // rosewater (style guide), selection overlay2 at 20 % / 25 % (style guide: 20 - 30 %). The style guide has no Markdown colours: headings mauve (the flavour's signature
        // colour), accent peach, inline code green (our choice).
        SchemeSpec(id: "catppuccin-latte", name: "Catppuccin Latte", family: "Catppuccin", dark: false,
                   bg: 0xeff1f5, fg: 0x4c4f69, comment: 0x7c7f93, heading: 0x8839ef, accent: 0xfe640b, link: 0x1e66f5, literal: 0x40a02b,
                   warn: 0xdf8e1d, info: 0x1e66f5, caret: 0xdc8a78, selection: .over(0x7c7f93, 0.20)),
        SchemeSpec(id: "catppuccin-mocha", name: "Catppuccin Mocha", family: "Catppuccin", dark: true,
                   bg: 0x1e1e2e, fg: 0xcdd6f4, comment: 0x9399b2, heading: 0xcba6f7, accent: 0xfab387, link: 0x89b4fa, literal: 0xa6e3a1,
                   warn: 0xf9e2af, info: 0x89b4fa, caret: 0xf5e0dc, selection: .over(0x9399b2, 0.25)),

        // Tokyo Night (night), folke/tokyonight.nvim extras/lua/tokyonight_night.lua (Apache-2.0; after enkia's Tokyo Night). Headings = blue, accent =
        // magenta, link = cyan, inline code = orange, selection = bg_visual, caret = fg.
        SchemeSpec(id: "tokyo-night", name: "Tokyo Night", family: "Tokyo Night", dark: true,
                   bg: 0x1a1b26, fg: 0xc0caf5, comment: 0x565f89, heading: 0x7aa2f7, accent: 0xbb9af7, link: 0x7dcfff, literal: 0xff9e64,
                   warn: 0xe0af68, info: 0x7aa2f7, caret: 0xc0caf5, selection: .opaque(0x283457)),
    ]
}
