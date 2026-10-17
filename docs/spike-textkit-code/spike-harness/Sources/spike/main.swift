import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.finishLaunching()

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let rest = Array(args.dropFirst())

func arg(_ name: String, default d: String) -> String {
    if let i = rest.firstIndex(of: "--" + name), i + 1 < rest.count { return rest[i + 1] }
    return d
}
func flag(_ name: String) -> Bool { rest.contains("--" + name) }

switch command {
case "smoke": runSmoke(rest)
case "open": runOpen(rest)
case "attrs": runAttrs(rest)
case "typing": runTyping(rest)
case "scroll": runScroll(rest)
case "truth": runTruth(rest)
case "probe": runProbe(rest)
case "defaults": runProbeDefaults(rest)
case "fileload": runProbeFileLoad(rest)
case "clip": runProbeClip(rest)
case "dropin": runDropIn(rest)
case "marked": runProbeMarked(rest)
case "config": runConfig(rest)
case "sanity": runSanity(rest)
case "settle": runProbeSettle(rest)
case "draw": runDraw(rest)
case "invalidate": runInvalidate(rest)
default:
    log("usage: spike <smoke|open|attrs|typing|scroll|draw|config|sanity> [--engine all|tk1c|tk1n|tk2] [--corpus 1m] [--runs 7]")
}
