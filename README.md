<h1 align="center">TermIMS</h1>

<p align="center"><img src="icon.png" width="128"></p>

<p align="center">A lightweight macOS menu bar app that automatically switches input methods based on the active application — and for terminal apps, based on the running process or tab title.</p>

## Features

- **Per-app input method rules** — Assign a specific input method to any application. When you switch to that app, the input method changes automatically.
- **Terminal sub-rules** — For terminal emulators (Ghostty, Terminal.app, iTerm2, kitty, wezterm, Warp, Alacritty), define additional rules that match by:
  - **Process name** — e.g., switch input method when `claude` or `nvim` is running in the active tab or split pane
  - **Tab title** — e.g., match a keyword in the terminal window title
- **Global default** — Set a fallback input method for apps without specific rules.
- **Terminal default** — Set a separate default for terminal apps when no sub-rule matches.
- **Switch indicator** — A brief overlay shows the current input method on switch. Configurable position (center, corners) and can be disabled.
- **Launch at Login** — Optional LaunchAgent-based auto-start.
- **Hide menu bar icon** — Run silently without a status bar icon. Reopen the app to access Settings.
- **Permission handling** — Guides you through granting Accessibility permission on first launch, and detects if permission is revoked.

## How It Works

TermIMS uses the macOS Accessibility API to monitor application focus changes and terminal tab switches. To map a focused tab to its foreground process, it goes through a small adapter layer that picks the most precise channel each terminal offers, then falls back to a generic working-directory + process-tree heuristic when no native channel exists.

## Terminal Support

Different terminals expose different signals about the focused tab. Status as of current testing:

| Terminal | Channel | Status | Extra setup |
|---|---|---|---|
| Ghostty | `AXDocument` cwd + process-tree heuristic | Works for tabs in distinct working directories; multiple tabs sharing a cwd need a title rule to disambiguate | None |
| Apple Terminal | AppleScript `tty of selected tab` | Works precisely for every tab | First launch macOS prompts for **Automation → Terminal** — accept it |
| kitty | `kitten @ ls` JSON | Works precisely for every tab | Add `allow_remote_control yes` **and** `listen_on unix:/tmp/kitty` to `~/.config/kitty/kitty.conf` and restart kitty. The socket path can be anything — TermIMS reads `listen_on` from the same file. |
| WezTerm | `wezterm cli list` JSON | Works precisely for every tab | None |
| iTerm2 | AppleScript `tty of current session of current window` | Works precisely for every tab and split pane | First launch macOS prompts for **Automation → iTerm**; accept it |
| Warp | Title heuristic (process-name match → shell-cwd match → ordered fallback) | Works in practice for most tabs; relies on Warp's habit of writing the running command or cwd into the tab title | None |
| Alacritty | Not supported | Alacritty is intentionally minimal — it doesn't expose cwd via AX, has no query CLI, and doesn't update its window title to track the running command. With multiple windows there's no reliable signal to disambiguate the focused one. Use a multiplexer (tmux) inside a single Alacritty window instead. | n/a |

For terminals on the generic-heuristic path, if you put each tab in its own working directory things work out of the box. When multiple tabs share a directory the matcher can't tell them apart from cwd alone — add a **Tab Title** rule to disambiguate (title rules are checked before process rules).

## Requirements

- macOS 13.0+
- Accessibility permission (System Settings → Privacy & Security → Accessibility)
- Automation permission for Apple Terminal and/or iTerm2 if you use them (System Settings → Privacy & Security → Automation → TermIMS → ...). macOS prompts on first focus event for each app — just accept.

## Install

### Download

Download `TermIMS.dmg` from the [Releases](https://github.com/cuiko/TermIMS/releases) page, open it, and drag `TermIMS.app` into the `Applications` folder.

### Build from source

The project is a single Swift file compiled directly with `swiftc`. No Xcode project needed.

```sh
git clone https://github.com/cuiko/TermIMS.git
cd TermIMS

# Build locally
make build

# Build and install to /Applications
make install

# Build, install, and launch
make run

# Package as DMG for distribution
make dist
```

## Usage

1. Launch TermIMS (or run `make run`).
2. Grant Accessibility permission when prompted.
3. Click the keyboard icon in the menu bar → **Settings**.
4. **General** tab — Set the global default input method, indicator preferences.
5. **App Rules** tab — Click **+** to add an app and assign its input method.
6. **Terminal Rules** tab — Set the terminal default, then add rules to match by process name or tab title.

### Terminal Rules Example

| Match        | Pattern  | Input Method |
|--------------|----------|--------------|
| Process Name | `claude` | Pinyin       |
| Process Name | `nvim`   | ABC          |
| Tab Title    | `ssh`    | ABC          |

When you switch to a Ghostty tab running `claude`, TermIMS detects the foreground process and switches to the configured input method. Switch to a plain shell tab and it reverts to the terminal default.

---

Inspired by [KeyboardHolder](https://github.com/leaves615/KeyboardHolder).

## License

MIT
