import Foundation
import MarkdownKit

/// Tiny assertion harness (XCTest / swift-testing are unavailable on this machine).
final class Harness {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var failureLog: [String] = []
    nonisolated(unsafe) static var currentGroup = ""

    static func group(_ name: String) { currentGroup = name }

    static func fail(_ message: String) {
        failures += 1
        let line = "FAIL [\(currentGroup)] \(message)"
        failureLog.append(line)
        print(line)
    }

    static func expect(_ cond: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !cond { fail(message()) }
    }

    static func expectEqual(_ actual: String, _ expected: String, _ label: @autoclosure () -> String) {
        checks += 1
        if actual != expected {
            fail("\(label())\n      expected: \(expected)\n      actual:   \(actual)")
        }
    }

    static func summary() -> Int32 {
        print("")
        if failures == 0 {
            print("OK: \(checks) checks passed")
            return 0
        }
        print("FAILED: \(failures) of \(checks) checks failed")
        return 1
    }
}

// MARK: - Run notation

func visible(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\n": out += "⏎"
        case "\r": out += "␍"
        case "\t": out += "⇥"
        default: out.unicodeScalars.append(ch)
        }
    }
    return out
}

/// Slice of an NSString by UTF-16 range, tolerating split surrogates (shown as U+FFFD).
func slice(_ t: NSString, _ r: NSRange) -> String { t.substring(with: r) }

/// Human-readable run notation, e.g. "[h1·marker:# ][h1:Hello ][h1·bold:world]".
func render(_ text: NSString, _ runs: [MDRun]) -> String {
    var out = ""
    for r in runs {
        out += "[\(r.style):\(visible(slice(text, r.range)))]"
    }
    return out
}

func renderAll(_ s: String, styler: MarkdownStyler = MarkdownStyler()) -> String {
    let t = NSString(string: s)
    return render(t, styler.lexAll(t))
}

/// Parse "\n" style escapes used on the command line.
func unescape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\r", with: "\r")
        .replacingOccurrences(of: "\\t", with: "\t")
}
