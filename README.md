# Computer Use 插件（Windows 桌面控制）

> English summary: a Windows-only computer-use plugin for DeepSeek Harness. It exposes screenshot, mouse, keyboard, and window control, plus UI Automation helpers that find, click, read, and fill controls by their accessible text. Implemented with Windows PowerShell + user32 `SendInput`/`CopyFromScreen` + UI Automation, with no native Node modules and no build step.

给 DeepSeek Harness 提供「操作真实桌面」能力的插件：截屏、鼠标、键盘、窗口管理，以及按文字定位控件、点击、等待、读窗口文本、往输入框写内容等高层封装，共 9 个模型工具。
纯 Windows 原生实现（Windows PowerShell + user32 `SendInput`/`CopyFromScreen` + UI Automation），不依赖 Node 原生模块，无需编译。

```
computer-use-plugin/
├── package.json      # bundle 声明（dsh.bundle.patch）+ peer 依赖
├── cordis.patch.yml  # 插入 computer-use 插件条目及配置
├── lib/index.js      # 插件主体：注册 9 个工具、调用桌面助手
└── lib/desktop.ps1   # 桌面助手：一次调用一个进程，JSON 进 / JSON 出
```

## 安装

把本目录放在任意位置，然后在 DeepSeek Harness 中安装：

```
plugin_manager  action: install_bundle  target: "<本目录的绝对路径>"
```

安装后 `computer_*` 工具对所有会话生效。卸载可在 Plugins 页面移除，或执行
`dsh plugin --profile <profile> remove @local/dsh-computer-use`。

本插件只支持 Windows；其他平台上工具注册成功，但每项操作都会返回平台不支持的说明。

## 工具

### `computer_screenshot`
截取桌面（或指定区域）到 PNG，返回路径、图像尺寸、屏幕区域、**缩放比例**、显示器布局、光标位置、前台窗口。

```json
{ "maxWidth": 1280 }
{ "region": { "x": 0, "y": 0, "width": 1280, "height": 800 }, "path": "C:\\tmp\\shot.png" }
```

模型拿到路径后用 `read_image` 查看。**关键**：`read_image` 里的坐标 × `scaleX` / `scaleY` 才是屏幕物理像素坐标。

### `computer_mouse`
`move` / `click` / `double_click` / `right_click` / `middle_click` / `drag` / `scroll`，坐标一律是**屏幕物理像素**。

```json
{ "action": "click", "x": 960, "y": 540 }
{ "action": "drag", "x": 100, "y": 200, "toX": 400, "toY": 200 }
{ "action": "scroll", "x": 960, "y": 540, "amount": -3 }
```

### `computer_keyboard`
- `type`：逐字符 Unicode 输入，中文/繁体/日文均可（走 SendInput KEYEVENTF_UNICODE）
- `paste`：写入剪贴板后 Ctrl+V，长文本、emoji 更稳
- `press`：单键，如 `"enter"`、`"f5"`、`"escape"`
- `hotkey`：组合键，如 `["ctrl","shift","esc"]`、`["alt","tab"]`

```json
{ "action": "type", "text": "你好，这是一段测试\n第二行" }
{ "action": "hotkey", "keys": ["ctrl", "s"] }
```

### `computer_window`
`list` / `active` / `focus` / `minimize` / `maximize` / `restore` / `close` / `launch`。

```json
{ "action": "list" }
{ "action": "focus", "title": "记事本" }
{ "action": "close", "hwnd": 2099222 }
{ "action": "launch", "command": "notepad.exe" }
{ "action": "launch", "command": "explorer.exe", "arguments": "https://example.com" }
```

`launch` 会等待新窗口出现并尝试置前；`focus` 返回 `focused` 真实结果，置前失败时会带 `warning`。
目标窗口可用 `hwnd`（精确）或 `title`（不区分大小写的子串匹配）。

### `computer_find_ui` —— 按名字找控件（不靠像素）
用 Windows UI Automation 枚举窗口（或整个桌面）里的控件：按钮、菜单项、标签页、输入框、列表项、文档文本等，返回名称、控件类型、AutomationId、矩形与中心坐标。

```json
{ "title": "记事本" }
{ "title": "DeepSeek Harness", "text": "插件", "limit": 10 }
{ "text": "保存", "controlType": "Button" }
```

常用 `controlType`：`Button`、`MenuItem`、`Edit`、`Document`、`TabItem`、`ListItem`、`Text`、`ComboBox`、`CheckBox`、`Window`。

### `computer_click_text` —— 按文字点击
先聚焦目标窗口，再按文字（可选控件类型 / AutomationId / 序号）定位元素并激活。优先走 UIA 的 Invoke / SelectionItem / ExpandCollapse / Toggle 模式（比点像素可靠得多），都不支持时才回退到点击元素中心。`waitMs` 让它在元素出现前反复重试。

```json
{ "title": "记事本", "text": "编辑", "controlType": "MenuItem" }
{ "title": "设置", "text": "保存", "controlType": "Button", "waitMs": 5000 }
{ "text": "确定", "controlType": "Button", "index": 1 }
```

### `computer_wait_for` —— 等待出现/消失
不再盲等 `sleep`：等到某个窗口或某个控件出现（或消失）为止，返回 `matched`、耗时与命中的窗口/元素。

```json
{ "what": "window", "title": "另存为", "timeoutMs": 8000 }
{ "what": "window", "title": "加载中", "state": "disappear", "timeoutMs": 15000 }
{ "what": "element", "title": "设置", "text": "保存", "controlType": "Button", "timeoutMs": 5000 }
```

### `computer_read_text` —— 一次读完整窗口文本
不用一张张截图：遍历 UI Automation 树，返回标签、按钮、菜单项、列表项、状态栏的可访问名称，并用 TextPattern/ValuePattern 取到文档与输入框的**真实内容**。适合读对话框、表单、列表、报错信息、编辑器内容。

```json
{ "title": "记事本", "maxChars": 4000 }
{ "title": "设置" }
{ "title": "DeepSeek Harness", "full": true }
```

### `computer_type_into` —— 按文字往输入框写内容
按标签（或 AutomationId / 控件类型）定位 Edit/Document/ComboBox，聚焦后写入值：优先用 UIA `ValuePattern` 并**回读校验**，失败则回退到聚焦 + Unicode 输入（可先 Ctrl+A 全选覆盖）。`submit` 可在写完按回车，`waitMs` 可等输入框出现。

```json
{ "title": "查找", "label": "查找", "controlType": "Edit", "text": "A-1024" }
{ "title": "登录", "label": "用户名", "text": "test@example.com" }
{ "title": "登录", "label": "密码", "text": "secret", "submit": true }
```

> 清空输入框：`text` 传空字符串 `""`（配合 `selectAll: true`）。

## 推荐工作流

1. `computer_screenshot` 看屏幕 → `read_image` 看图片，同时拿到 `scaleX/scaleY` 与前台窗口
2. **文本场景优先走 UIA**：`computer_read_text` 快速读懂界面文字 → `computer_find_ui` 确认控件名 → `computer_click_text` 点击 / `computer_type_into` 填表 → `computer_wait_for` 等弹窗或加载结束
3. 走不通（游戏、画布、远程桌面、无 UIA 的界面）再回退像素：`computer_window focus` → `computer_mouse` 坐标点击 / `computer_keyboard` 输入
4. 操作后再截一次图或 `computer_read_text` 确认结果

## 配置（`cordis.patch.yml`）

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `screenshotDir` | 空 | 截图目录，空则用系统临时目录 `%TEMP%\dsh-computer-use\screenshots` |
| `maxImageWidth` | `1600` | 截图默认下采样宽度，`0` 表示保持原生分辨率 |
| `allowInput` | `true` | 设为 `false` 后只保留截图与窗口查看，禁用鼠标键盘注入与 `launch` |
| `timeoutMs` | `30000` | 单次桌面动作超时 |
| `powershell` | 空 | 指定 powershell.exe 路径，空则用系统 Windows PowerShell |

改完 patch 后保存即热重载；改 `lib/index.js` 需要重载插件（见下方「调试」）。

## 安全与限制

- **UIPI / 管理员窗口**：本插件以 DSH 进程权限运行。若目标窗口以管理员身份运行（UAC 提升），Windows 会拒绝注入输入，`focus` 返回 `focused: false` 或按键无效。需要控制管理员程序时，请以管理员身份启动 DSH。
- **UAC 安全桌面、锁屏、登录界面** 无法截图或操作，这是系统设计，不是插件缺陷。
- **中文/全角/emoji**：`type` 用 Unicode SendInput；少数应用对合成输入不友好（例如终端、部分游戏），改用 `paste`。
- **性能**：每个动作启动一次无状态 PowerShell 子进程，实测约 0.6–1.3 秒；连续操作建议合并参数减少调用次数。UIA 搜索是进程内完成，窗口范围通常 < 0.5 秒，但在**整个桌面**范围枚举约 3 万个元素、需 5 秒左右，建议总是带 `title`/`hwnd` 限定窗口。
- **多显示器/高 DPI**：助手进程声明 DPI 感知，截图与鼠标坐标统一为物理像素；`scaleX` / `scaleY` 用于换算 `read_image` 的预览坐标。
- **UI Automation 覆盖面**：Win32 / WinForms / WPF / Qt / Electron 与 Chromium（Chrome、Edge、DSH 本体）/ Office / 大部分 UWP 应用都能枚举到控件；游戏、视频画布、远程桌面、自绘界面通常没有控件树，`computer_find_ui` 会返回 0 个元素——此时回退到「截图 + 坐标」。
- **UWP 窗口例外**：个别系统应用（如「设置」）的外层是 `ApplicationFrameWindow`，通过窗口句柄取不到子树，此时 `computer_find_ui` 可能为空，改用截图定位。
- **模式优先**：`computer_click_text` 优先用 UIA 的 Invoke/Select/Expand/Toggle，不移动鼠标也不会误点到别处；只有在元素不支持任何模式时才回退成鼠标点击元素中心，返回的 `method` 字段会告诉你实际用了哪种。

## 调试

直接跑桌面助手，绕过 DSH：

```powershell
$req = "$env:TEMP\req.json"; $res = "$env:TEMP\res.json"
'{"action":"info"}' | Set-Content -LiteralPath $req -Encoding UTF8
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\lib\desktop.ps1 -RequestFile $req -ResultFile $res
Get-Content -LiteralPath $res -Raw
```

支持的 `action`：`screenshot`、`mouse`、`keyboard`、`window`、`ui`、`uiclick`、`wait`、`uitext`、`uiset`、`info`（字段含义见 `lib/desktop.ps1` 顶部 C# 声明与各分支）。

改完 `lib/index.js` 后需要重载插件才生效（link 安装不会监听 `lib/` 文件变化），最快的重载方式：
在 Plugin Manager 里把本 bundle 关开一次（`set_bundle(enabled:false)` 再 `set_bundle(enabled:true)`），或改一下 `cordis.patch.yml` 里的 config 触发配置层重载。
`lib/desktop.ps1` 每次调用都重新读取，改完即生效、无需重载。

## 开发验证记录（作者本机实测）

- `info` / `screenshot`（全屏、区域、maxWidth 下采样且 scale 正确）✅
- `window`：list / active / focus（含 `AttachThreadInput` 置前）/ launch / close / minimize ✅
- `mouse`：move / click / drag（窗口实测位移 +100,+100）/ scroll ✅
- `keyboard`：type（中文「中文测试」、繁体「繁體」、ASCII、符号）/ press / hotkey（ctrl+a、alt+n）✅
- 端到端：启动记事本 → 置前 → 输入中文 → 区域截图 → 关闭不保存 ✅
- `ui`：记事本窗口找到 12 个控件（文件/编辑/查看菜单、加粗、斜体、文本编辑器、标签页…）；DeepSeek Harness（Electron）找到侧边栏/标题栏按钮，中文名正确 ✅
- `uiclick`：按文字「编辑」+`MenuItem` 命中记事本菜单项，走 `invoke` 模式，菜单被真实展开 ✅；桌面 `Program Manager` 走 `mouse` 回退点击 ✅
- `wait`：窗口出现 71ms 命中；元素出现 226ms 命中；不存在目标 1.3s 后按超时返回 `matched=false` ✅
- `uitext`：记事本 31 个文本块（含文档正文三行、菜单、状态栏、查找栏内容）✅；DeepSeek Harness 30 个文本块（侧栏、会话标题、输入框内容）✅
- `uiset`：记事本「查找」输入框按标签命中并写入，回读 `A-1024 测试` 一致 ✅；记事本文档按 `Document` 全量替换并回读一致 ✅；DSH 输入框按标签写入 34 字并回读一致（走 keyboard 回退路径）✅

### 已修复

- 窗口枚举用的 C# 回调曾是临时委托，可能被 GC 回收导致**窗口列表间歇性漏窗**（表现为 `no window matching ...`、`no matching input control found`）。现已改为静态字段持有回调，连续多次 `list` 结果稳定（7/7/7），基于窗口的查找恢复正常。

## 许可证

MIT，见 [LICENSE](LICENSE)。
