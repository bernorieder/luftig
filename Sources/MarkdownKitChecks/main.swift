import Foundation
import MarkdownKit

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    mdkit-checks            run all fast checks (expectations + invariants + short fuzz)
    mdkit-checks --bench    benchmarks (1 MB and 10 MB synthetic corpora)
    mdkit-checks --fuzz <iterations> <seed>   differential fuzzing (iterations = random edits)
    mdkit-checks --conformance   CommonMark / GFM conformance suite: table + documented deviations
    mdkit-checks --corpus <edits per file> <seed> [oddities] [review=N] [oracle] [real] [inline]   real *.md files (read only)
    mdkit-checks --unicode-class   flanking class of every scalar vs its general category
    mdkit-checks --stress [bytes] [name]   pathological inputs   --ref-fuzz / --oracle-fuzz / --oracle-fuzz2 / --block-fuzz <n> <seed>   differentials
    mdkit-checks --mdit-export <docs.jsonl> <corpus|corpusmut|gen|genbig|tiny|block|inline|inline2|lists|fenceshtml|uni> [count] [seed]   (markdown-it-py oracle,
    mdkit-checks --mdit-compare <docs.jsonl> <oracle.jsonl> [show=N] [samples=N] [shortest=N] [x2] [real] [norefs] [nourl] [notask] [dev] [doc=<suffix>]   see Scripts/mdit_oracle.py)
    mdkit-checks --show '<text with \\n escapes>'   print the run notation of a string
    mdkit-checks --showfile <path>
    """)
}

if args.first == "--show" {
    for a in args.dropFirst() { print(renderAll(unescape(a))) }
    exit(0)
} else if args.first == "--showfile" {
    if let p = args.dropFirst().first, let s = try? String(contentsOfFile: p, encoding: .utf8) { print(renderAll(s)) }
    exit(0)
} else if args.first == "--bench" {
    runBenchmarks()
    exit(0)
} else if args.first == "--sweep" {
    runStrideSweep()
    exit(0)
} else if args.first == "--fuzz" {
    let iterations = args.count > 1 ? Int(args[1]) ?? 50_000 : 50_000
    let seed = args.count > 2 ? UInt64(args[2]) ?? 1 : 1
    let ok = runFuzz(iterations: iterations, seed: seed, verbose: true)
    exit(ok ? 0 : 1)
} else if args.first == "--corpus" {
    // mdkit-checks --corpus <edits per file> <seed> [oracle] [oddities] [review=60] [limit=N] [dups] [fixtures] [dump=<class>]
    let rest = Array(args.dropFirst())
    let edits = rest.count > 0 ? Int(rest[0]) ?? 30 : 30
    let seed = rest.count > 1 ? UInt64(rest[1]) ?? 1 : 1
    let flags = Array(rest.dropFirst(2))
    corpusFlags = flags
    func opt(_ k: String, _ d: Int) -> Int { flags.first(where: { $0.hasPrefix(k + "=") }).flatMap { Int($0.dropFirst(k.count + 1)) } ?? d }
    runRealCorpus(editsPerFile: edits, seed: seed, doOracle: flags.contains("oracle"), doOddities: flags.contains("oddities"), review: opt("review", 60), limit: opt("limit", Int.max))
    exit(0)
} else if args.first == "--oracle-file" {
    // mdkit-checks --oracle-file <path> [fromLine toLine] [blockonly]
    let r = Array(args.dropFirst())
    let nums = r.dropFirst().compactMap { Int($0) }
    runOracleFileCommand(path: r.first ?? "", from: nums.count > 1 ? nums[0] : 0, to: nums.count > 1 ? nums[1] : 0, blockOnly: r.contains("blockonly"))
    exit(0)
} else if args.first == "--stress" {
    runStress(bytes: args.count > 1 ? Int(args[1]) ?? 1_000_000 : 1_000_000, filter: args.count > 2 ? args[2] : nil)   // [bytes] [case-name filter]
    exit(0)
} else if args.first == "--block-fuzz" {
    runBlockOracleFuzzCommand(count: args.count > 1 ? Int(args[1]) ?? 5000 : 5000, seed: args.count > 2 ? UInt64(args[2]) ?? 1 : 1, show: args.count > 3 ? Int(args[3]) ?? 60 : 60)
    exit(0)
} else if args.first == "--ref-fuzz" {
    // emphasis / code span / escape differential against a naive spec-literal reference implementation
    runRefFuzzCommand(count: args.count > 1 ? Int(args[1]) ?? 100_000 : 100_000, seed: args.count > 2 ? UInt64(args[2]) ?? 1 : 1, show: args.count > 3 ? Int(args[3]) ?? 30 : 30)
    exit(0)
} else if args.first == "--oracle-fuzz" {
    // inline differential fuzz against cmark-gfm (Foundation's AttributedString markdown parser)
    runOracleFuzzCommand(count: args.count > 1 ? Int(args[1]) ?? 20_000 : 20_000, seed: args.count > 2 ? UInt64(args[2]) ?? 1 : 1, show: args.count > 3 ? Int(args[3]) ?? 40 : 40)
    exit(0)
} else if args.first == "--unicode-class" {
    runUnicodeClassCheck(upTo: args.count > 1 ? UInt32(args[1]) ?? 0x30000 : 0x30000, show: args.count > 2 ? Int(args[2]) ?? 80 : 80)
    exit(0)
} else if args.first == "--oracle-fuzz2" {
    runOracleFuzz2Command(count: args.count > 1 ? Int(args[1]) ?? 20_000 : 20_000, seed: args.count > 2 ? UInt64(args[2]) ?? 1 : 1, show: args.count > 3 ? Int(args[3]) ?? 40 : 40)
    exit(0)
} else if args.first == "--mdit-export" {
    // mdkit-checks --mdit-export <docs.jsonl> <corpus|gen|genbig|block|inline> [count] [seed]   (second oracle, see MditOracle.swift)
    let r = Array(args.dropFirst())
    runMditExport(path: r.count > 0 ? r[0] : "", kind: r.count > 1 ? r[1] : "corpus", count: r.count > 2 ? Int(r[2]) ?? 1000 : 1000, seed: r.count > 3 ? UInt64(r[3]) ?? 1 : 1)
    exit(0)
} else if args.first == "--mdit-compare" {
    let r = Array(args.dropFirst())
    runMditCompare(docsPath: r.count > 0 ? r[0] : "", oraclePath: r.count > 1 ? r[1] : "", flags: Array(r.dropFirst(2)))
    exit(0)
} else if args.first == "--conformance" {
    // Independent CommonMark / GFM conformance suite (SpecInline / SpecBlocks / SpecReal): full table + documented deviations.
    runSpecConformance()
    printConformanceTable(verbose: true)
    exit(Harness.failures == 0 ? 0 : 1)
} else if args.first == "--help" || args.first == "-h" {
    usage()
    exit(0)
} else {
    let t0 = Date()
    runExpectationTests()
    runSpecConformance()
    printConformanceTable(verbose: false)
    runReviewRegressions()
    runInvariantTests()
    runIncrementalTests()
    runLargeConsistencyTests()
    runAPITests()
    Harness.group("fuzz (short)")
    let ok = runFuzz(iterations: 6_000, seed: 12345, verbose: false)
    Harness.expect(ok, "short differential fuzz")
    print(String(format: "elapsed %.2fs", Date().timeIntervalSince(t0)))
    exit(Harness.summary())
}
