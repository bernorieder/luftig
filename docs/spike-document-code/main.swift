// main.swift - entry point.
//
//   Scribe                       normal app
//   Scribe --selftest <name|all> headless scenarios (activation policy .prohibited, no window ever ordered front),
//                                exit status 0 = all passed, 1 = a check failed, 2 = timeout/crash of the runner

import AppKit

let launchArguments = CommandLine.arguments

if launchArguments.contains(where: { $0 == "--selftest" || $0.hasPrefix("--selftest=") }) {
    // Without this AppKit treats a loose argument ("all") as a file to open and blocks on an (invisible) error alert.
    UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    SelfTest.run(arguments: launchArguments)          // never returns
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
