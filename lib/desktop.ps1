param(
    [Parameter(Mandatory = $true)][string]$RequestFile,
    [Parameter(Mandatory = $true)][string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class CuWindow
{
    public long Hwnd { get; set; }
    public string Title { get; set; }
    public int Pid { get; set; }
    public string Process { get; set; }
    public int X { get; set; }
    public int Y { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public bool Minimized { get; set; }
}

public static class CuNative
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    /** Rooted window-enumeration callback; see ListTopWindows. */
    private static EnumProc _enumCallback;

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, [Out] StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] public static extern bool SwitchToThisWindow(IntPtr h, bool alt);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint data, IntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr e);

    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    public struct INPUT64
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Explicit, Size = 28)]
    public struct INPUT32
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(4)] public KEYBDINPUT ki;
    }

    [DllImport("user32.dll", EntryPoint = "SendInput")]
    public static extern uint SendInput64(uint n, INPUT64[] p, int cb);

    [DllImport("user32.dll", EntryPoint = "SendInput")]
    public static extern uint SendInput32(uint n, INPUT32[] p, int cb);

    public const int SM_XVIRTUALSCREEN = 76;
    public const int SM_YVIRTUALSCREEN = 77;
    public const int SM_CXVIRTUALSCREEN = 78;
    public const int SM_CYVIRTUALSCREEN = 79;

    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    public static void Init()
    {
        SetProcessDPIAware();
    }

    public static CuWindow Describe(IntPtr h)
    {
        CuWindow w = new CuWindow();
        w.Hwnd = h.ToInt64();
        w.Minimized = IsIconic(h);
        int len = GetWindowTextLengthW(h);
        StringBuilder sb = new StringBuilder(len + 2);
        GetWindowTextW(h, sb, sb.Capacity);
        w.Title = sb.ToString();
        int pid = 0;
        GetWindowThreadProcessId(h, out pid);
        w.Pid = pid;
        w.Process = "";
        try { w.Process = System.Diagnostics.Process.GetProcessById(pid).ProcessName; }
        catch { }
        RECT r;
        if (GetWindowRect(h, out r))
        {
            w.X = r.Left;
            w.Y = r.Top;
            w.Width = r.Right - r.Left;
            w.Height = r.Bottom - r.Top;
        }
        return w;
    }

    public static CuWindow[] ListTopWindows()
    {
        List<CuWindow> list = new List<CuWindow>();
        // The callback is kept in a static field: a temporary delegate can be garbage
        // collected while native code is still calling it, which silently truncates
        // the window list and made windows intermittently invisible to every action.
        _enumCallback = delegate(IntPtr h, IntPtr p)
        {
            if (!IsWindowVisible(h)) return true;
            CuWindow w = Describe(h);
            if (w.Title.Length == 0) return true;
            if (w.Width <= 0 || w.Height <= 0) return true;
            if (w.Title == "Program Manager") return true;
            list.Add(w);
            return true;
        };
        EnumWindows(_enumCallback, IntPtr.Zero);
        return list.ToArray();
    }

    public static CuWindow Active()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return null;
        return Describe(h);
    }

    public static CuWindow Find(string spec)
    {
        if (spec == null) return null;
        spec = spec.Trim();
        if (spec.Length == 0) return null;
        long direct = 0;
        if (long.TryParse(spec, out direct))
        {
            IntPtr h = new IntPtr(direct);
            if (IsWindowVisible(h)) return Describe(h);
        }
        CuWindow[] all = ListTopWindows();
        foreach (CuWindow w in all)
        {
            if (w.Title.Equals(spec, StringComparison.OrdinalIgnoreCase)) return w;
        }
        foreach (CuWindow w in all)
        {
            if (w.Title.IndexOf(spec, StringComparison.OrdinalIgnoreCase) >= 0) return w;
        }
        return null;
    }

    public static bool Focus(long hwnd)
    {
        IntPtr h = new IntPtr(hwnd);
        uint mine = GetCurrentThreadId();
        int pid = 0;
        uint targetThread = GetWindowThreadProcessId(h, out pid);
        IntPtr fg = GetForegroundWindow();
        uint fgThread = (fg != IntPtr.Zero) ? GetWindowThreadProcessId(fg, out pid) : 0;

        bool attachedTarget = false;
        if (targetThread != 0 && targetThread != mine) attachedTarget = AttachThreadInput(mine, targetThread, true);
        bool attachedFg = false;
        if (fgThread != 0 && fgThread != mine && fgThread != targetThread) attachedFg = AttachThreadInput(mine, fgThread, true);

        if (IsIconic(h)) ShowWindow(h, 9);
        ShowWindow(h, 5);
        bool ok = SetForegroundWindow(h);
        if (!ok)
        {
            keybd_event(0x12, 0, 0, IntPtr.Zero);
            keybd_event(0x12, 0, KEYEVENTF_KEYUP, IntPtr.Zero);
            ok = SetForegroundWindow(h);
        }
        if (!ok)
        {
            SwitchToThisWindow(h, true);
        }
        BringWindowToTop(h);
        SetActiveWindow(h);
        SetFocus(h);

        if (attachedFg) AttachThreadInput(mine, fgThread, false);
        if (attachedTarget) AttachThreadInput(mine, targetThread, false);

        return GetForegroundWindow() == h;
    }

    public static bool Close(long hwnd)
    {
        return PostMessageW(new IntPtr(hwnd), 0x0010, IntPtr.Zero, IntPtr.Zero);
    }

    public static bool Minimize(long hwnd) { return ShowWindow(new IntPtr(hwnd), 6); }
    public static bool Maximize(long hwnd) { return ShowWindow(new IntPtr(hwnd), 3); }
    public static bool Restore(long hwnd) { return ShowWindow(new IntPtr(hwnd), 9); }

    public static int[] VirtualScreen()
    {
        int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        return new int[] { x, y, w, h };
    }

    public static int[] Cursor()
    {
        POINT p;
        if (GetCursorPos(out p)) return new int[] { p.X, p.Y };
        return new int[] { 0, 0 };
    }

    public static void MoveTo(int x, int y)
    {
        int[] vs = VirtualScreen();
        int vw = vs[2] > 1 ? vs[2] - 1 : 1;
        int vh = vs[3] > 1 ? vs[3] - 1 : 1;
        double nx = ((double)(x - vs[0]) * 65535.0) / vw;
        double ny = ((double)(y - vs[1]) * 65535.0) / vh;
        mouse_event(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, (int)Math.Round(nx), (int)Math.Round(ny), 0, IntPtr.Zero);
    }

    private static void Press(string button, bool down)
    {
        uint f = MOUSEEVENTF_LEFTDOWN;
        if (button == "right") f = MOUSEEVENTF_RIGHTDOWN;
        else if (button == "middle") f = MOUSEEVENTF_MIDDLEDOWN;
        if (!down)
        {
            if (f == MOUSEEVENTF_LEFTDOWN) f = MOUSEEVENTF_LEFTUP;
            else if (f == MOUSEEVENTF_RIGHTDOWN) f = MOUSEEVENTF_RIGHTUP;
            else f = MOUSEEVENTF_MIDDLEUP;
        }
        mouse_event(f, 0, 0, 0, IntPtr.Zero);
    }

    public static void Click(string button, int count)
    {
        for (int i = 0; i < count; i++)
        {
            Press(button, true);
            System.Threading.Thread.Sleep(25);
            Press(button, false);
            if (i + 1 < count) System.Threading.Thread.Sleep(60);
        }
    }

    public static void Drag(int x1, int y1, int x2, int y2)
    {
        MoveTo(x1, y1);
        System.Threading.Thread.Sleep(40);
        Press("left", true);
        System.Threading.Thread.Sleep(60);
        int steps = 18;
        for (int i = 1; i <= steps; i++)
        {
            int x = x1 + (x2 - x1) * i / steps;
            int y = y1 + (y2 - y1) * i / steps;
            MoveTo(x, y);
            System.Threading.Thread.Sleep(12);
        }
        System.Threading.Thread.Sleep(60);
        Press("left", false);
    }

    public static void Wheel(int notches)
    {
        mouse_event(MOUSEEVENTF_WHEEL, 0, 0, unchecked((uint)(notches * 120)), IntPtr.Zero);
    }

    public static void KeyDown(int vk) { keybd_event((byte)vk, 0, 0, IntPtr.Zero); }
    public static void KeyUp(int vk) { keybd_event((byte)vk, 0, KEYEVENTF_KEYUP, IntPtr.Zero); }

    public static void TypeChar(int code)
    {
        ushort ch = (ushort)code;
        if (IntPtr.Size == 8)
        {
            INPUT64[] a = new INPUT64[2];
            a[0].type = 1;
            a[0].ki.wVk = 0;
            a[0].ki.wScan = ch;
            a[0].ki.dwFlags = KEYEVENTF_UNICODE;
            a[1] = a[0];
            a[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            SendInput64(2, a, Marshal.SizeOf(typeof(INPUT64)));
        }
        else
        {
            INPUT32[] a = new INPUT32[2];
            a[0].type = 1;
            a[0].ki.wVk = 0;
            a[0].ki.wScan = ch;
            a[0].ki.dwFlags = KEYEVENTF_UNICODE;
            a[1] = a[0];
            a[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            SendInput32(2, a, Marshal.SizeOf(typeof(INPUT32)));
        }
    }

    public static void TypeText(string text)
    {
        foreach (char c in text)
        {
            if (c == '\r') continue;
            if (c == '\n') { KeyDown(0x0D); KeyUp(0x0D); continue; }
            if (c == '\t') { KeyDown(0x09); KeyUp(0x09); continue; }
            TypeChar(c);
        }
    }
}
'@

function Write-Result($obj) {
    $json = $obj | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::WriteAllText($ResultFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-WinDict($w) {
    if ($null -eq $w) { return $null }
    return [ordered]@{
        hwnd      = $w.Hwnd
        title     = $w.Title
        pid       = $w.Pid
        process   = $w.Process
        x         = $w.X
        y         = $w.Y
        width     = $w.Width
        height    = $w.Height
        minimized = $w.Minimized
    }
}

function Resolve-TargetWindow($req) {
    if ($null -ne $req.hwnd) {
        return [CuNative]::Describe((New-Object System.IntPtr([long]$req.hwnd)))
    }
    $label = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$req.title)) { $label = [string]$req.title }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$req.windowTitle)) { $label = [string]$req.windowTitle }
    if ($label -ne '') {
        return [CuNative]::Find($label)
    }
    throw 'provide title or hwnd'
}

$VK = @{
    'backspace' = 8; 'tab' = 9; 'enter' = 13; 'return' = 13; 'shift' = 16; 'ctrl' = 17; 'control' = 17;
    'alt' = 18; 'pause' = 19; 'capslock' = 20; 'esc' = 27; 'escape' = 27; 'space' = 32; 'pageup' = 33; 'pgup' = 33;
    'pagedown' = 34; 'pgdn' = 34; 'end' = 35; 'home' = 36; 'left' = 37; 'up' = 38; 'right' = 39; 'down' = 40;
    'printscreen' = 44; 'insert' = 45; 'ins' = 45; 'delete' = 46; 'del' = 46; 'win' = 91; 'windows' = 91; 'meta' = 91;
    'numlock' = 144; 'scrolllock' = 145;
    ';' = 186; '=' = 187; ',' = 188; '-' = 189; '.' = 190; '/' = 191; '`' = 192; '[' = 219; '\' = 220; ']' = 221; "'" = 222;
    'plus' = 187; 'minus' = 189
}

function Resolve-VK([string]$key) {
    $k = $key.Trim().ToLowerInvariant()
    if ($VK.ContainsKey($k)) { return [int]$VK[$k] }
    if ($k.Length -eq 1) {
        $c = [char]$k[0]
        if ($c -ge 'a' -and $c -le 'z') { return [int][char]([char]::ToUpperInvariant($c)) }
        if ($c -ge '0' -and $c -le '9') { return [int][char]$c }
    }
    if ($k -match '^f([1-9]|1[0-9]|2[0-4])$') { return 111 + [int]$Matches[1] }
    if ($k -match '^numpad([0-9])$') { return 96 + [int]$Matches[1] }
    throw "unknown key name: $key"
}

# ---------------------------------------------------------------------------
# UI Automation helpers: locate and operate on real UI elements by their
# accessible name, control type, or automation id instead of raw pixels.
# ---------------------------------------------------------------------------
$script:UiaReady = $false

function Initialize-Uia {
    if ($script:UiaReady) { return }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $script:UiaReady = $true
}

function New-UiCache {
    $cache = New-Object System.Windows.Automation.CacheRequest
    $props = @(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
        [System.Windows.Automation.AutomationElement]::BoundingRectangleProperty,
        [System.Windows.Automation.AutomationElement]::IsEnabledProperty,
        [System.Windows.Automation.AutomationElement]::IsOffscreenProperty
    )
    foreach ($p in $props) { [void]$cache.Add($p) }
    return $cache
}

function Get-UiRoot($req) {
    Initialize-Uia
    if ($null -ne $req.hwnd) {
        return [System.Windows.Automation.AutomationElement]::FromHandle((New-Object System.IntPtr([long]$req.hwnd)))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$req.windowTitle)) {
        $w = [CuNative]::Find([string]$req.windowTitle)
        if ($null -eq $w) { throw "no window matching '$([string]$req.windowTitle)'" }
        return [System.Windows.Automation.AutomationElement]::FromHandle((New-Object System.IntPtr([long]$w.Hwnd)))
    }
    return [System.Windows.Automation.AutomationElement]::RootElement
}

function Get-UiRecord($el) {
    $c = $el.Cached
    $controlType = ''
    try { $controlType = [string]$c.ControlType.ProgrammaticName -replace '^ControlType\.', '' } catch { }
    $rec = [ordered]@{
        name         = [string]$c.Name
        controlType  = $controlType
        automationId = [string]$c.AutomationId
        className    = [string]$c.ClassName
        enabled      = [bool]$c.IsEnabled
        offscreen    = [bool]$c.IsOffscreen
        x            = 0
        y            = 0
        width        = 0
        height       = 0
        centerX      = 0
        centerY      = 0
    }
    try {
        $r = $c.BoundingRectangle
        if ($null -ne $r -and -not $r.IsEmpty -and $r.Width -gt 0 -and $r.Height -gt 0) {
            $rec.x = [int]$r.X
            $rec.y = [int]$r.Y
            $rec.width = [int]$r.Width
            $rec.height = [int]$r.Height
            $rec.centerX = [int]($r.X + ($r.Width / 2))
            $rec.centerY = [int]($r.Y + ($r.Height / 2))
        }
    } catch { }
    return $rec
}

function Find-UiMatches($req) {
    $root = Get-UiRoot $req
    $cache = New-UiCache
    $cache.Push()
    try {
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    }
    finally {
        $cache.Pop()
    }

    $needle = ''
    if ($null -ne $req.text) { $needle = ([string]$req.text).Trim().ToLowerInvariant() }
    $typeNeed = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$req.controlType)) { $typeNeed = ([string]$req.controlType).Trim().ToLowerInvariant() }
    $idNeed = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$req.automationId)) { $idNeed = ([string]$req.automationId).Trim().ToLowerInvariant() }
    $includeOffscreen = $false
    if ($null -ne $req.includeOffscreen) { $includeOffscreen = [bool]$req.includeOffscreen }
    $includeUnnamed = $false
    if ($null -ne $req.includeUnnamed) { $includeUnnamed = [bool]$req.includeUnnamed }
    $limit = 40
    if ($null -ne $req.limit -and [int]$req.limit -gt 0) { $limit = [int]$req.limit }

    $found = New-Object System.Collections.ArrayList
    foreach ($el in $all) {
        $rec = $null
        try { $rec = Get-UiRecord $el } catch { continue }
        if ($needle -ne '' -and $rec.name.ToLowerInvariant().IndexOf($needle) -lt 0) { continue }
        if ($needle -eq '' -and -not $includeUnnamed -and $rec.name.Trim() -eq '') { continue }
        if ($typeNeed -ne '' -and $rec.controlType.ToLowerInvariant() -ne $typeNeed) { continue }
        if ($idNeed -ne '' -and $rec.automationId.ToLowerInvariant() -ne $idNeed) { continue }
        if (-not $includeOffscreen -and $rec.offscreen) { continue }
        if ($rec.width -le 0 -or $rec.height -le 0) { continue }
        [void]$found.Add([pscustomobject]@{ Live = $el; Record = $rec })
        if ($found.Count -ge $limit) { break }
    }
    return $found.ToArray()
}

function Invoke-UiElement($el, [string]$button, [bool]$double) {
    $patterns = @(
        @{ Pattern = [System.Windows.Automation.InvokePattern]::Pattern; Method = 'invoke' },
        @{ Pattern = [System.Windows.Automation.SelectionItemPattern]::Pattern; Method = 'select' },
        @{ Pattern = [System.Windows.Automation.ExpandCollapsePattern]::Pattern; Method = 'expand' },
        @{ Pattern = [System.Windows.Automation.TogglePattern]::Pattern; Method = 'toggle' }
    )
    foreach ($entry in $patterns) {
        $obj = $null
        $has = $false
        try { $has = $el.TryGetCurrentPattern($entry.Pattern, [ref]$obj) } catch { $has = $false }
        if (-not $has -or $null -eq $obj) { continue }
        try {
            switch ($entry.Method) {
                'select' { $obj.Select() }
                'expand' { $obj.Expand() }
                'toggle' { $obj.Toggle() }
                default { $obj.Invoke() }
            }
            Start-Sleep -Milliseconds 120
            return $entry.Method
        }
        catch { }
    }

    $scroll = $null
    try {
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scroll)) { $scroll.ScrollIntoView() }
    }
    catch { }
    $r = $el.Current.BoundingRectangle
    if ($null -eq $r -or $r.IsEmpty) { throw 'matched element has no clickable rectangle' }
    $cx = [int]($r.X + ($r.Width / 2))
    $cy = [int]($r.Y + ($r.Height / 2))
    [CuNative]::MoveTo($cx, $cy)
    Start-Sleep -Milliseconds 60
    [CuNative]::Click($button, $(if ($double) { 2 } else { 1 }))
    Start-Sleep -Milliseconds 120
    return 'mouse'
}

function Get-UiElementValue($el, [int]$maxChars = 4000) {
    $vp = $null
    try {
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
            $v = [string]$vp.Current.Value
            if ($v.Length -gt $maxChars) { $v = $v.Substring(0, $maxChars) }
            return $v
        }
    }
    catch { }
    $tp = $null
    try {
        if ($el.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$tp)) {
            $v = [string]$tp.DocumentRange.GetText($maxChars)
            return $v
        }
    }
    catch { }
    return $null
}

function Find-UiInputMatches($req) {
    $root = Get-UiRoot $req
    $cache = New-UiCache
    $cache.Push()
    try {
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    }
    finally {
        $cache.Pop()
    }

    $needle = ''
    if ($null -ne $req.label) { $needle = ([string]$req.label).Trim().ToLowerInvariant() }
    $idNeed = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$req.automationId)) { $idNeed = ([string]$req.automationId).Trim().ToLowerInvariant() }
    $typeNeed = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$req.controlType)) { $typeNeed = ([string]$req.controlType).Trim().ToLowerInvariant() }
    if ($typeNeed -eq '') { $typeNeed = '' }
    $allowType = $false
    if ($typeNeed -ne '') { $allowType = $true }
    $limit = 20
    if ($null -ne $req.limit -and [int]$req.limit -gt 0) { $limit = [int]$req.limit }

    $inputTypes = @('Edit', 'Document', 'ComboBox', 'Spinner')
    $found = New-Object System.Collections.ArrayList
    foreach ($el in $all) {
        $rec = $null
        try { $rec = Get-UiRecord $el } catch { continue }
        if ($idNeed -ne '') {
            if ($rec.automationId.ToLowerInvariant() -ne $idNeed) { continue }
        }
        else {
            if ($needle -ne '' -and $rec.name.ToLowerInvariant().IndexOf($needle) -lt 0) { continue }
            if ($needle -eq '' -and $allowType -eq $false) { continue }
        }
        if ($allowType) {
            if ($rec.controlType.ToLowerInvariant() -ne $typeNeed) { continue }
        }
        else {
            if ($inputTypes -notcontains $rec.controlType) { continue }
        }
        if ($rec.offscreen) { continue }
        if ($rec.width -le 0 -or $rec.height -le 0) { continue }
        [void]$found.Add([pscustomobject]@{ Live = $el; Record = $rec })
        if ($found.Count -ge $limit) { break }
    }
    return $found.ToArray()
}

try {
    Add-Type -TypeDefinition $src -Language CSharp
    [CuNative]::Init()
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms

    $req = Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $action = [string]$req.action
    $data = $null

    switch ($action) {
        'screenshot' {
            $vs = [CuNative]::VirtualScreen()
            $x = $vs[0]; $y = $vs[1]; $w = $vs[2]; $h = $vs[3]
            if ($null -ne $req.region) {
                $x = [int]$req.region.x; $y = [int]$req.region.y
                $w = [int]$req.region.width; $h = [int]$req.region.height
            }
            if ($w -le 0 -or $h -le 0) { throw "invalid capture region ${w}x${h}" }
            $bmp = New-Object System.Drawing.Bitmap($w, $h)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
            $g.Dispose()

            $scaleX = 1.0; $scaleY = 1.0
            $maxW = 0
            if ($null -ne $req.maxWidth) { $maxW = [int]$req.maxWidth }
            if ($maxW -gt 0 -and $w -gt $maxW) {
                $sw = $maxW
                $sh = [int][math]::Round($h * $maxW / $w)
                $res = New-Object System.Drawing.Bitmap($sw, $sh)
                $rg = [System.Drawing.Graphics]::FromImage($res)
                $rg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $rg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $rg.DrawImage($bmp, 0, 0, $sw, $sh)
                $rg.Dispose()
                $bmp.Dispose()
                $bmp = $res
                $scaleX = [double]$w / [double]$sw
                $scaleY = [double]$h / [double]$sh
            }

            $path = [string]$req.path
            if ([string]::IsNullOrWhiteSpace($path)) { throw "screenshot requires a path" }
            $dir = [System.IO.Path]::GetDirectoryName($path)
            if (-not [string]::IsNullOrEmpty($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
            $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $ow = $bmp.Width; $oh = $bmp.Height
            $bmp.Dispose()

            $monitors = @()
            foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
                $monitors += [ordered]@{
                    device  = $s.DeviceName
                    primary = $s.Primary
                    x       = $s.Bounds.X
                    y       = $s.Bounds.Y
                    width   = $s.Bounds.Width
                    height  = $s.Bounds.Height
                }
            }
            $cur = [CuNative]::Cursor()
            $data = [ordered]@{
                path          = $path
                imageWidth    = $ow
                imageHeight   = $oh
                screenX       = $x
                screenY       = $y
                screenWidth   = $w
                screenHeight  = $h
                scaleX        = [math]::Round($scaleX, 4)
                scaleY        = [math]::Round($scaleY, 4)
                virtualScreen = [ordered]@{ x = $vs[0]; y = $vs[1]; width = $vs[2]; height = $vs[3] }
                monitors      = $monitors
                cursor        = [ordered]@{ x = $cur[0]; y = $cur[1] }
                activeWindow  = Get-WinDict ([CuNative]::Active())
            }
        }
        'mouse' {
            $ma = [string]$req.mouseAction
            $button = 'left'
            if ($null -ne $req.button) { $button = ([string]$req.button).ToLowerInvariant() }
            switch ($ma) {
                'move' {
                    if ($null -eq $req.x -or $null -eq $req.y) { throw "move requires x and y" }
                    [CuNative]::MoveTo([int]$req.x, [int]$req.y)
                }
                'click' {
                    if ($null -ne $req.x -and $null -ne $req.y) { [CuNative]::MoveTo([int]$req.x, [int]$req.y); Start-Sleep -Milliseconds 40 }
                    [CuNative]::Click($button, 1)
                }
                'double_click' {
                    if ($null -ne $req.x -and $null -ne $req.y) { [CuNative]::MoveTo([int]$req.x, [int]$req.y); Start-Sleep -Milliseconds 40 }
                    [CuNative]::Click($button, 2)
                }
                'drag' {
                    if ($null -eq $req.x -or $null -eq $req.y -or $null -eq $req.toX -or $null -eq $req.toY) { throw "drag requires x, y, toX, toY" }
                    [CuNative]::Drag([int]$req.x, [int]$req.y, [int]$req.toX, [int]$req.toY)
                }
                'scroll' {
                    if ($null -ne $req.x -and $null -ne $req.y) { [CuNative]::MoveTo([int]$req.x, [int]$req.y); Start-Sleep -Milliseconds 40 }
                    $amount = 3
                    if ($null -ne $req.amount) { $amount = [int]$req.amount }
                    [CuNative]::Wheel($amount)
                }
                default { throw "unknown mouseAction: $ma" }
            }
            Start-Sleep -Milliseconds 80
            $cur = [CuNative]::Cursor()
            $data = [ordered]@{
                action       = $ma
                cursor       = [ordered]@{ x = $cur[0]; y = $cur[1] }
                activeWindow = Get-WinDict ([CuNative]::Active())
            }
        }
        'keyboard' {
            $ka = [string]$req.keyboardAction
            switch ($ka) {
                'type' {
                    $text = [string]$req.text
                    if ([string]::IsNullOrEmpty($text)) { throw "type requires text" }
                    [CuNative]::TypeText($text)
                    $data = [ordered]@{ action = 'type'; characters = $text.Length }
                }
                'paste' {
                    $text = [string]$req.text
                    if ([string]::IsNullOrEmpty($text)) { throw "paste requires text" }
                    [System.Windows.Forms.Clipboard]::SetDataObject($text, $true)
                    Start-Sleep -Milliseconds 120
                    [CuNative]::KeyDown(17)
                    [CuNative]::KeyDown(86)
                    [CuNative]::KeyUp(86)
                    [CuNative]::KeyUp(17)
                    $data = [ordered]@{ action = 'paste'; characters = $text.Length }
                }
                'press' {
                    $keys = @($req.keys)
                    if ($keys.Count -lt 1) { throw "press requires keys" }
                    $vk = Resolve-VK ([string]$keys[0])
                    [CuNative]::KeyDown($vk)
                    Start-Sleep -Milliseconds 30
                    [CuNative]::KeyUp($vk)
                    $data = [ordered]@{ action = 'press'; key = [string]$keys[0] }
                }
                'hotkey' {
                    $keys = @($req.keys)
                    if ($keys.Count -lt 2) { throw 'hotkey requires at least two keys, e.g. ctrl plus c' }
                    $vks = @()
                    foreach ($k in $keys) { $vks += (Resolve-VK ([string]$k)) }
                    for ($i = 0; $i -lt $vks.Count - 1; $i++) { [CuNative]::KeyDown($vks[$i]) }
                    Start-Sleep -Milliseconds 30
                    [CuNative]::KeyDown($vks[$vks.Count - 1])
                    Start-Sleep -Milliseconds 30
                    [CuNative]::KeyUp($vks[$vks.Count - 1])
                    for ($i = $vks.Count - 2; $i -ge 0; $i--) { [CuNative]::KeyUp($vks[$i]) }
                    $data = [ordered]@{ action = 'hotkey'; keys = @($keys) }
                }
                default { throw "unknown keyboardAction: $ka" }
            }
            Start-Sleep -Milliseconds 60
            $data['activeWindow'] = Get-WinDict ([CuNative]::Active())
        }
        'window' {
            $wa = [string]$req.windowAction
            switch ($wa) {
                'list' {
                    $list = @()
                    foreach ($w in [CuNative]::ListTopWindows()) { $list += (Get-WinDict $w) }
                    $data = [ordered]@{ action = 'list'; count = $list.Count; windows = $list }
                }
                'active' {
                    $data = [ordered]@{ action = 'active'; window = (Get-WinDict ([CuNative]::Active())) }
                }
                'focus' {
                    $target = Resolve-TargetWindow $req
                    if ($null -eq $target) { throw "no matching window found" }
                    $ok = [CuNative]::Focus($target.Hwnd)
                    Start-Sleep -Milliseconds 300
                    $active = [CuNative]::Active()
                    $focused = ($null -ne $active -and $active.Hwnd -eq $target.Hwnd)
                    $data = [ordered]@{
                        action  = 'focus'
                        focused = $focused
                        window  = (Get-WinDict $active)
                    }
                    if (-not $focused) {
                        $data['warning'] = 'Windows refused to bring the window to the foreground; it may be elevated (run as administrator) or another window holds a foreground lock.'
                    }
                }
                'minimize' {
                    $target = Resolve-TargetWindow $req
                    if ($null -eq $target) { throw "no matching window found" }
                    [void][CuNative]::Minimize($target.Hwnd)
                    $data = [ordered]@{ action = 'minimize'; window = (Get-WinDict $target) }
                }
                'maximize' {
                    $target = Resolve-TargetWindow $req
                    if ($null -eq $target) { throw "no matching window found" }
                    [void][CuNative]::Maximize($target.Hwnd)
                    $data = [ordered]@{ action = 'maximize'; window = (Get-WinDict $target) }
                }
                'restore' {
                    $target = Resolve-TargetWindow $req
                    if ($null -eq $target) { throw "no matching window found" }
                    [void][CuNative]::Restore($target.Hwnd)
                    $data = [ordered]@{ action = 'restore'; window = (Get-WinDict $target) }
                }
                'close' {
                    $target = Resolve-TargetWindow $req
                    if ($null -eq $target) { throw "no matching window found" }
                    $sent = [CuNative]::Close($target.Hwnd)
                    $data = [ordered]@{ action = 'close'; closeSent = $sent; window = (Get-WinDict $target) }
                }
                'launch' {
                    $cmd = [string]$req.command
                    if ([string]::IsNullOrWhiteSpace($cmd)) { throw "launch requires command" }
                    $before = @{}
                    foreach ($w in [CuNative]::ListTopWindows()) { $before[[string]$w.Hwnd] = $true }
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = $cmd
                    $psi.UseShellExecute = $true
                    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
                    if ($null -ne $req.arguments) { $psi.Arguments = [string]$req.arguments }
                    if (-not [string]::IsNullOrWhiteSpace([string]$req.workingDirectory)) { $psi.WorkingDirectory = [string]$req.workingDirectory }
                    $p = [System.Diagnostics.Process]::Start($psi)
                    $procName = ''
                    try { $procName = $p.ProcessName } catch { }
                    $win = $null
                    $fresh = @()
                    for ($i = 0; $i -lt 40; $i++) {
                        Start-Sleep -Milliseconds 120
                        $fresh = @()
                        foreach ($w in [CuNative]::ListTopWindows()) {
                            if (-not $before.ContainsKey([string]$w.Hwnd)) { $fresh += $w }
                        }
                        foreach ($w in $fresh) { if ($w.Pid -eq $p.Id) { $win = $w; break } }
                        if ($null -ne $win) { break }
                    }
                    if ($null -eq $win) {
                        foreach ($w in $fresh) {
                            if ($w.Process -eq $procName -or $w.Process -like "$procName*") { $win = $w; break }
                        }
                    }
                    if ($null -eq $win -and $fresh.Count -eq 1) { $win = $fresh[0] }
                    if ($null -ne $win) { [void][CuNative]::Focus($win.Hwnd); Start-Sleep -Milliseconds 250 }
                    if ($null -eq $win) { $win = [CuNative]::Active() }
                    $data = [ordered]@{
                        action  = 'launch'
                        pid     = $p.Id
                        process = $procName
                        window  = (Get-WinDict $win)
                    }
                }
                default { throw "unknown windowAction: $wa" }
            }
        }
        'ui' {
            Initialize-Uia
            $uiHits = @(Find-UiMatches $req)
            $list = @()
            foreach ($m in $uiHits) { $list += $m.Record }
            $rootWindow = $null
            if ($null -ne $req.hwnd -or -not [string]::IsNullOrWhiteSpace([string]$req.windowTitle)) {
                $rootWindow = Get-WinDict (Resolve-TargetWindow $req)
            }
            else {
                $rootWindow = Get-WinDict ([CuNative]::Active())
            }
            $data = [ordered]@{
                action = 'ui'
                scope  = $rootWindow
                count  = $list.Count
                elements = $list
            }
        }
        'uiclick' {
            Initialize-Uia
            $scoped = ($null -ne $req.hwnd -or -not [string]::IsNullOrWhiteSpace([string]$req.windowTitle))
            if ($scoped) {
                $target = Resolve-TargetWindow $req
                if ($null -eq $target) { throw "no matching window found" }
                [void][CuNative]::Focus($target.Hwnd)
                Start-Sleep -Milliseconds 200
            }

            $waitMs = 0
            if ($null -ne $req.waitMs) { $waitMs = [int]$req.waitMs }
            if ($waitMs -lt 0) { $waitMs = 0 }
            $deadline = (Get-Date).AddMilliseconds($waitMs)
            $uiHits = @()
            while ($true) {
                try { $uiHits = @(Find-UiMatches $req) } catch { $uiHits = @() }
                if ($uiHits.Count -gt 0) { break }
                if ((Get-Date) -ge $deadline) { break }
                Start-Sleep -Milliseconds 250
            }
            if ($uiHits.Count -eq 0) { throw "no UI element matched the requested text or filters" }

            $index = 0
            if ($null -ne $req.index) { $index = [int]$req.index }
            if ($index -lt 0 -or $index -ge $uiHits.Count) { throw "index $index is out of range; matched $($uiHits.Count) element(s)" }

            $chosen = $uiHits[$index]
            $button = 'left'
            if (-not [string]::IsNullOrWhiteSpace([string]$req.button)) { $button = ([string]$req.button).ToLowerInvariant() }
            $double = $false
            if ($null -ne $req.double) { $double = [bool]$req.double }
            $method = Invoke-UiElement $chosen.Live $button $double
            Start-Sleep -Milliseconds 150
            $cur = [CuNative]::Cursor()
            $data = [ordered]@{
                action  = 'uiclick'
                matched = $uiHits.Count
                index   = $index
                method  = $method
                element = $chosen.Record
                cursor  = [ordered]@{ x = $cur[0]; y = $cur[1] }
                activeWindow = Get-WinDict ([CuNative]::Active())
            }
        }
        'wait' {
            $timeout = 10000
            if ($null -ne $req.timeoutMs) { $timeout = [int]$req.timeoutMs }
            if ($timeout -lt 100 -or $timeout -gt 600000) { throw 'timeoutMs must be between 100 and 600000' }
            $interval = 250
            if ($null -ne $req.intervalMs) { $interval = [Math]::Max(50, [int]$req.intervalMs) }
            $what = 'window'
            if (-not [string]::IsNullOrWhiteSpace([string]$req.what)) { $what = ([string]$req.what).ToLowerInvariant() }
            $state = 'appear'
            if (-not [string]::IsNullOrWhiteSpace([string]$req.state)) { $state = ([string]$req.state).ToLowerInvariant() }
            if ($what -eq 'element') { Initialize-Uia }

            $start = Get-Date
            $matched = $false
            $payload = $null
            $count = 0
            while ($true) {
                if ($what -eq 'window') {
                    $w = $null
                    try {
                        if ($null -ne $req.hwnd) { $w = [CuNative]::Describe((New-Object System.IntPtr([long]$req.hwnd))) }
                        elseif (-not [string]::IsNullOrWhiteSpace([string]$req.title)) { $w = [CuNative]::Find([string]$req.title) }
                        else { throw 'wait for window requires title or hwnd' }
                    }
                    catch { $w = $null }
                    $found = ($null -ne $w -and $w.Hwnd -ne 0)
                    if (($state -eq 'disappear' -and -not $found) -or ($state -ne 'disappear' -and $found)) {
                        $matched = $true
                        $payload = @{ window = (Get-WinDict $w) }
                        break
                    }
                }
                else {
                    $uiHits = @()
                    try { $uiHits = @(Find-UiMatches $req) } catch { $uiHits = @() }
                    $found = ($uiHits.Count -gt 0)
                    $count = $uiHits.Count
                    if (($state -eq 'disappear' -and -not $found) -or ($state -ne 'disappear' -and $found)) {
                        $matched = $true
                        $list = @()
                        foreach ($m in $uiHits) { $list += $m.Record }
                        $payload = @{ elements = $list }
                        break
                    }
                }
                if (((Get-Date) - $start).TotalMilliseconds -ge $timeout) { break }
                Start-Sleep -Milliseconds $interval
            }
            $elapsed = [int]((Get-Date) - $start).TotalMilliseconds
            $data = [ordered]@{
                action    = 'wait'
                what      = $what
                state     = $state
                matched   = $matched
                timedOut  = (-not $matched)
                elapsedMs = $elapsed
                count     = $count
            }
            if ($null -ne $payload -and $payload.ContainsKey('window')) { $data['window'] = $payload['window'] }
            if ($null -ne $payload -and $payload.ContainsKey('elements')) { $data['elements'] = $payload['elements'] }
        }
        'uitext' {
            Initialize-Uia
            $root = Get-UiRoot $req
            $cache = New-UiCache
            $cache.Push()
            try {
                $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            }
            finally {
                $cache.Pop()
            }

            $maxChars = 8000
            if ($null -ne $req.maxChars) { $maxChars = [int]$req.maxChars }
            if ($maxChars -lt 200) { $maxChars = 200 }
            $limit = 500
            if ($null -ne $req.limit) { $limit = [int]$req.limit }
            $full = $false
            if ($null -ne $req.full) { $full = [bool]$req.full }
            $textTypes = @('Text', 'Document', 'Edit', 'ListItem', 'Hyperlink', 'HeaderItem', 'DataItem', 'TreeItem', 'TabItem', 'MenuItem', 'Button', 'CheckBox', 'ComboBox', 'RadioButton')

            $lines = New-Object System.Collections.ArrayList
            $seen = @{}
            $used = 0
            $truncated = $false
            foreach ($el in $all) {
                $rec = $null
                try { $rec = Get-UiRecord $el } catch { continue }
                if ($rec.offscreen) { continue }
                $line = $rec.name.Trim()
                $isTextHolder = ($rec.controlType -eq 'Document' -or $rec.controlType -eq 'Edit')
                if ($line -eq '' -and -not $isTextHolder) { continue }
                if (-not $full -and $textTypes -notcontains $rec.controlType) { continue }
                if ($isTextHolder) {
                    $val = $null
                    try { $val = Get-UiElementValue $el 4000 } catch { $val = $null }
                    if ($null -ne $val -and $val.Trim() -ne '') { $line = $val.Trim() }
                }
                if ($line -eq '') { continue }
                $key = $rec.controlType + '|' + $line
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                if ($full) { $line = '[' + $rec.controlType + '] ' + $line }
                if (($used + $line.Length + 1) -gt $maxChars) { $truncated = $true; break }
                [void]$lines.Add($line)
                $used += $line.Length + 1
                if ($lines.Count -ge $limit) { $truncated = $true; break }
            }

            $scope = $null
            if ($null -ne $req.hwnd -or -not [string]::IsNullOrWhiteSpace([string]$req.windowTitle)) {
                $scope = Get-WinDict (Resolve-TargetWindow $req)
            }
            else {
                $scope = Get-WinDict ([CuNative]::Active())
            }
            $joined = ($lines -join "`n")
            $joined = $joined -replace "`r`n", "`n"
            $joined = $joined -replace "`r", "`n"
            $data = [ordered]@{
                action    = 'uitext'
                scope     = $scope
                count     = $lines.Count
                text      = $joined
                truncated = $truncated
            }
        }
        'uiset' {
            Initialize-Uia
            if ($null -eq $req.value) { throw 'uiset requires value' }
            $value = [string]$req.value
            $method = 'auto'
            if (-not [string]::IsNullOrWhiteSpace([string]$req.method)) { $method = ([string]$req.method).ToLowerInvariant() }

            $scoped = ($null -ne $req.hwnd -or -not [string]::IsNullOrWhiteSpace([string]$req.windowTitle))
            if ($scoped) {
                $t = Resolve-TargetWindow $req
                if ($null -eq $t) { throw 'no matching window found' }
                [void][CuNative]::Focus($t.Hwnd)
                Start-Sleep -Milliseconds 150
            }

            $waitMs = 0
            if ($null -ne $req.waitMs) { $waitMs = [int]$req.waitMs }
            if ($waitMs -lt 0) { $waitMs = 0 }
            $deadline = (Get-Date).AddMilliseconds($waitMs)
            $hits = @()
            while ($true) {
                try { $hits = @(Find-UiInputMatches $req) } catch { $hits = @() }
                if ($hits.Count -gt 0) { break }
                if ((Get-Date) -ge $deadline) { break }
                Start-Sleep -Milliseconds 250
            }
            if ($hits.Count -eq 0) { throw 'no matching input control found' }

            $index = 0
            if ($null -ne $req.index) { $index = [int]$req.index }
            if ($index -lt 0 -or $index -ge $hits.Count) { throw "index $index is out of range; matched $($hits.Count) control(s)" }

            $chosen = $hits[$index]
            $el = $chosen.Live
            $before = $null
            try { $before = Get-UiElementValue $el 2000 } catch { $before = $null }
            $used = ''

            if ($method -ne 'keyboard') {
                $vp = $null
                $has = $false
                try { $has = $el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) } catch { $has = $false }
                if ($has -and $null -ne $vp) {
                    $readOnly = $false
                    try { $readOnly = [bool]$vp.Current.IsReadOnly } catch { $readOnly = $false }
                    if (-not $readOnly) {
                        try {
                            $vp.SetValue($value)
                            Start-Sleep -Milliseconds 150
                            $check = Get-UiElementValue $el 4000
                            if ($null -eq $check -or $check -eq $value) { $used = 'value' }
                        }
                        catch { $used = '' }
                    }
                }
            }

            if ($used -eq '') {
                try { $el.SetFocus() } catch { }
                Start-Sleep -Milliseconds 120
                $selectAll = $true
                if ($null -ne $req.selectAll) { $selectAll = [bool]$req.selectAll }
                if ($selectAll) {
                    [CuNative]::KeyDown(17)
                    [CuNative]::KeyDown(65)
                    [CuNative]::KeyUp(65)
                    [CuNative]::KeyUp(17)
                    Start-Sleep -Milliseconds 80
                }
                [CuNative]::TypeText($value)
                Start-Sleep -Milliseconds 150
                $used = 'keyboard'
            }

            $submitted = $false
            if ($null -ne $req.submit -and [bool]$req.submit) {
                [CuNative]::KeyDown(13)
                [CuNative]::KeyUp(13)
                Start-Sleep -Milliseconds 200
                $submitted = $true
            }

            $after = $null
            try { $after = Get-UiElementValue $el 4000 } catch { $after = $null }
            $data = [ordered]@{
                action       = 'uiset'
                method       = $used
                submitted    = $submitted
                matched      = $hits.Count
                index        = $index
                element      = $chosen.Record
                valueBefore  = $before
                valueAfter   = $after
                activeWindow = Get-WinDict ([CuNative]::Active())
            }
        }
        'info' {
            $vs = [CuNative]::VirtualScreen()
            $cur = [CuNative]::Cursor()
            $monitors = @()
            foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
                $monitors += [ordered]@{
                    device  = $s.DeviceName
                    primary = $s.Primary
                    x       = $s.Bounds.X
                    y       = $s.Bounds.Y
                    width   = $s.Bounds.Width
                    height  = $s.Bounds.Height
                }
            }
            $data = [ordered]@{
                virtualScreen = [ordered]@{ x = $vs[0]; y = $vs[1]; width = $vs[2]; height = $vs[3] }
                monitors      = $monitors
                cursor        = [ordered]@{ x = $cur[0]; y = $cur[1] }
                activeWindow  = Get-WinDict ([CuNative]::Active())
            }
        }
        default { throw "unknown action: $action" }
    }

    Write-Result ([ordered]@{ ok = $true; data = $data })
}
catch {
    Write-Result ([ordered]@{ ok = $false; error = $_.Exception.Message })
}
