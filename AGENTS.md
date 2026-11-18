# TermIMS

A macOS menu bar app. Swift Package Manager layout, no Xcode project.

```
Sources/TermIMSCore/*.swift   # pure logic — no AppKit, no syscalls, unit-tested
Sources/TermIMS/*.swift       # the app: AppKit, Accessibility, sysctl, IPC
Tests/TermIMSCoreTests/       # swift-testing suites over TermIMSCore
Scripts/package-app.sh        # wraps the SPM binary into TermIMS.app
Resources/AppIcon.png         # source for the generated AppIcon.icns
Info.plist                    # bundle metadata, copied into the .app
Package.swift                 # SPM manifest (core + executable + tests)
Makefile                      # thin shell over package-app.sh + DMG packaging
```

Build/install/run/dist all go through `make` (which calls `swift build -c release` under the hood). Adding a new file just means dropping a `.swift` into the right target — SPM picks it up automatically.

## Testing

```sh
swift test
```

`TermIMSCore` holds the logic that can be decided from data alone — process
naming, title/cwd heuristics — as pure functions. That is what the test suite
covers, and it needs neither Accessibility permission nor a live terminal, so
it also runs in CI.

Anything that reads the world (Accessibility, `sysctl`, AppleScript, terminal
CLIs, the herdr socket) stays in the `TermIMS` target. When adding logic,
prefer putting the decision in `TermIMSCore` and leaving only the I/O in the
app — that is what keeps it testable.

## Release

When the user asks to publish a release, follow these steps:

1. **Update version** in `Info.plist` — bump both `CFBundleVersion` and `CFBundleShortVersionString` (use x.y.z format).
2. **Commit, tag, push** — version bump should be its own commit:
   ```sh
   git add Info.plist
   git commit -m "chore: Bump version to x.y.z"
   git tag vx.y.z
   git push origin main --tags
   ```

That's it. The `release` workflow at `.github/workflows/release.yml` picks up the `v*` tag, builds `dist/TermIMS.dmg` on a macOS runner via `make dist`, and creates a GitHub Release with auto-generated notes (from PRs merged since the previous tag). No local `make dist` / `gh release create` needed.

Ask the user for the version number if not provided. Release notes are derived automatically — only ask if they want to customise.
