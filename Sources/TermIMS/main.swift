import Cocoa

// `TermIMS diagnose` runs one headless resolution and prints it as JSON, then
// exits. Kept ahead of NSApplication setup so the menu bar app never appears.
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("diagnose") {
    exit(Diagnostics.run())
}
// `herdr-probe [cwd]` resolves which herdr session a tab with that cwd maps
// to. Deliberately free of Accessibility calls so it runs from a plain build.
if let i = args.firstIndex(of: "herdr-probe") {
    exit(Diagnostics.herdrProbe(tabCwd: i + 1 < args.count ? args[i + 1] : nil))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
