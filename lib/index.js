/**
 * Computer-use tools for DeepSeek Harness (Windows host).
 *
 * The plugin registers four model-facing tools that drive the real desktop:
 * screenshot capture, mouse input, keyboard input, and window management.
 * Every action is executed by one stateless Windows PowerShell child process
 * running `lib/desktop.ps1`, which talks back through a temporary JSON file so
 * that no console encoding can corrupt Unicode text.
 * @module @local/dsh-computer-use
 */
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineTool } from '@deepseek-ai/dsh-tools'

/** Stable Loader identity. */
export const name = 'computer-use'

/** Services this plugin needs. */
export const inject = ['tools']

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SCRIPT = path.join(HERE, 'desktop.ps1')

const DEFAULTS = {
  /** Directory for screenshots; empty means the OS temp directory. */
  screenshotDir: '',
  /** Default downscale width for screenshots (0 keeps native resolution). */
  maxImageWidth: 1600,
  /** Allow mouse and keyboard injection. */
  allowInput: true,
  /** Deadline for one desktop-helper call. */
  timeoutMs: 30000,
  /** Explicit powershell.exe path, overriding Windows PowerShell discovery. */
  powershell: '',
}

const PLATFORM_NOTE =
  process.platform === 'win32'
    ? ''
    : ' This plugin only controls Windows desktops; no other platform backend is installed.'

/**
 * Resolve the Windows PowerShell executable.
 * @param config - merged plugin configuration.
 * @returns an absolute executable path.
 */
function powershellPath(config) {
  if (config.powershell) return config.powershell
  const root = process.env.SystemRoot || 'C:\\Windows'
  const classic = path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  if (fs.existsSync(classic)) return classic
  return 'powershell.exe'
}

/**
 * Run one desktop action through the PowerShell helper.
 * @param request - helper request object.
 * @param config - merged plugin configuration.
 * @param signal - caller cancellation signal.
 * @returns the helper's `data` payload.
 */
async function runDesktop(request, config, signal) {
  if (process.platform !== 'win32') throw new Error('computer-use requires a Windows host.' + PLATFORM_NOTE)
  const tmpDir = path.join(os.tmpdir(), 'dsh-computer-use')
  fs.mkdirSync(tmpDir, { recursive: true })
  const stamp = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`
  const requestFile = path.join(tmpDir, `req-${stamp}.json`)
  const resultFile = path.join(tmpDir, `res-${stamp}.json`)
  fs.writeFileSync(requestFile, JSON.stringify(request), 'utf8')
  try {
    await new Promise((resolve, reject) => {
      const child = spawn(
        powershellPath(config),
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          SCRIPT,
          '-RequestFile',
          requestFile,
          '-ResultFile',
          resultFile,
        ],
        { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] },
      )
      let stderr = ''
      let settled = false
      const finish = (fn, value) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        if (signal) signal.removeEventListener('abort', onAbort)
        fn(value)
      }
      const timer = setTimeout(() => {
        try {
          child.kill()
        } catch {}
        finish(reject, new Error(`desktop helper timed out after ${config.timeoutMs}ms`))
      }, config.timeoutMs)
      const onAbort = () => {
        try {
          child.kill()
        } catch {}
        finish(reject, new Error('computer-use action was cancelled'))
      }
      if (signal) {
        if (signal.aborted) onAbort()
        else signal.addEventListener('abort', onAbort, { once: true })
      }
      child.stderr.on('data', (chunk) => {
        stderr += chunk.toString('utf8')
        if (stderr.length > 8000) stderr = stderr.slice(-8000)
      })
      child.on('error', (error) => finish(reject, error))
      child.on('close', (code) => {
        if (settled) return
        if (!fs.existsSync(resultFile)) {
          finish(reject, new Error(`desktop helper exited with code ${code}${stderr.trim() ? `: ${stderr.trim()}` : ''}`))
          return
        }
        finish(resolve, undefined)
      })
    })
    const parsed = JSON.parse(fs.readFileSync(resultFile, 'utf8').replace(/^\uFEFF/, ''))
    if (!parsed || parsed.ok !== true) throw new Error(parsed && parsed.error ? parsed.error : 'desktop helper failed')
    return parsed.data
  } finally {
    for (const file of [requestFile, resultFile]) {
      try {
        fs.unlinkSync(file)
      } catch {}
    }
  }
}

/**
 * Describe one window on a single line.
 * @param window - helper window record.
 * @returns compact human/model readable text.
 */
function windowLine(window) {
  if (!window) return 'none'
  const flags = window.minimized ? ' [minimized]' : ''
  return `"${window.title}" (${window.process || '?'}, pid ${window.pid}) at ${window.x},${window.y} ${window.width}x${window.height}${flags}`
}

/**
 * Describe one UI Automation element on a single line.
 * @param index - zero-based position in the returned list.
 * @param element - helper element record.
 * @returns compact human/model readable text.
 */
function elementLine(index, element) {
  const id = element.automationId ? ` #${element.automationId}` : ''
  const state = element.offscreen ? ' [offscreen]' : element.enabled === false ? ' [disabled]' : ''
  return `[${index}] "${element.name}" (${element.controlType || '?'}${id}) at ${element.x},${element.y} ${element.width}x${element.height}; center ${element.centerX},${element.centerY}${state}`
}

/**
 * Describe the monitor layout.
 * @param monitors - helper monitor records.
 * @returns one-line layout summary.
 */
function monitorLine(monitors) {
  if (!Array.isArray(monitors) || monitors.length === 0) return 'unknown'
  return monitors
    .map((m, index) => `#${index + 1}${m.primary ? ' primary' : ''} ${m.width}x${m.height} at ${m.x},${m.y}`)
    .join('; ')
}

/**
 * Compose the screenshot result text.
 * @param data - helper payload.
 * @returns model-facing summary.
 */
function screenshotText(data) {
  const lines = [
    `Screenshot saved to ${data.path}`,
    `Image ${data.imageWidth}x${data.imageHeight}px covering screen region ${data.screenX},${data.screenY} ${data.screenWidth}x${data.screenHeight}px.`,
    `Scale: screen_x = image_x * ${data.scaleX}, screen_y = image_y * ${data.scaleY}.`,
    `Monitors: ${monitorLine(data.monitors)}. Cursor at ${data.cursor.x},${data.cursor.y}.`,
    `Active window: ${windowLine(data.activeWindow)}.`,
    'Call read_image on the screenshot path to view it, then pass screen coordinates to computer_mouse.',
  ]
  return lines.join('\n')
}

/**
 * Resolve the default screenshot directory.
 * @param config - merged plugin configuration.
 * @returns absolute directory path.
 */
function screenshotDirectory(config) {
  return config.screenshotDir || path.join(os.tmpdir(), 'dsh-computer-use', 'screenshots')
}

/**
 * Register the computer-use tools on `ctx.tools`.
 * @param ctx - registrant context carrying the tool registry.
 * @param rawConfig - deployment configuration from the profile patch.
 */
export function apply(ctx, rawConfig) {
  const config = { ...DEFAULTS, ...(rawConfig || {}) }
  if (!Number.isSafeInteger(config.maxImageWidth) || config.maxImageWidth < 0) {
    throw new Error('computer-use requires maxImageWidth to be a non-negative integer')
  }
  if (!Number.isSafeInteger(config.timeoutMs) || config.timeoutMs < 1000) {
    throw new Error('computer-use requires timeoutMs to be an integer of at least 1000')
  }

  const guardInput = () => {
    if (config.allowInput === false) {
      throw new Error('mouse and keyboard control are disabled; set allowInput: true in the computer-use plugin config to enable them')
    }
  }

  ctx.tools.register(
    defineTool({
      name: 'computer_screenshot',
      description:
        'Capture the Windows desktop to a PNG file and return its path, exact pixel size, monitor layout, cursor position, the active window, and the screen-to-image scale. Call this before driving the desktop, then open the returned path with read_image. Screen coordinates for computer_mouse are image coordinates multiplied by scaleX/scaleY.' +
        PLATFORM_NOTE,
      parameters: {
        path: {
          type: 'string',
          description: 'Optional absolute file path for the PNG. Defaults to a fresh file in the plugin screenshot directory.',
        },
        maxWidth: {
          type: 'integer',
          description: 'Optional downscale width in pixels; 0 keeps native resolution. Defaults to the plugin maxImageWidth.',
        },
        region: {
          type: 'object',
          additionalProperties: false,
          description: 'Optional screen rectangle to capture instead of the whole virtual desktop.',
          properties: {
            x: { type: 'integer', required: true, description: 'Left edge in screen coordinates.' },
            y: { type: 'integer', required: true, description: 'Top edge in screen coordinates.' },
            width: { type: 'integer', required: true, description: 'Width in pixels.' },
            height: { type: 'integer', required: true, description: 'Height in pixels.' },
          },
        },
      },
      output: {
        schema: { type: 'json' },
        render: (_args, value) => [{ type: 'text', text: screenshotText(value) }],
      },
      async execute(args, exec) {
        const target =
          args.path && args.path.trim()
            ? args.path.trim()
            : path.join(screenshotDirectory(config), `shot-${new Date().toISOString().replace(/[:.]/g, '-')}.png`)
        const request = {
          action: 'screenshot',
          path: target,
          maxWidth: args.maxWidth === undefined ? config.maxImageWidth : args.maxWidth,
        }
        if (args.region) request.region = args.region
        return runDesktop(request, config, exec.signal)
      },
    }),
  )

  ctx.tools.register(
    defineTool({
      name: 'computer_mouse',
      description:
        'Move, click, double-click, drag, or scroll the physical mouse using SCREEN coordinates (physical pixels, as reported by computer_screenshot). Call computer_screenshot first to locate the target, and use computer_window focus when the target window must own the input.' +
        PLATFORM_NOTE,
      parameters: {
        action: {
          type: 'string',
          required: true,
          enum: ['move', 'click', 'double_click', 'right_click', 'middle_click', 'drag', 'scroll'],
          description: 'What to do with the mouse.',
        },
        x: { type: 'integer', description: 'Target screen X in pixels (required for move, click, double_click, drag; optional for scroll).' },
        y: { type: 'integer', description: 'Target screen Y in pixels (required for move, click, double_click, drag; optional for scroll).' },
        toX: { type: 'integer', description: 'Drag end X in screen pixels.' },
        toY: { type: 'integer', description: 'Drag end Y in screen pixels.' },
        button: {
          type: 'string',
          enum: ['left', 'right', 'middle'],
          description: 'Button for click and double_click; defaults to left.',
        },
        amount: {
          type: 'integer',
          description: 'Scroll wheel notches; positive scrolls up, negative scrolls down. Defaults to 3.',
        },
      },
      output: {
        schema: { type: 'json' },
        render: (args, value) => [
          {
            type: 'text',
            text: `${args.action} at ${value.cursor.x},${value.cursor.y}. Active window: ${windowLine(value.activeWindow)}.`,
          },
        ],
      },
      async execute(args, exec) {
        guardInput()
        const mapping = {
          click: 'click',
          double_click: 'double_click',
          right_click: 'click',
          middle_click: 'click',
          move: 'move',
          drag: 'drag',
          scroll: 'scroll',
        }
        const request = { action: 'mouse', mouseAction: mapping[args.action] }
        if (args.action === 'right_click') request.button = 'right'
        else if (args.action === 'middle_click') request.button = 'middle'
        else if (args.button) request.button = args.button
        if (args.x !== undefined) request.x = args.x
        if (args.y !== undefined) request.y = args.y
        if (args.toX !== undefined) request.toX = args.toX
        if (args.toY !== undefined) request.toY = args.toY
        if (args.amount !== undefined) request.amount = args.amount
        return runDesktop(request, config, exec.signal)
      },
    }),
  )

  ctx.tools.register(
    defineTool({
      name: 'computer_keyboard',
      description:
        'Send keyboard input to the focused window. action=type writes literal text with Unicode input, including Chinese characters; action=paste copies the text to the clipboard and sends Ctrl+V, which is more reliable for long text, emoji, or apps that mishandle synthetic typing; action=press sends one named key; action=hotkey sends a chord such as ctrl+shift+esc. Focus the target window with computer_window first.' +
        PLATFORM_NOTE,
      parameters: {
        action: {
          type: 'string',
          required: true,
          enum: ['type', 'paste', 'press', 'hotkey'],
          description: 'How to deliver the input.',
        },
        text: { type: 'string', description: 'Literal text for type and paste.' },
        keys: {
          type: 'array',
          description: 'Key names for press (one entry) or hotkey (modifiers first, final key last), for example "enter", "f5", ["ctrl", "c"].',
          items: { type: 'string' },
        },
      },
      output: {
        schema: { type: 'json' },
        render: (args, value) => [
          {
            type: 'text',
            text:
              args.action === 'type' || args.action === 'paste'
                ? `${args.action} delivered ${value.characters} characters. Active window: ${windowLine(value.activeWindow)}.`
                : `${value.action} sent: ${(value.keys || [value.key]).join('+')}. Active window: ${windowLine(value.activeWindow)}.`,
          },
        ],
      },
      async execute(args, exec) {
        guardInput()
        const action = args.action
        if ((action === 'type' || action === 'paste') && (typeof args.text !== 'string' || args.text.length === 0)) {
          throw new Error(`computer_keyboard ${action} requires non-empty text`)
        }
        if ((action === 'press' || action === 'hotkey') && (!Array.isArray(args.keys) || args.keys.length === 0)) {
          throw new Error(`computer_keyboard ${action} requires keys`)
        }
        return runDesktop(
          { action: 'keyboard', keyboardAction: action, text: args.text, keys: args.keys },
          config,
          exec.signal,
        )
      },
    }),
  )

  ctx.tools.register(
    defineTool({
      name: 'computer_window',
      description:
        'Inspect and control top-level desktop windows. list returns every visible window with hwnd, title, process name, and rectangle; active returns the foreground window; focus/minimize/maximize/restore/close act on a window found by hwnd or case-insensitive title substring; launch starts a program and returns the window it opened. Run focus before sending keyboard or mouse input to a window that is not already in front.' +
        PLATFORM_NOTE,
      parameters: {
        action: {
          type: 'string',
          required: true,
          enum: ['list', 'active', 'focus', 'minimize', 'maximize', 'restore', 'close', 'launch'],
          description: 'Window operation to perform.',
        },
        title: {
          type: 'string',
          description: 'Case-insensitive title substring identifying the target window (focus, minimize, maximize, restore, close).',
        },
        hwnd: { type: 'integer', description: 'Exact window handle, preferred over title when known.' },
        command: { type: 'string', description: 'Executable, document, or URL to start for launch.' },
        arguments: { type: 'string', description: 'Command-line arguments for launch, as one string.' },
        workingDirectory: { type: 'string', description: 'Working directory for launch.' },
      },
      output: {
        schema: { type: 'json' },
        render: (args, value) => {
          if (args.action === 'list') {
            const lines = (value.windows || []).map((w) => `[${w.hwnd}] ${windowLine(w)}`)
            return [{ type: 'text', text: `${value.count} visible window(s):\n${lines.join('\n') || '(none)'}` }]
          }
          if (args.action === 'active') return [{ type: 'text', text: `Active window: ${windowLine(value.window)}.` }]
          if (args.action === 'launch') {
            return [
              {
                type: 'text',
                text: `Launched ${value.process || args.command} (pid ${value.pid}). Window: ${windowLine(value.window)}.`,
              },
            ]
          }
          if (args.action === 'focus') {
            const warning = value.warning ? ` ${value.warning}` : ''
            return [
              {
                type: 'text',
                text: `Focus ${value.focused ? 'succeeded' : 'failed'}. Foreground window: ${windowLine(value.window)}.${warning}`,
              },
            ]
          }
          return [{ type: 'text', text: `${args.action}: ${windowLine(value.window)}.` }]
        },
      },
      async execute(args, exec) {
        const request = { action: 'window', windowAction: args.action }
        if (args.title !== undefined) request.title = args.title
        if (args.hwnd !== undefined) request.hwnd = args.hwnd
        if (args.command !== undefined) request.command = args.command
        if (args.arguments !== undefined) request.arguments = args.arguments
        if (args.workingDirectory !== undefined) request.workingDirectory = args.workingDirectory
        if (args.action === 'launch') guardInput()
        return runDesktop(request, config, exec.signal)
      },
    }),
  )

  ctx.tools.register(
    defineTool({
      name: 'computer_find_ui',
      description:
        'List UI Automation elements of a window (or the whole desktop) so you can locate controls by their accessible name instead of pixels: buttons, menu items, tabs, edits, list items, tree items, and document text. Filter with text (case-insensitive substring), controlType (Button, MenuItem, Edit, Document, TabItem, ListItem, Text, ComboBox, CheckBox, Window...), or automationId. Call it before computer_click_text when you are unsure of the exact label, and call it with no text to dump the named elements of a window. Works with Win32, WinForms, WPF, Qt, Electron/Chromium, Office and most UWP apps; games, video canvases, or remote-desktop surfaces expose no tree and need screenshot plus coordinates instead.' +
        PLATFORM_NOTE,
      parameters: {
        text: {
          type: 'string',
          description: 'Case-insensitive substring of the accessible name. Omit to list all named elements in scope.',
        },
        controlType: { type: 'string', description: 'Exact UI Automation control type, for example Button or MenuItem.' },
        automationId: { type: 'string', description: 'Exact AutomationId when the app exposes one.' },
        title: { type: 'string', description: 'Window title substring limiting the search; omit to search the whole desktop.' },
        hwnd: { type: 'integer', description: 'Exact window handle limiting the search; preferred over title when known.' },
        limit: { type: 'integer', description: 'Maximum elements to return; defaults to 40.' },
        includeOffscreen: { type: 'boolean', description: 'Include scrolled-away or hidden elements; defaults to false.' },
      },
      output: {
        schema: { type: 'json' },
        render: (args, value) => {
          const scope = value.scope ? `"${value.scope.title}"` : 'the desktop'
          if (!value.count) {
            return [
              {
                type: 'text',
                text: `No UI Automation element matched in ${scope}. The window may expose no accessibility tree (games, canvases) or the filter is too narrow; use computer_screenshot and coordinates instead.`,
              },
            ]
          }
          const lines = value.elements.map((el, index) => elementLine(index, el))
          return [{ type: 'text', text: `${value.count} UI element(s) in ${scope}:\n${lines.join('\n')}` }]
        },
      },
      async execute(args, exec) {
        const request = { action: 'ui' }
        if (args.text !== undefined) request.text = args.text
        if (args.controlType !== undefined) request.controlType = args.controlType
        if (args.automationId !== undefined) request.automationId = args.automationId
        if (args.title !== undefined) request.windowTitle = args.title
        if (args.hwnd !== undefined) request.hwnd = args.hwnd
        if (args.limit !== undefined) request.limit = args.limit
        if (args.includeOffscreen !== undefined) request.includeOffscreen = args.includeOffscreen
        return runDesktop(request, config, exec.signal)
      },
    }),
  )

  ctx.tools.register(
    defineTool({
      name: 'computer_click_text',
      description:
        'Find a UI Automation element by its visible text and activate it, which is more reliable than clicking pixels. It first focuses the scoped window, retries until the element appears (waitMs), then prefers the element\'s Invoke/SelectionItem/ExpandCollapse/Toggle pattern and falls back to a mouse click at its center. Use index when several elements share the text, and controlType or automationId to disambiguate. Works for Win32, WinForms, WPF, Qt, Electron/Chromium, Office and most UWP apps; for games or canvas surfaces use computer_screenshot plus computer_mouse.' +
        PLATFORM_NOTE,
      parameters: {
        text: {
          type: 'string',
          description: 'Case-insensitive substring of the element\'s accessible name, for example a button label.',
        },
        controlType: { type: 'string', description: 'Exact control type to disambiguate, for example Button or MenuItem.' },
        automationId: { type: 'string', description: 'Exact AutomationId to disambiguate.' },
        title: { type: 'string', description: 'Window title substring to focus and search within; omit to search the whole desktop.' },
        hwnd: { type: 'integer', description: 'Exact window handle to focus and search within; preferred over title.' },
        index: { type: 'integer', description: 'Zero-based match to activate when several elements match; defaults to 0.' },
        button: { type: 'string', enum: ['left', 'right', 'middle'], description: 'Mouse button for the fallback click; defaults to left.' },
        double: { type: 'boolean', description: 'Double-click the element position instead of a single click.' },
        waitMs: {
          type: 'integer',
          description: 'How long to keep retrying until the element appears, in milliseconds; 0 checks once.',
        },
      },
      output: {
        schema: { type: 'json' },
        render: (args, value) => {
          const el = value.element
          return [
            {
              type: 'text',
              text: `Clicked "${el.name}" (${el.controlType || '?'}) via ${value.method} at ${el.centerX},${el.centerY}; ${value.matched} match(es), used index ${value.index}. Active window: ${windowLine(value.activeWindow)}.`,
            },
          ]
        },
      },
      async execute(args, exec) {
        guardInput()
        if (!args.text && !args.automationId) throw new Error('computer_click_text requires text or automationId')
        const request = { action: 'uiclick' }
        if (args.text !== undefined) request.text = args.text
        if (args.controlType !== undefined) request.controlType = args.controlType
        if (args.automationId !== undefined) request.automationId = args.automationId
        if (args.title !== undefined) request.windowTitle = args.title
        if (args.hwnd !== undefined) request.hwnd = args.hwnd
        if (args.index !== undefined) request.index = args.index
        if (args.button !== undefined) request.button = args.button
        if (args.double !== undefined) request.double = args.double
        if (args.waitMs !== undefined) request.waitMs = args.waitMs
        return runDesktop(request, config, exec.signal)
      },
    }),
  )

  ctx.tools.register(
    defineTool({
      name: 'computer_wait_for',
      description:
        'Wait until a window or a UI Automation element appears or disappears, instead of sleeping blindly. what=window matches a window by title substring or hwnd; what=element matches an accessible element by text within a scoped window. Returns matched=true with the found window or elements, or matched=false when the timeout elapses. Use it after computer_window launch to know the app is ready, before typing into a dialog, or to wait for a loading state to finish.' +
        PLATFORM_NOTE,
      parameters: {
        what: { type: 'string', required: true, enum: ['window', 'element'], description: 'What to wait for.' },
        state: {
          type: 'string',
          enum: ['appear', 'disappear'],
          description: 'Wait until the target appears (default) or disappears.',
        },
        title: { type: 'string', description: 'Window title substring: the window itself for what=window, or the search scope for what=element.' },
        hwnd: { type: 'integer', description: 'Window handle instead of a title.' },
        text: { type: 'string', description: 'For what=element: case-insensitive substring of the element name.' },
        controlType: { type: 'string', description: 'For what=element: exact UI Automation control type.' },
        timeoutMs: { type: 'integer', description: 'Maximum wait in milliseconds; defaults to 10000.' },
        intervalMs: { type: 'integer', description: 'Poll interval in milliseconds; defaults to 250.' },
      },
      output: {
        schema: { type: 'json' },
        render: (args, value) => {
          if (value.matched) {
            if (value.what === 'window') {
              return [{ type: 'text', text: `Window appeared after ${value.elapsedMs}ms: ${windowLine(value.window)}.` }]
            }
            const first = value.elements && value.elements.length ? ` first: ${elementLine(0, value.elements[0])}` : ''
            return [
              {
                type: 'text',
                text: `${value.count} element(s) matched after ${value.elapsedMs}ms${first}.`,
              },
            ]
          }
          return [
            {
              type: 'text',
              text: `Timed out after ${value.elapsedMs}ms waiting for ${value.what || 'window'} to ${value.state || 'appear'}. Check the name with computer_window list or computer_find_ui.`,
            },
          ]
        },
      },
      async execute(args, exec) {
        const request = { action: 'wait', what: args.what, state: args.state }
        if (args.title !== undefined) {
          request.title = args.title
          request.windowTitle = args.title
        }
        if (args.hwnd !== undefined) request.hwnd = args.hwnd
        if (args.text !== undefined) request.text = args.text
        if (args.controlType !== undefined) request.controlType = args.controlType
        if (args.timeoutMs !== undefined) request.timeoutMs = args.timeoutMs
        if (args.intervalMs !== undefined) request.intervalMs = args.intervalMs
        return runDesktop(request, config, exec.signal)
      },
    }),
  )

  ctx.tools.register(
    defineTool({
      name: 'computer_read_text',
      description:
        'Read the visible text of a window in one call instead of one screenshot at a time: it walks the UI Automation tree and returns the accessible names of labels, buttons, menu items, list items, tabs and status bars, plus the real content of documents and edits (via TextPattern/ValuePattern). Use it to understand a dialog, form, list, error message, or editor content as text; when the window has no accessibility tree (games, canvases) fall back to computer_screenshot plus read_image.' +
        PLATFORM_NOTE,
      parameters: {
        title: { type: 'string', description: 'Window title substring; omit to read the foreground window.' },
        hwnd: { type: 'integer', description: 'Exact window handle; preferred over title when known.' },
        maxChars: { type: 'integer', description: 'Maximum characters returned; defaults to 8000.' },
        limit: { type: 'integer', description: 'Maximum text blocks returned; defaults to 500.' },
        full: {
          type: 'boolean',
          description: 'Also include non-text controls such as panes and groups, prefixed with their control type. Defaults to false.',
        },
      },
      output: {
        schema: { type: 'json' },
        render: (args, value) => {
          const scope = value.scope ? `"${value.scope.title}"` : 'the foreground window'
          const note = value.truncated ? ' (truncated)' : ''
          return [
            {
              type: 'text',
              text: `Text of ${scope}, ${value.count} block(s)${note}:\n${value.text || '(no accessible text)'}`,
            },
          ]
        },
      },
      async execute(args, exec) {
        const request = { action: 'uitext' }
        if (args.title !== undefined) request.windowTitle = args.title
        if (args.hwnd !== undefined) request.hwnd = args.hwnd
        if (args.maxChars !== undefined) request.maxChars = args.maxChars
        if (args.limit !== undefined) request.limit = args.limit
        if (args.full !== undefined) request.full = args.full
        return runDesktop(request, config, exec.signal)
      },
    }),
  )

  ctx.tools.register(
    defineTool({
      name: 'computer_type_into',
      description:
        'Type or set text into the input control that matches a label, which is how you fill a form field without pixel coordinates. It finds an Edit/Document/ComboBox element whose accessible name contains label (or an exact automationId, or the first input of a kind), focuses it, and writes the value: it prefers UIA ValuePattern and verifies the read-back, falling back to focus plus Unicode typing with Ctrl+A. Use submit to press Enter afterwards, and waitMs to wait for the field to appear.' +
        PLATFORM_NOTE,
      parameters: {
        text: { type: 'string', required: true, description: 'The value to write into the control.' },
        label: { type: 'string', description: 'Case-insensitive substring of the target control name, for example "Search" or a field label.' },
        automationId: { type: 'string', description: 'Exact AutomationId of the input instead of a label.' },
        controlType: { type: 'string', description: 'Exact control type, for example Edit or ComboBox; omitting it accepts Edit, Document, ComboBox and Spinner.' },
        title: { type: 'string', description: 'Window title substring to focus and search within; omit to search the whole desktop.' },
        hwnd: { type: 'integer', description: 'Exact window handle; preferred over title when known.' },
        index: { type: 'integer', description: 'Zero-based match to use when several controls match; defaults to 0.' },
        method: {
          type: 'string',
          enum: ['auto', 'value', 'keyboard'],
          description: 'auto (default) tries ValuePattern then falls back to typing; value forces the UIA value pattern; keyboard focuses the control and types.',
        },
        selectAll: { type: 'boolean', description: 'For the keyboard path, select existing content with Ctrl+A before typing; defaults to true.' },
        submit: { type: 'boolean', description: 'Press Enter after writing the value.' },
        waitMs: { type: 'integer', description: 'How long to keep retrying until the control appears, in milliseconds; 0 checks once.' },
      },
      output: {
        schema: { type: 'json' },
        render: (args, value) => {
          const el = value.element
          const after = value.valueAfter === null || value.valueAfter === undefined ? '(unreadable)' : JSON.stringify(value.valueAfter)
          return [
            {
              type: 'text',
              text: `Wrote ${args.text.length} character(s) into "${el.name}" (${el.controlType || '?'}) using ${value.method}${value.submitted ? ', then pressed Enter' : ''}. Value now: ${after}. ${value.matched} match(es), used index ${value.index}.`,
            },
          ]
        },
      },
      async execute(args, exec) {
        guardInput()
        if (typeof args.text !== 'string') throw new Error('computer_type_into requires text')
        if (!args.label && !args.automationId && !args.controlType) {
          throw new Error('computer_type_into requires label, automationId, or controlType to locate the input')
        }
        const request = { action: 'uiset', value: args.text }
        if (args.label !== undefined) request.label = args.label
        if (args.automationId !== undefined) request.automationId = args.automationId
        if (args.controlType !== undefined) request.controlType = args.controlType
        if (args.title !== undefined) request.windowTitle = args.title
        if (args.hwnd !== undefined) request.hwnd = args.hwnd
        if (args.index !== undefined) request.index = args.index
        if (args.method !== undefined) request.method = args.method
        if (args.selectAll !== undefined) request.selectAll = args.selectAll
        if (args.submit !== undefined) request.submit = args.submit
        if (args.waitMs !== undefined) request.waitMs = args.waitMs
        return runDesktop(request, config, exec.signal)
      },
    }),
  )
}
