import Foundation

// ColorSchemesMath.swift - the colour maths behind the colour schemes: WCAG 2 contrast, OKLab / OKLCH, and the deterministic
// "make this colour legible" step (`ColorMath.fit`). Pure Foundation, no AppKit, main thread or not.
//
// Colours are `RGB` = sRGB components 0...1 (SIMD3<Double>), always handled in the sRGB encoding the screen shows; `quantize` snaps a
// colour to the 8 bits it will be stored with, and every contrast test in this file uses the QUANTIZED colour (what is drawn).

typealias RGB = SIMD3<Double>

enum ColorMath {
    // MARK: sRGB <-> linear, WCAG luminance

    /// sRGB transfer function (exact), used by the OKLab conversions.
    static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// WCAG 2 relative luminance. Same formula (same 0.03928 threshold) as the self-test's `Contrast.luminance`, so the numbers agree to the digit.
    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
    }
    /// WCAG 2 contrast ratio of two OPAQUE colours (1 ... 21).
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
    /// `top` at `alpha` composited over the opaque `base`, in the sRGB encoding (what CoreGraphics and the self-test's `Contrast.over` do).
    static func over(_ top: RGB, _ alpha: Double, _ base: RGB) -> RGB { top * alpha + base * (1 - alpha) }

    static func clamp01(_ c: RGB) -> RGB { RGB(min(1, max(0, c.x)), min(1, max(0, c.y)), min(1, max(0, c.z))) }
    /// Snaps to the 8 bit per channel value the colour is stored (and drawn) with.
    static func quantize(_ c: RGB) -> RGB { let k = clamp01(c); return RGB((k.x * 255).rounded() / 255, (k.y * 255).rounded() / 255, (k.z * 255).rounded() / 255) }

    static func rgb(hex: UInt32) -> RGB { RGB(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255) }
    static func hex(_ c: RGB) -> String {
        let q = quantize(c)
        return String(format: "#%02x%02x%02x", Int((q.x * 255).rounded()), Int((q.y * 255).rounded()), Int((q.z * 255).rounded()))
    }

    // MARK: OKLab / OKLCH (Bjorn Ottosson, 2020: https://bottosson.github.io/posts/oklab/)

    static func oklab(_ c: RGB) -> RGB {
        let r = linear(c.x), g = linear(c.y), b = linear(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return RGB(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                   1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                   0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Linear-light RGB of an OKLab colour; components can lie outside 0...1 (outside the sRGB gamut).
    private static func linearRGB(_ lab: RGB) -> RGB {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return RGB(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                   -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                   -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }
    private static func inGamut(_ lin: RGB) -> Bool {
        let e = 0.0005
        return lin.x >= -e && lin.x <= 1 + e && lin.y >= -e && lin.y <= 1 + e && lin.z >= -e && lin.z <= 1 + e
    }

    /// (lightness 0...1, chroma, hue in radians)
    static func oklch(_ c: RGB) -> (L: Double, C: Double, h: Double) {
        let lab = oklab(c)
        return (lab.x, (lab.y * lab.y + lab.z * lab.z).squareRoot(), atan2(lab.z, lab.y))
    }

    /// The sRGB colour of an OKLCH triple; when it lies outside the gamut the chroma is reduced (lightness and hue are kept).
    static func rgb(L: Double, C: Double, h: Double) -> RGB {
        let L = min(1, max(0, L))
        func lin(_ chroma: Double) -> RGB { linearRGB(RGB(L, chroma * cos(h), chroma * sin(h))) }
        var chroma = C
        if !inGamut(lin(chroma)) {
            var lo = 0.0, hi = C
            for _ in 0..<24 { let mid = (lo + hi) / 2; if inGamut(lin(mid)) { lo = mid } else { hi = mid } }
            chroma = lo
        }
        let l = lin(chroma)
        return clamp01(RGB(encode(max(0, l.x)), encode(max(0, l.y)), encode(max(0, l.z))))
    }

    /// Mix in OKLab (perceptually even): `t` = 0 is `a`, 1 is `b`.
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let p = oklab(a), q = oklab(b)
        let m = p * (1 - t) + q * t
        return rgb(L: m.x, C: (m.y * m.y + m.z * m.z).squareRoot(), h: atan2(m.z, m.y))
    }

    // MARK: making a colour legible

    /// One requirement of a colour: at least `min`:1 against the opaque surface.
    struct Need { let surface: RGB; let min: Double }

    static func meets(_ c: RGB, _ needs: [Need]) -> Bool { needs.allSatisfy { ratio(c, $0.surface) >= $0.min } }
    /// Worst margin (ratio - required) over all needs.
    static func margin(_ c: RGB, _ needs: [Need]) -> Double { needs.map { ratio(c, $0.surface) - $0.min }.min() ?? 0 }

    /// THE adjustment step of the colour schemes. Returns `c` (quantized) when it already meets every need; otherwise the colour with the SAME HUE
    /// and CHROMA (gamut-mapped) whose OKLCH lightness has moved the LEAST towards white (`towardsLight`, dark schemes) or black (light schemes) for
    /// all needs to hold. Binary search on the lightness (24 steps) between the original and the extreme, on the quantized colour; deterministic.
    /// If even the extreme (white / black) fails, the extreme is returned and the caller's test reports it.
    static func fit(_ c: RGB, needs: [Need], towardsLight: Bool) -> RGB {
        let q = quantize(c)
        if meets(q, needs) { return q }
        let (L0, C0, h) = oklch(c)
        let target = towardsLight ? 1.0 : 0.0
        func candidate(_ t: Double) -> RGB { quantize(rgb(L: L0 + (target - L0) * t, C: C0, h: h)) }
        if !meets(candidate(1), needs) { return candidate(1) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if meets(candidate(mid), needs) { hi = mid } else { lo = mid }
        }
        return candidate(hi)
    }

    /// OKLCH lightness change from `a` to `b`, in points of 100 (positive: lighter).
    static func deltaL(from a: RGB, to b: RGB) -> Double { (oklab(b).x - oklab(a).x) * 100 }
}
