// main.swift - entry point.
//
//   luftig                       the app
//
// A variant built with LUFTIG_SELFTEST (Scripts/build-app.sh --selftest -> build/luftig-SelfTest.app) additionally understands
//   luftig-SelfTest --selftest <name|all>   headless scenarios, see SelfTest/. The shipping binary contains none of that.

import AppKit

#if LUFTIG_SELFTEST
LaunchProbe.mainEntered = Date().timeIntervalSince1970
if SelfTestHooks.handleLaunchArguments(CommandLine.arguments) { /* never returns */ }
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
