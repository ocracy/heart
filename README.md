# Heart

> One window. Every dev process. A real terminal. A built-in browser. And
> Claude sessions on tap. Native macOS, ~5 MB, no Electron.

**Heart** is a SwiftUI launcher for the local dev workflow you already have.
Define your stack in a JSON file, drop it into the sidebar, and your Laravel
server, three Vite frontends, ngrok tunnel, queue worker, and a fleet of
`claude` shells all live side by side in a single window. Click a task to
see its terminal. Click again to flip to the live preview. Hit a Claude
shortcut to spawn another agent in that directory — keep two, three, five
of them open in parallel.

<p align="center">
  <img src="docs/demo.gif" width="780" alt="Heart demo">
</p>

<p align="center">
  <img src="docs/screenshot.png" width="780" alt="Heart screenshot">
</p>

---

## Why Heart?

Modern projects need a Laravel API, a few frontend dev servers, an ngrok
tunnel, a worker, plus a couple of `claude` sessions to ask questions and
run agents. That's six terminal tabs and six browser windows, and you spend
half the day finding which is which.

Heart collapses all of that into **one window**. One sidebar of tasks, one
detail pane that shows you exactly what you need: a terminal, an in-app
browser, or a stack of parallel Claude conversations.

---

## Features

### 📁 JSON config + named folders

Drop a `heart.json` onto the sidebar and Heart imports it as a folder. The
bundle's `name` becomes the folder name — no prompt, no setup. Drop a
second bundle, get a second folder. Each project stays scoped.

```json
{
  "name": "Maatrics",
  "tasks": [
    { "id": "laravel", "name": "Laravel Serve", "command": "php artisan serve",
      "cwd": "~/projects/maatrics/api", "port": 8000,
      "url": "http://localhost:8000" },
    { "id": "frontend", "name": "Frontend", "command": "npm run dev",
      "cwd": "~/projects/maatrics/web", "folder": "Frontend",
      "url": "http://localhost:5173" }
  ]
}
```

Nested folders via slash: `"folder": "Backend/Workers"` → `Maatrics/Backend/Workers`.
The legacy bare-array shape is still accepted (the file just lacks a
top-level name → Heart prompts for one).

### ✨ Claude Code support — multi-session shortcuts

Tag a task with `"kind": "claude"` and Heart treats it as an agent shortcut,
not a service:

```json
{ "id": "claude-frontend", "kind": "claude",
  "command": "claude", "cwd": "~/projects/maatrics/web",
  "name": "Claude Frontend" }
```

Click the shortcut and you get a multi-session detail pane:

- **+** opens another `claude` session in the same directory — fan out as
  many parallel agents as you want
- Each session has its own terminal pill: status dot, name, **pencil icon**
  to rename ("Bug fix", "Feature spike", "Quick question"), **X** to kill
  just that session
- Sessions **persist** across sidebar selection. Open three Claudes,
  switch to your Laravel terminal, come back — all three are still there,
  exactly as you left them
- Shift+Enter inserts a newline in the prompt without submitting (no
  `claude /terminal-setup` needed — Heart handles it natively)

### 🌐 Built-in browser per service

Set `"url"` on a task and you get a globe icon in the sidebar plus a
**Browser** tab in the detail pane:

- Address bar, back / forward, reload that actually works on flaky
  localhost servers
- 📱 Mobile toggle — clamps the viewport to 390 pt and swaps the
  user-agent so the page renders as iPhone Safari
- 🌐 **Open in Chrome** button — hands the current URL to the system
  Google Chrome (or the default browser if Chrome isn't installed)
- Cookies and localStorage persist across launches via the default WKWebView data store

### ⚡ One-click Activate overlay

Selected a task that's not running? Heart shows a big **Activate** button
right where the terminal would go, with the command displayed underneath.
Click it, the process starts, and the sidebar's play icon flips to stop
in sync.

When a task crashes, the same overlay shows the exit code and a
**Restart** button.

### 🚀 Real terminal — iTerm-class

Powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
(xterm-256color compatible). Renders ANSI colors, cursor positioning,
mouse, scrollback, and TUIs — `vim`, `htop`, `ngrok`, `k9s`, `claude`,
`fzf` all work exactly as they would in iTerm2 or Apple Terminal. PTY
size follows the SwiftUI view (`TIOCSWINSZ` on resize), so full-screen
TUIs reflow correctly when you resize the window or collapse the sidebar.

### 🪟 Collapsible sidebar

Hit `⌃⌘S` (or click the toolbar button) to hide the sidebar. The terminal
+ browser take the whole window — distraction-free coding mode.

### 🛡️ Clean shutdown — no orphan ports

Cmd+Q runs every running task through a graceful chain in parallel:

1. **Ctrl+C** through the PTY (SIGINT to the foreground process group)
2. **`killpg(SIGTERM)`** to the entire process group — covers shell
   children that wouldn't otherwise receive a signal when the parent zsh
   dies
3. Up to 2 s shared wait so all tasks drain in parallel
4. **`killpg(SIGKILL)`** for any stragglers

Result: the next launch finds 8000, 5173, 8082 all free. Force-quit is
the only case Heart can't recover from (no handlers run on SIGKILL from
the OS).

### 🔌 KILL PORT button

For when something *else* on your machine is still pinning :8000.
Click → `lsof -ti tcp:8000 | xargs kill -9`, scoped to the task's port.

### ⌨️ Login shell that respects your dotfiles

Commands run under `/bin/zsh -l -i -c` — both `.zprofile` *and* `.zshrc`
sourced, so your custom PATH, aliases, fnm, mise, asdf, and rbenv hooks
all work without surprises.

---

## Install

### From a release

Grab the latest [**Heart.zip**](https://github.com/ocracy/heart/releases/latest):

1. Unzip → drag `Heart.app` into **`/Applications`**.
2. In Terminal:
   ```bash
   xattr -cr /Applications/Heart.app && open /Applications/Heart.app
   ```
3. Launch from Spotlight (`⌘+Space` → "heart") on subsequent runs.

> **Why step 2?** Heart is ad-hoc signed. The `xattr` command clears
> `com.apple.quarantine` — safe and one-time only.

**Don't want to use Terminal?** Finder → right-click `/Applications/Heart.app`
→ **Open** → **Open** in the dialog.

### From source

```bash
git clone https://github.com/ocracy/heart.git
cd heart
./install.sh
```

Installs to `/Applications/Heart.app`. Requires macOS 13+ and Swift 5.9
(Xcode Command Line Tools).

---

## First run

Heart starts with two placeholder tasks. Three ways to add your own:

**A. Drag-and-drop** — drop a `heart.json` (or any `tasks.json`) onto the
dashed area at the bottom of the sidebar. If the JSON has a top-level
`name`, the import is silent — your tasks land under that folder
immediately. Otherwise Heart prompts for a folder name.

**B. Right-click → Edit** — modify any task in a clean form. Saves to
disk on every keystroke commit.

**C. Settings → JSON editor** (`⌘+,`) — paste raw JSON, validate, save.

A starter [`tasks.example.json`](tasks.example.json) ships with the repo.

---

## tasks.json schema

Two accepted shapes:

```jsonc
// Bundle (preferred — auto-imports under "name", no prompt):
{
  "name": "Maatrics",
  "tasks": [ /* DevTask[] */ ]
}

// Or just a bare array (legacy, prompts for folder name):
[ /* DevTask[] */ ]
```

Each task:

| Field       | Type      | Notes                                                                    |
|-------------|-----------|--------------------------------------------------------------------------|
| `id`        | string    | Unique key (slug or UUID)                                                |
| `name`      | string    | Sidebar label                                                            |
| `command`   | string    | Runs under `/bin/zsh -l -i -c`                                           |
| `cwd`       | string    | Absolute path or `~/...` (tilde is expanded)                             |
| `port`      | int?      | If set: enables readiness check + KILL PORT button                       |
| `url`       | string?   | Adds globe icon + in-app Browser tab                                     |
| `folder`    | string?   | Sidebar grouping. Slash-separated for nesting: `Backend/Workers`         |
| `kind`      | string?   | `"claude"` → multi-session shortcut, pinned with sparkles badge           |
| `autoStart` | bool?     | Reserved — saved but not yet acted on                                    |

Persisted at `~/Library/Application Support/Heart/tasks.json`.

---

## Workflow — what one window looks like

```
1. Drop heart.json (your project's config) → all services + Claude shortcuts appear
2. Click each row's play icon → full stack spins up in seconds
3. Click the globe icon → see the live preview without leaving Heart
4. Click a Claude shortcut → terminal opens with `claude` in that dir
5. Need a parallel agent? + → second session, both alive, name them
6. Cmd+Q when done — every port is freed
```

That's the whole thing. One window. Everything together.

---

## Scripts

```bash
./build.sh     # release build → ./Heart.app (no install)
./install.sh   # build + install to /Applications/Heart.app
./dist.sh      # universal (arm64 + x86_64) → Heart.zip for distribution
```

To regenerate just the icon:
```bash
swift scripts/make-icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

---

## Uninstall

```bash
rm -rf /Applications/Heart.app
rm -rf ~/Library/Application\ Support/Heart
```

---

## Tech stack

- Swift 5.9, SwiftUI, AppKit (macOS 13+)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation (xterm-256color, mouse, scrollback)
- WKWebView — in-app browser
- Foundation `Process` + `forkpty` (via SwiftTerm) — child management
- Swift Package Manager (no Xcode project)
- Sandbox disabled (required to spawn arbitrary child processes)
- ~5 MB binary

---

## License

MIT — see [LICENSE](LICENSE).
