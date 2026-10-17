import AppKit

enum Engine: String, CaseIterable {
    case tk1c = "TK1-contig"
    case tk1n = "TK1-noncontig"
    case tk2 = "TK2"

    var isTK2: Bool { self == .tk2 }
    var short: String { rawValue }

    static func parse(_ s: String) -> [Engine] {
        if s.contains(",") { return s.split(separator: ",").flatMap { parse(String($0)) } }
        switch s {
        case "all": return Engine.allCases
        case "tk1": return [.tk1c, .tk1n]
        case "tk1c": return [.tk1c]
        case "tk1n": return [.tk1n]
        case "tk2": return [.tk2]
        default: return Engine.allCases
        }
    }
}

enum SetTextMode: String, CaseIterable {
    case stringProperty = "textView.string="
    case replaceCharacters = "storage.replaceCharacters"
    case setAttributedString = "storage.setAttributedString"
}

/// Text view subclass used by the harness: records invalidated rects so we can verify incremental redraw coverage,
/// and counts draw passes.
final class SpikeTextView: ScribeEditorTextView {
    var recordInvalidations = false
    var invalidRects: [NSRect] = []
    var drawCount = 0
    var drawnRects: [NSRect] = []
    var recordDraws = false

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        if recordInvalidations { invalidRects.append(widenedForDecorations(invalidRect)) }
        super.setNeedsDisplay(invalidRect)
    }
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        if recordInvalidations { invalidRects.append(widenedForDecorations(rect)) }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }
    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        if recordDraws { drawnRects.append(dirtyRect) }
        super.draw(dirtyRect)
    }
}

struct HarnessOptions {
    var width: CGFloat = 900
    var height: CGFloat = 700
    var decorate = true
    var isRichText = false
    var allowsUndo = true
    var appearance: NSAppearance.Name? = nil
    var tk1BackgroundLayout = true
    var inset = NSSize(width: 24, height: 16)
    var lineFragmentPadding: CGFloat = 0
    var configure: ((SpikeTextView) -> Void)? = nil
    var widenInvalidation = false
}

final class Harness: NSObject {
    let engine: Engine
    let window: NSWindow
    let scroll: NSScrollView
    let textView: SpikeTextView
    let opts: HarnessOptions
    var layoutManager1: NSLayoutManager?       // TK1 only
    var textLayoutManager2: NSTextLayoutManager? // TK2 only
    var contentStorage2: NSTextContentStorage?
    var styledSet = IndexSet()
    var createdFragments: [Int] = []   // char offsets of paragraphs for which TK2 created a fragment (debug)

    var storage: NSTextStorage { textView.textStorage! }
    var container: NSTextContainer { textView.textContainer! }
    var clip: NSClipView { scroll.contentView }
    var visibleRect: NSRect { clip.documentVisibleRect }

    init(engine: Engine, options: HarnessOptions = HarnessOptions()) {
        self.engine = engine
        self.opts = options

        let frame = NSRect(x: 0, y: 0, width: options.width, height: options.height)
        let tv: SpikeTextView
        if engine.isTK2 {
            // TextKit 2: let AppKit build the stack. NEVER touch tv.layoutManager (that silently downgrades to TK1).
            let cs = NSTextContentStorage()
            let tlm = NSTextLayoutManager()
            let tc = NSTextContainer(size: NSSize(width: options.width, height: CGFloat.greatestFiniteMagnitude))
            tlm.textContainer = tc
            cs.addTextLayoutManager(tlm)
            tv = SpikeTextView(frame: frame, textContainer: tc)
            textLayoutManager2 = tlm
            contentStorage2 = cs
        } else {
            let ts = NSTextStorage()
            let lm: NSLayoutManager = options.decorate ? ScribeLayoutManager() : NSLayoutManager()
            let tc = NSTextContainer(size: NSSize(width: options.width, height: CGFloat.greatestFiniteMagnitude))
            lm.addTextContainer(tc)
            ts.addLayoutManager(lm)
            tv = SpikeTextView(frame: frame, textContainer: tc)
            lm.allowsNonContiguousLayout = (engine == .tk1n)
            lm.backgroundLayoutEnabled = options.tk1BackgroundLayout
            layoutManager1 = lm
        }
        textView = tv

        scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        tv.minSize = NSSize(width: 0, height: options.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.lineFragmentPadding = options.lineFragmentPadding
        tv.textContainerInset = options.inset
        tv.isRichText = options.isRichText
        tv.allowsUndo = options.allowsUndo
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.widenInvalidationForDecorations = options.widenInvalidation
        options.configure?(tv)

        scroll.documentView = tv

        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let an = options.appearance { window.appearance = NSAppearance(named: an) }
        window.contentView = scroll
        window.orderBack(nil)   // no key / main / activation
        super.init()

        if let tlm = textLayoutManager2 {
            tlm.delegate = self
        }
    }

    deinit { window.close() }

    // MARK: text installation

    func installBaseDefaults(_ theme: Theme) {
        // The "initial attributes the view needs just to display": default font + colour for the typing attributes.
        textView.font = theme.bodyFont
        textView.textColor = Palette.text
    }

    /// Hands the text to the view. Returns the time of the hand-over itself.
    @discardableResult
    func setText(_ text: String, mode: SetTextMode, baseAttrs: [NSAttributedString.Key: Any]?) -> Double {
        switch mode {
        case .stringProperty:
            return ms { textView.string = text }
        case .replaceCharacters:
            return ms { storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text) }
        case .setAttributedString:
            let attr = NSAttributedString(string: text, attributes: baseAttrs)
            return ms { storage.setAttributedString(attr) }
        }
    }

    // MARK: layout / display

    /// Lay out only what is visible (plus whatever the engine needs to find the document height).
    func layoutVisible() {
        let rect = visibleRect
        if let lm = layoutManager1 {
            lm.ensureLayout(forBoundingRect: rect, in: container)
        } else if let tlm = textLayoutManager2 {
            tlm.textViewportLayoutController.layoutViewport()
        }
        textView.layoutSubtreeIfNeeded()
    }

    lazy var snapshotRep: NSBitmapImageRep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!

    /// Draw the scroll view (visible part) into a bitmap. Excludes bitmap allocation.
    @discardableResult
    func drawVisible() -> Double {
        let rep = snapshotRep
        return ms { scroll.cacheDisplay(in: scroll.bounds, to: rep) }
    }

    func savePNG(_ path: String) {
        let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
        scroll.cacheDisplay(in: scroll.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: scrolling helpers

    func scrollTo(y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(clip)
    }

    var docHeight: CGFloat { textView.frame.height }

    /// Spin the main run loop for `seconds` (lets background layout, timers etc. run). Returns the worst main-thread stall in ms.
    /// A background thread samples "time since the main thread last ticked" every 0.5 ms (the main thread ticks from a 1 ms timer),
    /// so a stall is measured at its full length even if it straddles the end of the spin.
    @discardableResult
    func spin(_ seconds: Double, measureStalls: Bool = false) -> (maxGapMs: Double, ticks: Int) {
        let shared = UnsafeMutablePointer<Double>.allocate(capacity: 3)   // [lastTick, maxGap, stop]
        shared[0] = nowMs(); shared[1] = 0; shared[2] = 0
        var ticks = 0
        let monitor = Thread {
            while shared[2] == 0 {
                let gap = nowMs() - shared[0]
                if gap > shared[1] { shared[1] = gap }
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        monitor.start()
        let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
            shared[0] = nowMs()
            ticks += 1
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
        let end = nowMs() + seconds * 1000
        while nowMs() < end {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        timer.invalidate()
        let finalGap = nowMs() - shared[0]      // time since the last tick when the loop ended
        shared[2] = 1
        let result = max(shared[1], finalGap > 50 ? finalGap : 0)
        Thread.sleep(forTimeInterval: 0.002)
        shared.deallocate()
        return (result, ticks)
    }
}

// MARK: - TK2 delegate (fragment factory)

extension Harness: NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let cm = textLayoutManager.textContentManager, let er = textElement.elementRange {
            createdFragments.append(cm.offset(from: cm.documentRange.location, to: er.location))
        }
        if opts.decorate, textElement is NSTextParagraph {
            return ScribeLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
