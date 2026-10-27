import AppKit
import MarkdownKit

/// One style run: complete attribute dictionary for a UTF-16 range (font + colour + paragraph style + custom keys).
/// `setAttributes` semantics: the dictionary REPLACES whatever was there, so it is always complete.
struct StyledRun {
    var range: NSRange
    var attributes: [NSAttributedString.Key: Any]
}

typealias TextAttributes = [NSAttributedString.Key: Any]

/// MDStyle -> complete attribute dictionary, cached per style value. Everything derives from ONE base font size, so a font-size
/// change is "make a new Theme" (new caches), re-apply the base attributes, restyle.
///
/// The contract with the text engine (docs/spike-textkit.md, docs/ARCHITECTURE.md):
///  * UNIFORM LINE HEIGHTS: every paragraph style has minimumLineHeight == maximumLineHeight (body: 1.5 x base). Styled and not yet
///    styled text have the same height, which is what keeps the scroller and scroll positions stable while styling lazily.
///    Headings get a fixed taller height per level (the only text whose height changes when it is styled).
///  * the paragraph style is IDENTICAL on every run of a paragraph, including its newline (TextKit takes it from the first
///    character). It is derived from the line-level facets only (heading level, quote depth, code / rule / table / front matter),
///    see `LineKey` and `styledRuns` (the `> ` prefix runs of a quote line take the style of the rest of their line).
///  * `.luftigBlock` is on every character of a code / quote / rule line including its newline; `.luftigInline` on inline code
///    including the backticks.
final class Theme {
    /// Everything this theme was built from. A change of any of it is "make a new Theme".
    let settings: ThemeSettings
    let baseSize: CGFloat
    let monoSize: CGFloat
    /// The body line box, whole points: base size x the line-height factor (the automatic curve unless the user chose one), but never less than
    /// the natural height (ascent + descent) of the tallest face a body line can hold, so that glyphs never overlap.
    let bodyLineHeight: CGFloat
    /// What the factor alone asked for, before that floor: `bodyLineHeight > requestedLineHeight` means the line box was raised to fit the fonts.
    let requestedLineHeight: CGFloat
    let bodyFont: NSFont
    let monoFont: NSFont
    /// The families actually in use. nil = the system font. A saved family that is no longer installed is nil here (the preference is not touched).
    let bodyFamily: String?
    let codeFamily: String?
    /// Advance of one character of the monospaced font: code, tables and front matter use tab stops of 4 of them (Markdown counts a tab as 4 columns).
    let monoAdvance: CGFloat

    private var cache: [UInt64: TextAttributes] = [:]
    private var fontCache: [FontKey: FontFace] = [:]
    private var paragraphCache: [UInt32: NSParagraphStyle] = [:]
    private var headingFloorCache: [CGFloat] = [-1, -1, -1, -1, -1, -1, -1]
    private var charBuffer = [unichar](repeating: 0, count: 4096)
    /// Widths of the prefixes of hanging list lines (HangingIndent.swift); per theme, like the other caches.
    let hangMeasurer = HangMeasurer()

    static let headingScales: [CGFloat] = [1, 1.6, 1.35, 1.18, 1.05, 1.0, 1.0]

    /// Line height / font size: looser for small text, tighter for large text (a well-set page: 1.46 at 11 pt, 1.42 at 16 pt, 1.38 at 20 pt,
    /// 1.31 at 28 pt). It was a flat 1.5, which is airy once every blank line is a whole line of it.
    static func lineHeightRatio(baseSize: CGFloat) -> CGFloat { min(1.5, max(1.3, 1.56 - 0.009 * baseSize)) }
    /// Heading line box = this x the heading font size (the font's own height is ~1.19 x the size): room for the glyphs, not for air.
    static let headingLineRatio: CGFloat = 1.3

    init(settings: ThemeSettings) {
        self.settings = settings
        let size = settings.baseSize
        let mono = Theme.codeSize(baseSize: size, scale: settings.codeScale)
        let body = FontFactory.resolve(settings.bodyFamily), code = FontFactory.resolve(settings.codeFamily)
        baseSize = size
        monoSize = mono
        bodyFamily = body
        codeFamily = code
        bodyFont = FontFactory.face(family: body, mono: false, size: size, weight: .regular, italic: false).font
        let monoFace = FontFactory.face(family: code, mono: true, size: mono, weight: .regular, italic: false).font
        monoFont = monoFace
        monoAdvance = ("0" as NSString).size(withAttributes: [.font: monoFace]).width
        let requested = (size * (settings.lineHeightFactor ?? Theme.lineHeightRatio(baseSize: size))).rounded()
        requestedLineHeight = requested
        // faces a body line can hold: text (regular / list marker / bold, each also italic) and code (inline code, code blocks, tables)
        var fonts: [NSFont] = []
        for weight in [NSFont.Weight.regular, .semibold, .bold] {
            for italic in [false, true] {
                fonts.append(FontFactory.face(family: body, mono: false, size: size, weight: weight, italic: italic).font)
                fonts.append(FontFactory.face(family: code, mono: true, size: mono, weight: weight, italic: italic).font)
            }
        }
        let floor = FontFactory.lineExtent(fonts)
        bodyLineHeight = max(requested, floor.rounded(.up))
    }

    convenience init(baseSize: CGFloat = 16) { self.init(settings: ThemeSettings(baseSize: baseSize)) }

    // MARK: sizes

    /// Size of the code font for text of `baseSize`: `scale` times it, to half a point (also inline code in a heading, at the heading's size).
    static func codeSize(baseSize: CGFloat, scale: CGFloat) -> CGFloat { (baseSize * scale * 2).rounded() / 2 }

    func headingSize(_ level: Int) -> CGFloat { level <= 0 ? baseSize : (baseSize * Theme.headingScales[min(6, level)]).rounded() }
    func lineHeight(headingLevel level: Int) -> CGFloat {
        level <= 0 ? bodyLineHeight : max(bodyLineHeight, (headingSize(level) * Theme.headingLineRatio).rounded(), headingFloor(level))
    }
    /// A heading line box is never smaller than the glyphs it holds: the natural height of the heading faces (and of inline code in a heading) at that size.
    private func headingFloor(_ level: Int) -> CGFloat {
        let l = min(6, level)
        if headingFloorCache[l] >= 0 { return headingFloorCache[l] }
        let size = headingSize(l), code = Theme.codeSize(baseSize: size, scale: settings.codeScale)
        var fonts = [FontFactory.face(family: bodyFamily, mono: false, size: baseSize, weight: .regular, italic: false).font]      // the `#` marker keeps the body size
        for weight in [NSFont.Weight.semibold, .bold] {
            for italic in [false, true] {
                fonts.append(FontFactory.face(family: bodyFamily, mono: false, size: size, weight: weight, italic: italic).font)
                fonts.append(FontFactory.face(family: codeFamily, mono: true, size: code, weight: weight, italic: italic).font)
            }
        }
        let floor = FontFactory.lineExtent(fonts)
        headingFloorCache[l] = floor.rounded(.up)
        return headingFloorCache[l]
    }
    /// Space above a heading line (on top of the blank line the source usually has there): a heading belongs to what follows it, so it
    /// gets a little more room above than below. The blank line after it is a whole body line, which is the other half of the rhythm.
    func spacingBefore(headingLevel level: Int) -> CGFloat {
        switch level {
        case 1: return (baseSize * 0.55).rounded()
        case 2: return (baseSize * 0.45).rounded()
        case 3: return (baseSize * 0.3).rounded()
        case 4: return (baseSize * 0.15).rounded()
        default: return 0
        }
    }

    /// Attributes a text view needs to display text that has not been styled yet (also what unstyled Markdown text gets).
    var baseAttributes: TextAttributes { attributes(for: MDStyle()) }

    // MARK: runs

    /// Lexer runs -> styled runs, with the LINE-LEVEL attributes (paragraph style, block mark) taken from the whole LINE.
    ///
    /// The lexer's runs are exact for what each piece of text IS, but a line is often made of runs with different line-level
    /// facets: the `> ` prefix runs of a quote line (`> > x` is `[q1 marker][q2 marker][q2 text]`), the unstyled indentation of
    /// a continuation line inside a setext heading or of a fence inside a list item (`[: item\n  ][fence: ```\n]`: the two spaces
    /// are the tail of the PREVIOUS run). TextKit takes the paragraph style from the first character of a line, so a line must carry
    /// ONE paragraph style and ONE block mark. Rule: the line-level facets of a line are those of the run that holds its LINE BREAK
    /// (the lexer gives the line break the style of the line it ends); every character of the line adopts them. Runs that span
    /// several lines are split at the line breaks where the lines differ. Character-level attributes (font, colour, underline, ...)
    /// always come from the run itself.
    ///
    /// `text` is needed for the line breaks and for one more thing: telling a setext underline (`====`, `----`) from an ATX marker
    /// (`# `): the underline LINE is shown as a plain dim line (body height, no spacing before), not as a second, tall heading line.
    func styledRuns(_ lexRuns: [MDRun], text: NSString) -> [StyledRun] {
        let lexCount = lexRuns.count
        guard lexCount > 0 else { return [] }
        let start = lexRuns[0].range.location
        let end = NSMaxRange(lexRuns[lexCount - 1].range)
        let length = end - start
        if charBuffer.count < length { charBuffer = [unichar](repeating: 0, count: max(length, charBuffer.count * 2)) }
        charBuffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: start, length: length)) }

        // Setext underline lines (`====`, `----`): the marker run and the part of the next run up to its FIRST line break. That next run
        // may go on over later lines (the lexer coalesces equal styles: `[h2 marker: ---][h2: \n title: x\n tags: y]`), so it is split
        // there; the result does not depend on how the lexer happened to cut the runs (incremental regions vs a whole-text lex).
        var work = lexRuns
        var underlineRuns = Set<Int>()
        var hasUnderline = false
        for i in 0..<lexCount where Theme.isHeadingMarker(lexRuns[i].style) {
            let c = charBuffer[lexRuns[i].range.location - start]
            if c == 0x3D || c == 0x2D { hasUnderline = true; break }
        }
        if hasUnderline {
            work = []
            work.reserveCapacity(lexCount + 8)
            var i = 0
            while i < lexCount {
                let run = lexRuns[i]
                work.append(run)
                if Theme.isHeadingMarker(run.style) {
                    let c = charBuffer[run.range.location - start]
                    if c == 0x3D || c == 0x2D {
                        underlineRuns.insert(work.count - 1)
                        if i + 1 < lexCount {
                            let next = lexRuns[i + 1]
                            var firstBreakEnd = -1
                            var k = next.range.location - start
                            let hi = NSMaxRange(next.range) - start
                            while k < hi {
                                let ch = charBuffer[k]
                                if ch == 0x0A { firstBreakEnd = k + 1 + start; break }
                                if ch == 0x0D { firstBreakEnd = (k + 1 < hi && charBuffer[k + 1] == 0x0A ? k + 2 : k + 1) + start; break }
                                k += 1
                            }
                            if firstBreakEnd > 0 && firstBreakEnd < NSMaxRange(next.range) {
                                work.append(MDRun(range: NSRange(location: next.range.location, length: firstBreakEnd - next.range.location), style: next.style))
                                underlineRuns.insert(work.count - 1)
                                work.append(MDRun(range: NSRange(location: firstBreakEnd, length: NSMaxRange(next.range) - firstBreakEnd), style: next.style))
                            } else {
                                work.append(next)
                                underlineRuns.insert(work.count - 1)
                            }
                            i += 2
                            continue
                        }
                    }
                }
                i += 1
            }
        }
        let runs = work
        let n = runs.count

        var out: [StyledRun] = []
        out.reserveCapacity(n + n / 8)
        // Right-to-left lines (Arabic, Hebrew, ...) get a right-aligned paragraph style, so a line's direction must be known per LINE. Only when the
        // region contains a right-to-left character at all (one pass over the buffer): everything below is then split at line breaks where the
        // direction changes. Left-to-right text takes the old path unchanged.
        let hasRTL = Theme.containsRightToLeft(charBuffer, count: length)
        var rtlLineStart = -1, rtlLineEnd = -1, rtlLineResult = false          // one-line cache for `lineIsRTL`: [start, end) of the last line asked about
        func isBreak(_ k: Int) -> Bool {
            let c = charBuffer[k]
            return c == 0x0A || (c == 0x0D && !(k + 1 < length && charBuffer[k + 1] == 0x0A))
        }
        /// Direction of the line that contains buffer index `k`: the first strong character decides (the Unicode default).
        func lineIsRTL(containing k: Int) -> Bool {
            if k >= rtlLineStart && k < rtlLineEnd { return rtlLineResult }
            var s = k
            while s > 0, !isBreak(s - 1) { s -= 1 }
            var e = k
            while e < length, !isBreak(e) { e += 1 }                            // the line's end, so that every further run of this line is a cache hit
            var result = false
            var j = s
            while j < e {
                let d = Theme.strongDirection(charBuffer[j])
                if d != 0 { result = d == 2; break }
                j += 1
            }
            rtlLineStart = s; rtlLineEnd = min(length, e + 1); rtlLineResult = result       // the line break itself belongs to the line
            return result
        }
        // Hanging lines (HangingIndent.swift): list items and indented continuation lines get a head indent, a per-LINE number like the direction.
        let hangs: [HangLine] = charBuffer.withUnsafeBufferPointer { buf in
            hangingLines(runs: runs, start: start, buffer: buf, length: length, isRTLLine: hasRTL ? { lineIsRTL(containing: $0) } : nil)
        }
        let hasHangs = !hangs.isEmpty
        /// Head indent (half points) of the line that contains buffer index `k`; 0: the line does not hang.
        func hangIndent(containing k: Int) -> Int {
            var lo = 0, hi = hangs.count - 1, found = -1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                if hangs[mid].start <= k { found = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return found >= 0 && k < hangs[found].end ? hangs[found].indent : 0
        }
        /// Append the styled run(s) for `range` (absolute offsets), walking BACKWARDS like the caller (the result is reversed at the end).
        /// A piece can hold several lines; it is split wherever the direction or the head indent changes from one line to the next.
        /// `singleLine`: the caller knows that the piece holds no line break except possibly its last character (nothing to split).
        func emit(_ range: NSRange, _ style: MDStyle, _ lineStyle: MDStyle, _ underline: Bool, singleLine: Bool = false) {
            guard range.length > 0 else { return }
            guard hasRTL || hasHangs else {
                out.append(StyledRun(range: range, attributes: attributes(for: style, lineStyle: lineStyle, underline: underline)))
                return
            }
            if singleLine {
                let last = NSMaxRange(range) - start - 1
                out.append(StyledRun(range: range, attributes: attributes(for: style, lineStyle: lineStyle, underline: underline,
                                                                           rtl: hasRTL && lineIsRTL(containing: last), hang: hasHangs ? hangIndent(containing: last) : 0)))
                return
            }
            let lo = range.location - start
            var end = NSMaxRange(range) - start                  // exclusive end of the piece being built, buffer coordinates
            var k = end
            var pieceRTL = hasRTL && lineIsRTL(containing: end - 1)
            var pieceHang = hasHangs ? hangIndent(containing: end - 1) : 0
            while k > lo {
                var s = k - 1                                    // the line that ends at k starts after the previous break
                while s > lo, !isBreak(s - 1) { s -= 1 }
                let rtl = hasRTL && lineIsRTL(containing: s)
                let hang = hasHangs ? hangIndent(containing: s) : 0
                if rtl != pieceRTL || hang != pieceHang {
                    out.append(StyledRun(range: NSRange(location: k + start, length: end - k), attributes: attributes(for: style, lineStyle: lineStyle, underline: underline, rtl: pieceRTL, hang: pieceHang)))
                    end = k; pieceRTL = rtl; pieceHang = hang
                }
                k = s
            }
            out.append(StyledRun(range: NSRange(location: lo + start, length: end - lo), attributes: attributes(for: style, lineStyle: lineStyle, underline: underline, rtl: pieceRTL, hang: pieceHang)))
        }
        var lineStyle = runs[n - 1].style            // style of the run that ends the line the current run's tail belongs to
        var lineUnderline = underlineRuns.contains(n - 1)
        var i = n - 1
        while i >= 0 {
            let run = runs[i]
            let r = run.range
            var lastBreakEnd = -1
            var k = r.location + r.length - 1 - start
            let lo = r.location - start
            while k >= lo {
                let c = charBuffer[k]
                if c == 0x0A || c == 0x0D { lastBreakEnd = k + 1 + start; break }
                k -= 1
            }
            if lastBreakEnd < 0 {
                emit(r, run.style, lineStyle, lineUnderline, singleLine: true)
            } else {
                let ul = underlineRuns.contains(i)
                if lastBreakEnd < NSMaxRange(r) {            // the tail after the last break belongs to the next line
                    emit(NSRange(location: lastBreakEnd, length: NSMaxRange(r) - lastBreakEnd), run.style, lineStyle, lineUnderline, singleLine: true)
                }
                emit(NSRange(location: r.location, length: lastBreakEnd - r.location), run.style, run.style, ul)
                lineStyle = run.style
                lineUnderline = ul
            }
            i -= 1
        }
        out.reverse()
        return out
    }

    // MARK: right-to-left detection

    /// Is there a right-to-left character anywhere in the buffer? (Hebrew, Arabic, Syriac, Thaana, NKo, ... and their presentation forms, RLM,
    /// the right-to-left supplementary scripts.) One pass; 0.5 ns per character.
    static func containsRightToLeft(_ buf: [unichar], count: Int) -> Bool {
        buf.withUnsafeBufferPointer { p in
            var i = 0
            while i < count {
                let c = p[i]
                if c >= 0x0590 && (c <= 0x08FF || c == 0x200F || (c >= 0xFB1D && c <= 0xFEFF) || c == 0xD802 || c == 0xD803 || c == 0xD83A || c == 0xD83B) { return true }
                i += 1
            }
            return false
        }
    }

    /// Bidi class of a UTF-16 unit for the "first strong character" rule: 0 = neutral (spaces, digits, punctuation, Markdown syntax, symbols, emoji,
    /// marks), 1 = strong left-to-right, 2 = strong right-to-left. Not a full UAX #9 table: the blocks that matter for deciding a line's direction.
    @inline(__always)
    static func strongDirection(_ c: unichar) -> Int {
        if c < 0x80 { let l = c | 0x20; return (l >= 0x61 && l <= 0x7A) ? 1 : 0 }
        if c < 0x0590 { return (c >= 0xC0 && c != 0xD7 && c != 0xF7) || c == 0xAA || c == 0xB5 || c == 0xBA ? 1 : 0 }
        if c <= 0x08FF {
            if (c >= 0x0660 && c <= 0x0669) || (c >= 0x06F0 && c <= 0x06F9) { return 0 }          // Arabic-Indic digits are weak
            if (c >= 0x0591 && c <= 0x05BD) || (c >= 0x064B && c <= 0x065F) || (c >= 0x0610 && c <= 0x061A) { return 0 }   // combining marks
            return 2
        }
        if c < 0x2000 { return 1 }
        if c <= 0x2BFF { return c == 0x200E ? 1 : (c == 0x200F ? 2 : 0) }             // general punctuation, symbols, arrows, dingbats
        if c >= 0x3000 && c <= 0x303F { return 0 }                                     // CJK punctuation
        if c >= 0xFB1D && c <= 0xFEFF { return (c >= 0xFE00 && c <= 0xFE6F) ? 0 : 2 }  // Hebrew / Arabic presentation forms (not variation selectors)
        if c >= 0xD800 && c <= 0xDBFF { return (c == 0xD802 || c == 0xD803 || c == 0xD83A || c == 0xD83B) ? 2 : (c == 0xD83C || c == 0xD83D ? 0 : 1) }
        if c >= 0xDC00 && c <= 0xDFFF { return 0 }
        return 1
    }

    /// `#`, closing `#`s, setext underline: a run of a heading line that is only a marker.
    @inline(__always)
    static func isHeadingMarker(_ s: MDStyle) -> Bool {
        s.headingLevel > 0 && (s.facets == [.marker] || s.facets == [.marker, .blockquote])
    }

    // MARK: attribute dictionaries

    /// Complete attribute dictionary for a run. `lineStyle` supplies the line-level facets (paragraph style, block decoration);
    /// by default the run's own style.
    /// `hang`: head indent of the line in half points (0: none), see HangingIndent.swift.
    func attributes(for style: MDStyle, lineStyle: MDStyle? = nil, underline: Bool = false, rtl: Bool = false, hang: Int = 0) -> TextAttributes {
        let line = LineKey(lineStyle ?? style, underline: underline, rtl: rtl, hang: hang)
        let key = UInt64(style.rawValue) | (UInt64(line.raw) << 32)
        if let a = cache[key] { return a }
        var d: TextAttributes = [:]
        let face = face(for: style)
        d[.font] = face.font
        if face.isSynthetic { face.addSyntheticAttributes(to: &d) }       // a family without italic / bold faces: slant / stroke the glyphs
        d[.foregroundColor] = color(for: style)
        d[.paragraphStyle] = paragraphStyle(line)
        if style.contains(.strikethrough) { d[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if (style.contains(.linkText) || style.contains(.autolink)) && !style.contains(.marker) {
            d[.underlineStyle] = NSUnderlineStyle.single.rawValue
            d[.underlineColor] = Palette.linkUnderline
        }
        if let mark = line.blockMark { d[.luftigBlock] = mark }
        if let panel = line.panelMark { d[.luftigPanel] = panel }
        if style.contains(.inlineCode) { d[.luftigInline] = NSNumber(value: 1) }
        cache[key] = d
        return d
    }

    // MARK: colours

    func color(for s: MDStyle) -> NSColor {
        if s.contains(.codeFence) { return s.contains(.codeLanguage) ? Palette.codeLanguage : Palette.marker }
        if s.contains(.marker) { return Palette.marker }
        if s.contains(.codeBlock) { return Palette.codeText }
        if s.contains(.inlineCode) { return Palette.inlineCode }
        if s.contains(.html) { return Palette.html }
        if s.contains(.escape) { return Palette.escape }
        if s.contains(.footnote) || s.contains(.referenceLabel) { return Palette.footnote }
        if s.contains(.linkDestination) { return Palette.linkDestination }
        if s.contains(.image) { return Palette.image }
        if s.contains(.linkText) || s.contains(.autolink) { return Palette.link }
        if s.contains(.taskMarker) { return s.contains(.taskChecked) ? Palette.accent : Palette.taskUnchecked }
        if s.contains(.listMarker) { return Palette.listMarker }
        if s.contains(.strikethrough) { return Palette.struck }
        let level = s.headingLevel
        if level > 0 { return level <= 4 ? Palette.heading : Palette.headingMuted }
        if s.contains(.tableDelimiter) { return Palette.marker }
        if s.contains(.frontMatter) { return Palette.frontMatter }
        if s.contains(.table) { return Palette.tableText }
        if s.contains(.blockquote) { return Palette.quoteText }
        return Palette.text
    }

    // MARK: fonts

    private struct FontKey: Hashable { var mono: Bool; var size: CGFloat; var weight: CGFloat; var italic: Bool }

    private func makeFace(mono: Bool, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> FontFace {
        let key = FontKey(mono: mono, size: size, weight: weight.rawValue, italic: italic)
        if let f = fontCache[key] { return f }
        let f = FontFactory.face(family: mono ? codeFamily : bodyFamily, mono: mono, size: size, weight: weight, italic: italic)
        fontCache[key] = f
        return f
    }

    func font(for s: MDStyle) -> NSFont { face(for: s).font }

    /// The font of a style plus what its family could not provide (see `FontFace`).
    func face(for s: MDStyle) -> FontFace {
        let level = s.headingLevel
        // code: monospaced, never bold/italic (the language label is semibold)
        if s.contains(.codeBlock) || s.contains(.codeFence) {
            return makeFace(mono: true, size: monoSize, weight: s.contains(.codeLanguage) ? .semibold : .regular, italic: false)
        }
        if s.contains(.inlineCode) {
            // bold / italic around a code span (`**`x`**`) keep their meaning: semibold (the span's width does not change) / slanted
            return makeFace(mono: true, size: level > 0 ? Theme.codeSize(baseSize: headingSize(level), scale: settings.codeScale) : monoSize,
                            weight: (level > 0 || s.contains(.bold)) ? .semibold : .regular, italic: s.contains(.italic))
        }
        // tables and front matter: monospaced so that pipes and keys line up
        if s.contains(.table) || s.contains(.frontMatter) {
            let heavy = (s.contains(.tableHeader) || s.contains(.bold)) && !s.contains(.tableDelimiter)
            return makeFace(mono: true, size: monoSize, weight: heavy ? .bold : .regular, italic: false)
        }
        if level > 0 {
            // the `#` / `===` markers of a heading itself stay at body size and weight: dim and light, not a second headline
            if s.facets == [.marker] || s.facets == [.marker, .blockquote] {
                return makeFace(mono: false, size: baseSize, weight: .regular, italic: false)
            }
            return makeFace(mono: false, size: headingSize(level), weight: level <= 2 ? .bold : .semibold, italic: s.contains(.italic))
        }
        var weight: NSFont.Weight = .regular
        if s.contains(.bold) { weight = .bold }
        else if s.contains(.listMarker) || s.contains(.taskChecked) { weight = .semibold }
        return makeFace(mono: false, size: baseSize, weight: weight, italic: s.contains(.italic))
    }

    // MARK: paragraph styles and block marks

    /// The line-level facets of a style: the only things a paragraph style / block decoration may depend on.
    struct LineKey {
        let raw: UInt32
        /// `underline`: the line is the setext underline of a heading (see styledRuns): it is a plain dim line, not a heading line.
        /// `rtl`: the line's first strong character is right-to-left (Arabic, Hebrew, ...): the paragraph is right-aligned. Only ever set for
        /// plain lines (no code / table / front matter / rule / quote: those are drawn with a bar or a band at the left).
        /// `hang`: the line hangs (list item, indented continuation): the x position where its text starts, in half points, bits 10...21. Plain lines only.
        init(_ s: MDStyle, underline: Bool = false, rtl: Bool = false, hang: Int = 0) {
            var k = UInt32(underline ? 0 : s.headingLevel) | (UInt32(s.quoteDepth) << 3) | (underline ? 1 << 8 : 0)
            let block: UInt32
            if s.contains(.codeBlock) || s.contains(.codeFence) { block = 1 }
            else if s.contains(.horizontalRule) { block = 2 }
            else if s.contains(.table) { block = s.contains(.tableHeader) ? 5 : (s.contains(.tableDelimiter) ? 6 : 3) }
            else if s.contains(.frontMatter) { block = 4 }
            else { block = 0 }
            k |= block << 5
            if rtl && block == 0 && s.quoteDepth == 0 { k |= 1 << 9 }
            if hang > 0 && block == 0 && !underline && s.headingLevel == 0 && !rtl { k |= UInt32(min(hang, 4095)) << 10 }
            raw = k
        }
        var heading: Int { Int(raw & 7) }
        var quote: Int { Int((raw >> 3) & 3) }
        var block: Int { Int((raw >> 5) & 7) }
        var isRTL: Bool { raw & (1 << 9) != 0 }
        /// Absolute head indent of a hanging line in half points; 0: the line does not hang.
        var hang: Int { Int((raw >> 10) & 0xFFF) }
        /// Lines with a band behind them whose text is inset by `DecorationMetrics.codeIndent` (code, tables, front matter) - when not in a quote.
        var hasPanel: Bool { block == 1 || block >= 3 }
        var blockMark: NSNumber? {
            switch block {
            case 1: return BlockMark.encode(.code, depth: quote)        // code inside a quote keeps the quote's bar(s)
            case 2: return BlockMark.encode(.rule, depth: quote)       // a rule inside a quote belongs to the quote (bar and band run through it)
            default: return quote > 0 ? BlockMark.encode(.quote, depth: quote) : nil
            }
        }
        /// `.luftigPanel`: tables and front matter (only outside quotes). Code / rule / quote use `.luftigBlock`.
        var panelMark: NSNumber? {
            guard quote == 0 else { return nil }
            switch block {
            case 5: return NSNumber(value: PanelKind.tableHeader.rawValue)
            case 6: return NSNumber(value: PanelKind.tableDelimiter.rawValue)
            case 3: return NSNumber(value: PanelKind.tableBody.rawValue)
            case 4: return NSNumber(value: PanelKind.frontMatter.rawValue)
            default: return nil
            }
        }
    }

    func paragraphStyle(_ line: LineKey) -> NSParagraphStyle {
        if let p = paragraphCache[line.raw] { return p }
        let p = NSMutableParagraphStyle()
        p.alignment = .natural
        p.baseWritingDirection = line.isRTL ? .rightToLeft : .leftToRight   // explicit: bars, bands and markers are on the left; see LineKey.rtl
        p.lineBreakMode = .byWordWrapping
        let level = line.heading
        let h = lineHeight(headingLevel: level)
        p.minimumLineHeight = h
        p.maximumLineHeight = h
        if level > 0 { p.paragraphSpacingBefore = spacingBefore(headingLevel: level) }
        var indent: CGFloat = 0
        if line.quote > 0 { indent = DecorationMetrics.quoteIndent(depth: line.quote) }
        else if line.hasPanel { indent = DecorationMetrics.codeIndent }
        if line.hasPanel {
            // AppKit's default tab stop is 28 pt (3.2 characters of the code font): a tab-indented code block was misaligned with its space-indented
            // neighbours. A tab is 4 columns in Markdown.
            p.tabStops = []
            p.defaultTabInterval = monoAdvance * 4
        }
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        if line.hang > 0 {
            // a list item / indented continuation line: wrapped lines start where the text of the line starts (HangingIndent.swift).
            // The tab grid is spelled out: the width of a tab in the prefix has to be known (AppKit's default is the same 28 pt grid).
            p.headIndent = CGFloat(line.hang) / 2
            p.tabStops = []
            p.defaultTabInterval = Theme.hangTabInterval
        }
        paragraphCache[line.raw] = p
        return p
    }
}
