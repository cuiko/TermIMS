# TermIMS

A lightweight macOS menu bar app that automatically switches input methods based on the active application — and for terminal apps, based on the running process or tab title.

## Features

- **Per-app input method rules** — Assign a specific input method to any application. When you switch to that app, the input method changes automatically.
- **Terminal sub-rules** — For terminal emulators (Ghostty, Terminal.app, iTerm2, kitty, wezterm, Warp, Alacritty), define additional rules that match by:
  - **Process name** — e.g., switch to Chinese when `claude` or `nvim` is running in the active tab
  - **Tab title** — e.g., match a keyword in the terminal window title
- **Global default** — Set a fallback input method for apps without specific rules.
- **Terminal default** — Set a separate default for terminal apps when no sub-rule matches.
- **Switch indicator** — A brief overlay shows the current input method on switch. Configurable position (center, corners) and can be disabled.
- **Launch at Login** — Optional LaunchAgent-based auto-start.
- **Hide menu bar icon** — Run silently without a status bar icon. Reopen the app to access Settings.
- **Permission handling** — Guides you through granting Accessibility permission on first launch, and detects if permission is revoked.

## How It Works

TermIMS uses the macOS Accessibility API to monitor application focus changes and terminal tab switches. For terminal process matching, it reads the kernel process table via `sysctl` and correlates the active tab using `AXDocument` (working directory) and `proc_pidinfo` — no shell plugins or terminal extensions required.

## Requirements

- macOS 13.0+
- Accessibility permission (System Settings → Privacy & Security → Accessibility)

## Build

The project is a single Swift file compiled directly with `swiftc`. No Xcode project needed.

```sh
# Build and install to /Applications
make install

# Build, install, and launch
make restart

# Remove
make clean
```

## Usage

1. Run `make restart` to build and launch.
2. Grant Accessibility permission when prompted.
3. Click the keyboard icon in the menu bar → **Settings**.
4. **General** tab — Set the global default input method, indicator preferences.
5. **App Rules** tab — Click **+** to add an app and assign its input method.
6. **Terminal Rules** tab — Set the terminal default, then add rules to match by process name or tab title.

### Terminal Rules Example

| Match       | Pattern    | Input Method |
|-------------|------------|--------------|
| Process Name | `claude`  | Chinese      |
| Process Name | `nvim`    | ABC          |
| Tab Title    | `ssh`     | ABC          |

When you switch to a Ghostty tab running `claude`, TermIMS detects the foreground process and switches to Chinese. Switch to a plain shell tab and it reverts to the terminal default.

## License

MIT
