import Cocoa

// `TermIMS diagnose` runs one headless resolution and prints it as JSON, then
// exits. Kept ahead of NSApplication setup so the menu bar app never appears.
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "diagnose" {
    // --title / --cwd replay an observed tab's signals against the live
    // process table, so a tab can be checked without focusing it.
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    exit(Diagnostics.run(bundleID: value("--bid"), title: value("--title"), cwd: value("--cwd")))
}
// `herdr-probe [cwd]` resolves which herdr session a tab with that cwd maps
// to. Deliberately free of Accessibility calls so it runs from a plain build.
if args.first == "herdr-probe" {
    exit(Diagnostics.herdrProbe(tabCwd: args.count > 1 ? args[1] : nil))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
