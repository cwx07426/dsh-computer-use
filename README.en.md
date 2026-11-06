# Computer Use plugin (Windows desktop control)

English | [中文](README.md)

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) plugin that lets the model operate a real Windows desktop: screenshots, mouse, keyboard, and window management, plus UI Automation helpers that find, click, read, and fill controls by their accessible text — 9 model-facing tools in total.

Pure Windows implementation (Windows PowerShell + user32 `SendInput`/`CopyFromScreen` + UI Automation). No native Node modules, no build step, no external services.

```
computer-use-plugin/
├── package.json      # bundle manifest (dsh.bundle.patch) + peer dependency
├── cordis.patch.yml  # inserts the computer-use row and its configuration
├── lib/index.js      # plugin body: registers 9 tools, calls the desktop helper
└── lib/desktop.ps1   # desktop helper: one stateless process per call, JSON in / JSON out
```

## Requirements

- Windows 10 or 11
- DeepSeek Harness with the Plugin Manager
- Windows PowerShell 5.1 (shipped with Windows)

## Install

Put this directory anywhere, then in DeepSeek Harness run:

```
plugin_manager  action: install_bundle  target: "<absolute path to this directory>"
```

Every `computer_*` tool then becomes available to all sessions. Remove it from the Plugins page, or run
`dsh plugin --profile <profile> remove @local/dsh-computer-use`.

The plugin is Windows-only: on other platforms the tools register, but every action reports that the platform is unsupported.

## Tools

### `computer_screenshot`
Capture the desktop (or a region) to PNG. Returns the path, image size, screen rectangle, **scale factors**, monitor layout, cursor position, and the foreground window.

```json
{ "maxWidth": 1280 }
{ "region": { "x": 0, "y": 0, "width": 1280, "height": 800 }, "path": "C:\\tmp\\shot.png" }
```

The model views the PNG with `read_image`. **Important:** multiply coordinates from `read_image` by `scaleX` / `scaleY` to get physical screen pixels.

### `computer_mouse`
`move` / `click` / `double_click` / `right_click` / `middle_click` / `drag` / `scroll`. Coordinates are always **physical screen pixels**.

```json
{ "action": "click", "x": 960, "y": 540 }
{ "action": "drag", "x": 100, "y": 200, "toX": 400, "toY": 200 }
{ "action": "scroll", "x": 960, "y": 540, "amount": -3 }
```

### `computer_keyboard`
- `type`: per-character Unicode input, including Chinese, Traditional Chinese, and Japanese (via `SendInput` `KEYEVENTF_UNICODE`)
- `paste`: put text on the clipboard, then Ctrl+V — more reliable for long text and emoji
- `press`: one key, such as `"enter"`, `"f5"`, `"escape"`
- `hotkey`: a chord, such as `["ctrl","shift","esc"]` or `["alt","tab"]`

```json
{ "action": "type", "text": "hello\nsecond line" }
{ "action": "hotkey", "keys": ["ctrl", "s"] }
```

### `computer_window`
`list` / `active` / `focus` / `minimize` / `maximize` / `restore` / `close` / `launch`.

```json
{ "action": "list" }
{ "action": "focus", "title": "Notepad" }
{ "action": "close", "hwnd": 2099222 }
{ "action": "launch", "command": "notepad.exe" }
{ "action": "launch", "command": "explorer.exe", "arguments": "https://example.com" }
```

`launch` waits for the new window to appear and tries to bring it to the front; `focus` reports the real `focused` result plus a `warning` when it could not raise the window. Targets are matched by `hwnd` (exact) or `title` (case-insensitive substring).

### `computer_find_ui` — find controls by name, not pixels
Enumerate the controls of a window (or the whole desktop) through Windows UI Automation: buttons, menu items, tabs, edits, list items, document text, and more. Returns name, control type, AutomationId, rectangle, and center coordinates.

```json
{ "title": "Notepad" }
{ "title": "DeepSeek Harness", "text": "Plugins", "limit": 10 }
{ "text": "Save", "controlType": "Button" }
```

Common `controlType` values: `Button`, `MenuItem`, `Edit`, `Document`, `TabItem`, `ListItem`, `Text`, `ComboBox`, `CheckBox`, `Window`.

### `computer_click_text` — click by text
Focus the target window, locate the element by text (optionally constrained by control type, AutomationId, or index), and activate it. It prefers the UIA Invoke / SelectionItem / ExpandCollapse / Toggle patterns (far more reliable than pixel clicks) and only falls back to clicking the element center when no pattern is supported. `waitMs` retries until the element appears.

```json
{ "title": "Notepad", "text": "Edit", "controlType": "MenuItem" }
{ "title": "Settings", "text": "Save", "controlType": "Button", "waitMs": 5000 }
{ "text": "OK", "controlType": "Button", "index": 1 }
```

### `computer_wait_for` — wait for appearance or disappearance
No more blind `sleep`: wait until a window or an element appears (or disappears), returning `matched`, the elapsed time, and what was found.

```json
{ "what": "window", "title": "Save As", "timeoutMs": 8000 }
{ "what": "window", "title": "Loading", "state": "disappear", "timeoutMs": 15000 }
{ "what": "element", "title": "Settings", "text": "Save", "controlType": "Button", "timeoutMs": 5000 }
```

### `computer_read_text` — read a whole window as text
Walk the UI Automation tree and return the accessible names of labels, buttons, menu items, list items, tabs, and status bars, plus the real content of documents and edits through TextPattern / ValuePattern. Suits dialogs, forms, lists, error messages, and editor content.

```json
{ "title": "Notepad", "maxChars": 4000 }
{ "title": "Settings" }
{ "title": "DeepSeek Harness", "full": true }
```

### `computer_type_into` — write into an input by its label
Find the Edit/Document/ComboBox by label (or AutomationId / control type), focus it, and write the value. It prefers the UIA `ValuePattern` and **reads the value back to verify**, falling back to focus plus Unicode typing (optionally Ctrl+A first). `submit` presses Enter afterwards; `waitMs` waits for the field to appear.

```json
{ "title": "Find", "label": "Find", "controlType": "Edit", "text": "A-1024" }
{ "title": "Login", "label": "Username", "text": "test@example.com" }
{ "title": "Login", "label": "Password", "text": "secret", "submit": true }
```

> To clear an input, pass `""` as `text` together with `selectAll: true`.

## Recommended workflow

1. `computer_screenshot` to see the screen → `read_image` to view it, together with `scaleX` / `scaleY` and the foreground window.
2. **Prefer UIA for text-driven work**: `computer_read_text` to understand the UI → `computer_find_ui` to confirm control names → `computer_click_text` to click or `computer_type_into` to fill → `computer_wait_for` to wait for dialogs or loading.
3. When UIA is unavailable (games, canvases, remote desktops), fall back to pixels: `computer_window focus` → `computer_mouse` by coordinate → `computer_keyboard`.
4. After acting, take another screenshot or `computer_read_text` to confirm the result.

## Configuration (`cordis.patch.yml`)

| Key | Default | Meaning |
| --- | --- | --- |
| `screenshotDir` | empty | Directory for screenshots; empty uses `%TEMP%\dsh-computer-use\screenshots` |
| `maxImageWidth` | `1600` | Default downscale width for screenshots; `0` keeps native resolution |
| `allowInput` | `true` | When `false`, screenshots and window viewing stay available but mouse/keyboard injection and `launch` are blocked |
| `timeoutMs` | `30000` | Deadline for one desktop action |
| `powershell` | empty | Explicit `powershell.exe` path; empty uses the system Windows PowerShell |

Saving the patch hot-reloads the plugin; after changing `lib/index.js` you must reload the plugin (see Debugging).

## Security and limitations

- **UIPI / elevated windows**: the plugin runs with the DSH process's privileges. Windows refuses input injection into windows running as administrator (UAC elevation); `focus` returns `focused: false` or keys are ignored. Start DSH as administrator when you need to control elevated programs.
- **UAC secure desktop, lock screen, and the sign-in screen** cannot be captured or driven; that is by design.
- **CJK / full-width / emoji**: `type` uses Unicode `SendInput`. A few applications dislike synthetic input (terminals, some games); use `paste` instead.
- **Performance**: every action starts one stateless PowerShell process (roughly 0.6–1.3 s). Batch parameters to reduce calls. UIA searches run in-process and are usually < 0.5 s inside a window, but enumerating the entire desktop (about 30k elements) takes around 5 s — always constrain with `title` / `hwnd`.
- **Multi-monitor / high DPI**: the helper is DPI-aware; screenshots and mouse coordinates use physical pixels, and `scaleX` / `scaleY` convert `read_image` preview coordinates.
- **UIA coverage**: Win32 / WinForms / WPF / Qt / Electron and Chromium (Chrome, Edge, DSH itself) / Office / most UWP apps expose a control tree; games, video canvases, remote desktops, and custom-drawn UI usually do not — `computer_find_ui` then returns 0 elements and you should fall back to screenshot plus coordinates.
- **UWP exceptions**: some system apps (for example Settings) wrap their content in an `ApplicationFrameWindow`, so `computer_find_ui` may return nothing for that handle; use screenshots instead.
- **Pattern first**: `computer_click_text` prefers UIA Invoke/Select/Expand/Toggle, so it does not move the mouse or click the wrong place; it falls back to a center click only when no pattern is supported, and the returned `method` tells you which path ran.

## Debugging

Run the desktop helper directly, bypassing DSH:

```powershell
$req = "$env:TEMP\req.json"; $res = "$env:TEMP\res.json"
'{"action":"info"}' | Set-Content -LiteralPath $req -Encoding UTF8
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\lib\desktop.ps1 -RequestFile $req -ResultFile $res
Get-Content -LiteralPath $res -Raw
```

Supported `action` values: `screenshot`, `mouse`, `keyboard`, `window`, `ui`, `uiclick`, `wait`, `uitext`, `uiset`, `info` (field meanings are documented in the C# declarations at the top of `lib/desktop.ps1` and in each branch).

After changing `lib/index.js`, reload the plugin: toggle the bundle off and on in the Plugin Manager, or change a config value in `cordis.patch.yml` to trigger a configuration-layer reload. `lib/desktop.ps1` is re-read on every call, so changes apply immediately.

## Development validation (author's machine)

- `info` / `screenshot` (full screen, region, downscale with correct scale) ✅
- `window`: list / active / focus (including `AttachThreadInput` foreground) / launch / close / minimize ✅
- `mouse`: move / click / drag (verified with a window offset of +100,+100) / scroll ✅
- `keyboard`: type (Chinese, Traditional Chinese, ASCII, symbols) / press / hotkey (ctrl+a, alt+n) ✅
- End to end: launch Notepad → focus → type Chinese → region screenshot → close without saving ✅
- `ui`: Notepad exposes 12 controls (File/Edit/View menus, bold, italic, text editor, tab); DeepSeek Harness (Electron) exposes sidebar and title-bar buttons with correct localized names ✅
- `uiclick`: clicking the Notepad menu item "Edit" + `MenuItem` hits the invoke pattern and opens the menu; desktop `Program Manager` falls back to a mouse click ✅
- `wait`: window appeared in 71 ms; element appeared in 226 ms; a missing target returns `matched=false` after the timeout ✅
- `uitext`: Notepad returns 31 text blocks (document body lines, menus, status bar, find bar); DeepSeek Harness returns 30 text blocks ✅
- `uiset`: Notepad's Find field is written and read back consistently; a Notepad document is fully replaced via `Document` and verified by read-back; the DSH composer is written with 34 characters and verified (keyboard fallback path) ✅

### Fixed

- The C# callback used for window enumeration used to be a temporary delegate that could be garbage-collected, occasionally dropping windows (`no window matching ...`, `no matching input control found`). It is now held in a static field, and repeated `list` calls are stable (7/7/7).

## License

MIT, see [LICENSE](LICENSE).
