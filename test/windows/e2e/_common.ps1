# Shared helpers for the M1 end-to-end scenarios. Dot-source it:
#
#   . (Join-Path $PSScriptRoot '_common.ps1')
#   Invoke-E2eScenario 'name' { ...; throw 'x' fails... }
#
# Every scenario runs against a throw-away sandbox: its own USERPROFILE,
# HOME, LOCALAPPDATA, APPDATA, TEMP and XDG_CONFIG_HOME, so the owner's
# config, logs and files are never read or written. The sandbox is deleted
# at the end. Keep this file ASCII only (Windows PowerShell 5.1 reads a
# BOM-less script as ANSI); build non-ASCII text from code points.
#
# Scenarios FAIL by `throw`; non-terminating errors would count as PASS, so
# Invoke-E2eScenario forces $ErrorActionPreference = 'Stop' around the body.
# `throw 'E2E-SKIP: reason'` records SKIP instead.

Set-StrictMode -Version Latest

$script:WinDir = Split-Path -Parent $PSScriptRoot
$script:Root = (Resolve-Path (Join-Path $script:WinDir '..\..')).Path
# GHOSTTY_E2E_EXE points the scenarios at another build (for example a
# release build, to tell debug-build slowness from a real stall).
$script:Exe = if ($env:GHOSTTY_E2E_EXE) { $env:GHOSTTY_E2E_EXE } else { Join-Path $script:Root 'zig-out\bin\ghostty.exe' }
$script:SendInput = Join-Path $script:WinDir 'send-input.ps1'
$script:CaptureWindow = Join-Path $script:WinDir 'capture-window.ps1'
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Sbx = $null
$script:WantLayout = $null

Import-Module (Join-Path $script:WinDir 'lib\Harness.psm1') -Force
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('GhosttyE2e.Win' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Win -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);

[DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);

// Message box buttons are clicked by control id (IDYES = 6, IDNO = 7), so
// the label language does not matter.
public static bool ClickButton(IntPtr dlg, int id) {
    IntPtr b = GetDlgItem(dlg, id);
    if (b == IntPtr.Zero) return false;
    return PostMessageW(b, 0xF5, IntPtr.Zero, IntPtr.Zero);   // BM_CLICK
}

// Enter delivered to the dialog window itself: its dialog manager runs the
// default button. (Real key presses would go through the harness' Alt tap,
// which puts a message box into menu mode.)
public static void PostEnter(IntPtr dlg) {
    PostMessageW(dlg, 0x100, (IntPtr)0x0D, (IntPtr)0x001C0001);   // WM_KEYDOWN
    PostMessageW(dlg, 0x101, (IntPtr)0x0D, unchecked((IntPtr)0xC01C0001));   // WM_KEYUP
}

public static string ClassOf(IntPtr h) { StringBuilder s = new StringBuilder(256); GetClassNameW(h, s, 256); return s.ToString(); }
public static string TextOf(IntPtr h) { StringBuilder s = new StringBuilder(512); GetWindowTextW(h, s, 512); return s.ToString(); }

public static IntPtr LayoutOf(IntPtr h) { uint pid; uint tid = GetWindowThreadProcessId(h, out pid); return GetKeyboardLayout(tid); }

// Top-level windows of a process, optionally of one window class.
public static IntPtr[] TopLevel(uint pid, string cls) {
    List<IntPtr> found = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
        uint p; GetWindowThreadProcessId(h, out p);
        if (p == pid && (cls == null || ClassOf(h) == cls)) found.Add(h);
        return true;
    }, IntPtr.Zero);
    return found.ToArray();
}

// WM_NULL round trip: true when the window's thread answered in time.
public static bool Responsive(IntPtr h, uint timeoutMs, out long elapsedMs) {
    Stopwatch sw = Stopwatch.StartNew();
    IntPtr r;
    IntPtr ok = SendMessageTimeoutW(h, 0, IntPtr.Zero, IntPtr.Zero, 0x1, timeoutMs, out r);
    elapsedMs = sw.ElapsedMilliseconds;
    return ok != IntPtr.Zero;
}

// Bitmap helpers over a BGRA buffer (top-down, `off` = first pixel).
public static int CountNotNear(byte[] b, int off, int w, int h, int r, int g, int bl, int tol) {
    int n = 0;
    for (int i = 0; i < w * h; i++) {
        int o = off + i * 4;
        if (Math.Abs(b[o] - bl) > tol || Math.Abs(b[o + 1] - g) > tol || Math.Abs(b[o + 2] - r) > tol) n++;
    }
    return n;
}

// Resizes a window in a loop on a worker thread so the caller can watch the
// window's responsiveness; a hung SetWindowPos only blocks the worker.
public class Resizer {
    public volatile int Done;
    public volatile bool Finished;
    public volatile bool WindowGone;
    public long MaxCallMs;
    public long TotalCallMs;
    Thread t;
    public void Start(IntPtr hwnd, int count, int[] w, int[] h) {
        t = new Thread(delegate() {
            Stopwatch sw = new Stopwatch();
            for (int i = 0; i < count; i++) {
                if (!IsWindow(hwnd)) { WindowGone = true; break; }
                sw.Restart();
                // SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
                SetWindowPos(hwnd, IntPtr.Zero, 0, 0, w[i % w.Length], h[i % h.Length], 0x2 | 0x4 | 0x10);
                long ms = sw.ElapsedMilliseconds;
                if (ms > MaxCallMs) MaxCallMs = ms;
                TotalCallMs += ms;
                Done = i + 1;
            }
            Finished = true;
        });
        t.IsBackground = true;
        t.Start();
    }
}
"@ -UsingNamespace 'System.Text', 'System.Collections.Generic', 'System.Diagnostics', 'System.Threading'
}

# --- results / info ---------------------------------------------------------

function Get-E2eTempRoot {
    $dir = Join-Path $env:TEMP 'ghostty-e2e'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dir
}

# Measurements and notes: shown, and appended to info.txt next to results.txt.
function Write-E2eInfo([string]$Message) {
    $line = "INFO $($script:Sbx.Name): $Message"
    Write-Host $line
    Add-Content -Path (Join-Path (Get-E2eTempRoot) 'info.txt') -Value $line -Encoding UTF8
}

function Get-EvidenceDir {
    $dir = $env:GHOSTTY_E2E_EVIDENCE
    if (-not $dir) { return $null }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dir
}

# --- sandbox ----------------------------------------------------------------

function New-E2eSandbox([string]$Name) {
    $base = $env:GHOSTTY_E2E_RUNROOT
    if (-not $base) { $base = Join-Path (Get-E2eTempRoot) ('adhoc-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
    $root = Join-Path $base ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $sbx = [pscustomobject]@{
        Name    = $Name
        Root    = $root
        Home    = Join-Path $root 'home'
        Local   = Join-Path $root 'local'
        Roaming = Join-Path $root 'roaming'
        Tmp     = Join-Path $root 'tmp'
        Dump    = Join-Path $root 'dump'
    }
    foreach ($d in $sbx.Home, $sbx.Local, $sbx.Roaming, $sbx.Tmp) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    $sbx
}

function Remove-E2eSandbox($Sbx) {
    if ($null -eq $Sbx) { return }
    for ($i = 0; $i -lt 10; $i++) {
        try {
            if (Test-Path -LiteralPath $Sbx.Root) { Remove-Item -LiteralPath $Sbx.Root -Recurse -Force -ErrorAction Stop }
            return
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Host "WARN could not delete $($Sbx.Root)"
}

<#
.SYNOPSIS
Runs one scenario in a fresh sandbox and records PASS/FAIL/SKIP through the
harness. The body throws to fail.
#>
function Invoke-E2eScenario {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    $script:Sbx = New-E2eSandbox $Name
    $global:E2eBody = $Body
    $global:E2eSkip = $null
    $global:E2eLast = $null
    $wrapped = {
        $ErrorActionPreference = 'Stop'
        try {
            & $global:E2eBody
        } catch {
            if ($_.Exception.Message -like 'E2E-SKIP:*') {
                $global:E2eSkip = $_.Exception.Message.Substring('E2E-SKIP:'.Length).Trim()
            } else {
                # What the window shows at the moment of the failure.
                if ($global:E2eLast) { Save-Evidence 'failure' $global:E2eLast -Window }
                throw
            }
        }
    }

    try {
        if (-not (Test-Path $script:Exe)) {
            $line = "FAIL ${Name}: missing $script:Exe (run zig build first)"
            Write-Output $line
            Add-Content -Path (Join-Path (Get-E2eTempRoot) 'results.txt') -Value $line -Encoding UTF8
            return
        }

        $out = @(Invoke-GuiScenario -Name $Name -ScriptBlock $wrapped)
        $line = [string]($out | Select-Object -Last 1)
        if ($global:E2eSkip -and $line -eq "PASS $Name") {
            # The harness cannot SKIP from inside a body: rewrite its line.
            $skip = "SKIP ${Name}: $($global:E2eSkip)"
            $path = Join-Path (Get-E2eTempRoot) 'results.txt'
            $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                if ($lines[$i] -eq $line) { $lines[$i] = $skip; break }
            }
            Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
            $line = $skip
        }
        Write-Output $line
        if ($line -like 'FAIL*') { Save-Log }
    } finally {
        Stop-OwnGhostty
        $parent = Split-Path -Parent $script:Sbx.Root
        Remove-E2eSandbox $script:Sbx
        if (-not $env:GHOSTTY_E2E_RUNROOT) { Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue }
    }
}

# --- waiting / files ----------------------------------------------------------

function Wait-Until {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [double]$TimeoutSec = 10,
        [int]$PollMs = 100
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $r = & $Condition
        if ($r) { return $r }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { return $null }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-File([string]$Path, [double]$TimeoutSec = 20) {
    $ok = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
        (Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt 0)
    }
    [bool]$ok
}

# File contents as the shell wrote them: UTF-8, and as the system ANSI code
# page for a shell that ignored the UTF-8 locale.
function Read-ShellFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ansi = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    [pscustomobject]@{
        Bytes = $bytes
        Hex   = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ' '
        Utf8  = [Text.Encoding]::UTF8.GetString($bytes)
        Ansi  = [Text.Encoding]::GetEncoding($ansi).GetString($bytes)
    }
}

# Text of a char sequence written as code points (scripts stay ASCII).
function ConvertFrom-CodePoints([int[]]$Codes) {
    ($Codes | ForEach-Object { [char]::ConvertFromUtf32($_) }) -join ''
}

# --- processes ----------------------------------------------------------------

function Get-ProcessTree([int]$RootPid) {
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CreationDate)
    $found = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootPid)
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        foreach ($p in $all) {
            if ($p.ParentProcessId -eq $parent -and $p.ProcessId -ne $parent -and $seen.Add([int]$p.ProcessId)) {
                $found.Add($p)
                $queue.Enqueue([int]$p.ProcessId)
            }
        }
    }
    $found.ToArray()
}

# The members of a snapshot that are still running (same pid and start time).
function Get-SurvivingProcesses([object[]]$Snapshot) {
    $live = @(Get-CimInstance Win32_Process | Select-Object ProcessId, Name, CreationDate)
    $out = @()
    foreach ($s in $Snapshot) {
        foreach ($l in $live) {
            if ($l.ProcessId -eq $s.ProcessId -and $l.CreationDate -eq $s.CreationDate) { $out += $s; break }
        }
    }
    $out
}

function Wait-ChildNamed($G, [string[]]$Names, [double]$TimeoutSec = 15) {
    Wait-Until -TimeoutSec $TimeoutSec -PollMs 200 -Condition {
        Get-ProcessTree $G.Pid | Where-Object { $Names -contains $_.Name.ToLowerInvariant() } | Select-Object -First 1
    }
}

function Format-Procs([object[]]$Procs) {
    (@($Procs | Where-Object { $_ }) | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join ', '
}

# --- launching ----------------------------------------------------------------

$script:BaseConfig = @"
background = #102030
foreground = #e0e0e0
confirm-close-surface = false
"@

<#
.SYNOPSIS
Starts ghostty.exe inside the current sandbox and waits for its main window.
Returns pid, hwnd, startup time and the sandbox paths. The process is
registered with the harness so it is killed whatever happens.

.PARAMETER ConfigText
config.ghostty contents (default: a plain test config). -NoConfig writes none.

.PARAMETER NoXdg
Leaves XDG_CONFIG_HOME unset, so the config path comes from USERPROFILE.

.PARAMETER KeepDefaultQuit
Does not add `quit-after-last-window-closed = true`; the process then keeps
the Windows default (false) and outlives its last window.

.PARAMETER ExtraArgs
Command line arguments for the exe.

.PARAMETER NoTestIpc
Leaves GHOSTTY_WIN32_TEST_IPC unset (it is `1` otherwise).

.PARAMETER Env
Extra environment variables for the child process (name -> value).

Every start gets a class of its own (`<ClassPrefix>-<8 hex>`, default prefix `ghostty-e2e`, in $G.Class), so
no scenario can reach another instance, nor an instance of the owner.
#>
function Start-E2eGhostty {
    param(
        [string]$ConfigText = $script:BaseConfig,
        [string]$ConfigFile,
        [switch]$NoConfig,
        [switch]$NoXdg,
        [switch]$NoDump,
        [switch]$KeepDefaultQuit,
        [switch]$NoTestIpc,
        [string[]]$ExtraArgs,
        [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$ClassPrefix = 'ghostty-e2e',
        [hashtable]$Env,
        [double]$WindowTimeoutSec = 15
    )

    $sbx = $script:Sbx
    if ($ConfigFile) { $ConfigText = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 }

    $class = "$ClassPrefix-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $configHome = Join-Path $sbx.Home '.config'
    if (-not $NoConfig) {
        $extra = if ($KeepDefaultQuit) { $ConfigText } else { "quit-after-last-window-closed = true`n$ConfigText" }
        $dir = Join-Path $configHome 'ghostty'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'config.ghostty'), (New-GhosttyConfigText -Class $class -Extra $extra), (New-Object Text.UTF8Encoding $false))
    }
    if (-not $NoDump) { New-Item -ItemType Directory -Force -Path $sbx.Dump | Out-Null }

    $vars = [ordered]@{
        USERPROFILE          = $sbx.Home
        HOME                 = $sbx.Home
        LOCALAPPDATA         = $sbx.Local
        APPDATA              = $sbx.Roaming
        TEMP                 = $sbx.Tmp
        TMP                  = $sbx.Tmp
        XDG_CONFIG_HOME      = $(if ($NoXdg) { $null } else { $configHome })
        GHOSTTY_D3D11_DUMP   = $(if ($NoDump) { $null } else { $sbx.Dump })
        GHOSTTY_WIN32_TEST_IPC = $(if ($NoTestIpc) { $null } else { '1' })
    }
    if ($Env) { foreach ($k in $Env.Keys) { $vars[[string]$k] = $Env[$k] } }
    $saved = @{}
    foreach ($n in $vars.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $vars[$n], 'Process') }
        # The class goes on the command line as well, so isolation never
        # depends on the config file (-NoConfig writes none).
        $startArgs = @{ FilePath = $script:Exe; WorkingDirectory = $script:Root; PassThru = $true }
        $startArgs.ArgumentList = @("--class=$class") + @($ExtraArgs | Where-Object { $_ })
        $proc = Start-Process @startArgs
    } finally {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
    Register-OwnGhostty -ProcessId $proc.Id

    # No scenario may run on the default class.
    $cmdLine = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine
    if ($cmdLine -notlike "*--class=$class*") { throw "ghostty was not started with --class=${class}: $cmdLine" }

    $hwnd = [IntPtr]::Zero
    while ($sw.Elapsed.TotalSeconds -lt $WindowTimeoutSec) {
        $proc.Refresh()
        if ($proc.HasExited) { throw "ghostty exited early with code $($proc.ExitCode)" }
        # Not MainWindowHandle: it is ambiguous once a process has several
        # GhosttyWindows (or the unowned tab drag ghost).
        $first = Find-GhosttyWindows $proc.Id | Select-Object -First 1
        if ($first) { $hwnd = $first; break }
        Start-Sleep -Milliseconds 10
    }
    $startupMs = $sw.ElapsedMilliseconds
    if ($hwnd -eq [IntPtr]::Zero) { throw "no main window within $WindowTimeoutSec s" }

    $global:E2eLast = [pscustomobject]@{
        Process   = $proc
        Pid       = $proc.Id
        Hwnd      = $hwnd
        StartupMs = $startupMs
        Sandbox   = $sbx
        Class     = $class
        Log       = Join-Path $sbx.Local 'ghostty\logs\ghostty.log'
        Dump      = Join-Path $sbx.Dump 'surface-1.bmp'
    }
    $global:E2eLast
}

# The visible GhosttyWindows of a process in z-order, topmost first.
function Find-GhosttyWindows([int]$ProcessId) {
    @([GhosttyE2e.Win]::TopLevel([uint32]$ProcessId, 'GhosttyWindow') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
}

function Get-GhosttyWindows($G) { Find-GhosttyWindows $G.Pid }

# The frame dump of a surface (ids count from 1 in creation order).
function Get-DumpPath($G, [int]$SurfaceId) {
    Join-Path $G.Sandbox.Dump "surface-$SurfaceId.bmp"
}

function Get-LogErrors($G) {
    if (-not (Test-Path -LiteralPath $G.Log)) { return @() }
    @(Select-String -LiteralPath $G.Log -Pattern '^\S+ error\(' | ForEach-Object { $_.Line })
}

function Wait-ProcessExit($G, [double]$TimeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exited = $G.Process.WaitForExit([int]($TimeoutSec * 1000))
    [pscustomobject]@{ Exited = $exited; Ms = $sw.ElapsedMilliseconds }
}

# --- keyboard layouts -----------------------------------------------------------

# Switches the window to a keyboard layout and waits until its thread really
# runs it, so a failing switch is not mistaken for a typing bug.
function Set-WindowLayout([IntPtr]$Hwnd, [string]$Klid) {
    # The request is a posted message: repeat it once a second in case the
    # window was not pumping yet.
    $hkl = [IntPtr]::Zero
    for ($try = 0; $try -lt 4; $try++) {
        # The default window procedure only switches for the active window.
        [void](Set-ForegroundSafe -Hwnd $Hwnd)
        $hkl = Switch-GhosttyLayout -Hwnd $Hwnd -Klid $Klid
        $ok = Wait-Until -TimeoutSec 1.5 -PollMs 50 -Condition { [GhosttyE2e.Win]::LayoutOf($Hwnd) -eq $hkl }
        if ($ok) {
            $script:WantLayout = [pscustomobject]@{ Hwnd = $Hwnd; Klid = $Klid; Hkl = $hkl }
            return
        }
    }
    throw ("window keyboard layout did not change to $Klid (expected hkl 0x{0:X}, window has 0x{1:X})" -f
        $hkl.ToInt64(), [GhosttyE2e.Win]::LayoutOf($Hwnd).ToInt64())
}

# --- input ----------------------------------------------------------------------

function ConvertTo-PsString([string]$s) {
    # Base64 of the UTF-8 bytes: survives any quoting and any character.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))
    "([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))"
}

# send-input.ps1 runs in its own process: it re-imports the harness with
# -Force, which would reset this process' layout and pid bookkeeping.
function Invoke-SendInput {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [string[]]$Keys,
        [string]$Text,
        [string[]]$Scancodes,
        [int]$DelayMs = 15,
        # Type into the window of the same process that has the foreground (a
        # panel such as the search bar or the palette is a top-level popup of
        # its own): taking the foreground for the main window would pull the
        # focus out of the panel's EDIT.
        [switch]$Panel
    )

    if ($Panel) {
        $fg = [GhosttyE2e.Win]::GetForegroundWindow()
        $fgPid = [uint32]0; $mainPid = [uint32]0
        [void][GhosttyE2e.Win]::GetWindowThreadProcessId($fg, [ref]$fgPid)
        [void][GhosttyE2e.Win]::GetWindowThreadProcessId($Hwnd, [ref]$mainPid)
        if ($fg -ne [IntPtr]::Zero -and $fgPid -eq $mainPid) { $Hwnd = $fg }
    }

    # The input language follows the foreground window (it is per session
    # unless the user chose per-window layouts), so a dialog or a focus
    # change can put the owner's layout back: re-apply ours first.
    $want = $script:WantLayout
    if ($want -and $want.Hwnd -eq $Hwnd) {
        [void](Set-ForegroundSafe -Hwnd $Hwnd)
        if ([GhosttyE2e.Win]::LayoutOf($Hwnd) -ne $want.Hkl) { Set-WindowLayout $Hwnd $want.Klid }
    }

    $script_ = ConvertTo-PsString $script:SendInput
    $cmd = "& $script_ -Hwnd '0x{0:X}' -DelayMs $DelayMs" -f $Hwnd.ToInt64()
    if ($PSBoundParameters.ContainsKey('Keys')) { $cmd += ' -Keys @(' + (($Keys | ForEach-Object { ConvertTo-PsString $_ }) -join ',') + ')' }
    if ($PSBoundParameters.ContainsKey('Text')) { $cmd += ' -Text ' + (ConvertTo-PsString $Text) }
    if ($PSBoundParameters.ContainsKey('Scancodes')) { $cmd += ' -Scancodes @(' + (($Scancodes | ForEach-Object { ConvertTo-PsString $_ }) -join ',') + ')' }

    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $ErrorActionPreference = 'Continue'
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $out = & $script:PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc 2>&1
        $code = $LASTEXITCODE
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        # The foreground lock can refuse once in a while: try again.
        if ($text -match 'SKIP send-input: could not take the foreground' -and $attempt -lt 4) {
            Start-Sleep -Milliseconds 800
            continue
        }
        if ($text -match 'SKIP send-input: (.*)') { throw "E2E-SKIP: $($Matches[1].Trim())" }
        # The system can put the owner's layout back while send-input starts
        # up. When it is the first key that cannot be typed nothing was sent
        # yet, so apply our layout again and retry.
        if ($code -ne 0 -and $text -match "'(.)' is not typeable on the foreground layout" -and $want -and
            $PSBoundParameters.ContainsKey('Keys') -and $Keys.Count -gt 0 -and
            ($Keys[0] -split '\+(?=.)')[-1] -ceq $Matches[1] -and $attempt -lt 4) {
            Set-WindowLayout $Hwnd $want.Klid
            continue
        }
        if ($code -ne 0 -and $text -match 'lost the foreground to (\d+)') {
            $text += " (that window: $(Get-WindowDescription ([IntPtr][int64]$Matches[1])))"
        }
        if ($code -ne 0) { throw "send-input failed (exit $code): $text" }
        return
    }
}

# Who owns a window: process name and title, for messages about interference.
function Get-WindowDescription([IntPtr]$Hwnd) {
    $owner = [uint32]0
    [void][GhosttyE2e.Win]::GetWindowThreadProcessId($Hwnd, [ref]$owner)
    $p = Get-Process -Id $owner -ErrorAction SilentlyContinue
    $name = if ($p) { $p.ProcessName } else { "pid $owner" }
    "$name '$([GhosttyE2e.Win]::TextOf($Hwnd))'"
}

# A string as key presses: space is spelled out, everything else is one key.
function ConvertTo-KeyList([string]$s) {
    @($s.ToCharArray() | ForEach-Object { if ($_ -eq ' ') { 'space' } else { [string]$_ } })
}

# Text for the shell: VK_PACKET input, which does not depend on the keyboard
# layout (the owner's layout can come back at any moment). Enter is a named
# key, also layout independent.
function Send-Typed([IntPtr]$Hwnd, [string]$s, [int]$DelayMs = 8) {
    Invoke-SendInput -Hwnd $Hwnd -Text $s -DelayMs $DelayMs
}

function Send-Line([IntPtr]$Hwnd, [string]$s, [int]$DelayMs = 8) {
    Invoke-SendInput -Hwnd $Hwnd -Text $s -DelayMs $DelayMs
    Invoke-SendInput -Hwnd $Hwnd -Keys 'enter'
}

# Real key presses (virtual key plus scancode through the window's layout).
function Send-RealKeys([IntPtr]$Hwnd, [string]$s, [int]$DelayMs = 12) {
    Invoke-SendInput -Hwnd $Hwnd -Keys (ConvertTo-KeyList $s) -DelayMs $DelayMs
}

# The first shell under ghostty, by name.
function Get-ShellProcess($G) {
    Wait-ChildNamed $G @('bash.exe', 'pwsh.exe', 'cmd.exe', 'powershell.exe') 15
}

# Git Bash the way src/os/windows_shell.zig finds it: Git\bin\bash.exe under
# %ProgramFiles%, %ProgramW6432%, %ProgramFiles(x86)%, %LOCALAPPDATA%\Programs;
# the registry InstallPath (HKLM, HKCU); git.exe on PATH (bash.exe one or two
# levels up, in bin). The WSL launcher in System32 does not count.
function Find-GitBash {
    $cands = @()
    foreach ($v in 'ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)') {
        $d = [Environment]::GetEnvironmentVariable($v)
        if ($d) { $cands += (Join-Path $d 'Git\bin\bash.exe') }
    }
    if ($env:LOCALAPPDATA) { $cands += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe') }
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $k = Get-ItemProperty -Path "$hive\SOFTWARE\GitForWindows" -Name InstallPath -ErrorAction SilentlyContinue
        if ($k -and $k.InstallPath) { $cands += (Join-Path $k.InstallPath 'bin\bash.exe') }
    }
    foreach ($dir in ($env:PATH -split ';')) {
        if (-not $dir) { continue }
        if (Test-Path -LiteralPath (Join-Path $dir 'git.exe')) {
            $parent = Split-Path -Parent $dir
            if ($parent) {
                $cands += (Join-Path $parent 'bin\bash.exe')
                $grand = Split-Path -Parent $parent
                if ($grand) { $cands += (Join-Path $grand 'bin\bash.exe') }
            }
        }
    }
    $cands | Where-Object { $_ -notlike '*\System32\*' -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

# Scenarios that script the shell speak bash. Types ahead (the pty buffers
# input) until a marker file proves the shell executes our lines.
function Wait-BashReady($G, [double]$TimeoutSec = 40) {
    $shell = Get-ShellProcess $G
    if (-not $shell) { throw 'no shell process under ghostty within 15 s' }
    if ($shell.Name -ne 'bash.exe') {
        $bash = Find-GitBash
        if ($bash) { throw "Git Bash installed ($bash) but default shell is $($shell.Name)" }
        throw 'E2E-SKIP: Git Bash is not installed, this scenario needs it'
    }

    # -Keys types through the window's layout; the owner may be on any layout.
    Set-WindowLayout $G.Hwnd '00000409'

    $marker = Join-Path $G.Sandbox.Tmp 'gt-ready.txt'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Send-Line $G.Hwnd 'echo ready > "$TEMP/gt-ready.txt"'
        if (Wait-File $marker 6) { return }
    }
    throw "bash did not run a typed line within $TimeoutSec s"
}

# --- frame dump -----------------------------------------------------------------

# Parses surface-<n>.bmp (32-bit BI_RGB, 54 byte header). Read with
# ReadAllBytes: System.Drawing.Bitmap would lock the file and break the
# dump's atomic replace.
function Read-Dump([string]$Path) {
    $b = $null
    for ($i = 0; $i -lt 8 -and $null -eq $b; $i++) {
        try { $b = [IO.File]::ReadAllBytes($Path) } catch [IO.IOException] { Start-Sleep -Milliseconds 40 }
    }
    if ($null -eq $b) { return $null }
    if ($b.Length -lt 54 -or $b[0] -ne 0x42 -or $b[1] -ne 0x4D) { throw "$Path is not a BMP" }
    $w = [BitConverter]::ToInt32($b, 18)
    $hRaw = [BitConverter]::ToInt32($b, 22)
    $bpp = [BitConverter]::ToUInt16($b, 28)
    $h = [Math]::Abs($hRaw)
    if ($bpp -ne 32 -or [BitConverter]::ToUInt32($b, 30) -ne 0) { throw "$Path is not a 32-bit BI_RGB bitmap" }
    if ($b.Length -ne 54 + $w * $h * 4) { throw "$Path size $($b.Length) does not match ${w}x${h}" }
    [pscustomobject]@{ Width = $w; Height = $h; TopDown = ($hRaw -lt 0); Bytes = $b; Path = $Path }
}

function Get-DumpPixel($D, [int]$X, [int]$Y) {
    $row = if ($D.TopDown) { $Y } else { $D.Height - 1 - $Y }
    $o = 54 + ($row * $D.Width + $X) * 4
    [pscustomobject]@{ R = $D.Bytes[$o + 2]; G = $D.Bytes[$o + 1]; B = $D.Bytes[$o]; A = $D.Bytes[$o + 3] }
}

function Format-Pixel($P) { '#{0:x2}{1:x2}{2:x2}/a{3}' -f $P.R, $P.G, $P.B, $P.A }

# Polls the dump until the predicate holds for a freshly read frame.
function Wait-Dump($G, [scriptblock]$Predicate, [double]$TimeoutSec = 10) {
    Wait-Until -TimeoutSec $TimeoutSec -PollMs 120 -Condition {
        if (-not (Test-Path -LiteralPath $G.Dump)) { return $null }
        $d = Read-Dump $G.Dump
        if ($d -and (& $Predicate $d)) { $d } else { $null }
    }
}

function Test-PixelNear($P, [int[]]$Rgb, [int]$Tol = 2) {
    ([Math]::Abs($P.R - $Rgb[0]) -le $Tol) -and ([Math]::Abs($P.G - $Rgb[1]) -le $Tol) -and ([Math]::Abs($P.B - $Rgb[2]) -le $Tol)
}

# --- evidence ---------------------------------------------------------------------

function Save-DumpPng($D, [string]$Path) {
    $bmp = New-Object System.Drawing.Bitmap $D.Width, $D.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
    try {
        $rect = New-Object System.Drawing.Rectangle 0, 0, $D.Width, $D.Height
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
        try {
            if ($D.TopDown) {
                [Runtime.InteropServices.Marshal]::Copy($D.Bytes, 54, $data.Scan0, $D.Width * $D.Height * 4)
            } else {
                for ($y = 0; $y -lt $D.Height; $y++) {
                    $src = 54 + ($D.Height - 1 - $y) * $D.Width * 4
                    [Runtime.InteropServices.Marshal]::Copy($D.Bytes, $src, [IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $D.Width * 4)
                }
            }
        } finally {
            $bmp.UnlockBits($data)
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bmp.Dispose()
    }
}

# Frame dump (and optionally a PrintWindow capture) into the evidence dir,
# when the runner gave one. Never fails a scenario.
function Save-Evidence {
    param([string]$Tag, $G, [switch]$Window, [IntPtr]$Hwnd = [IntPtr]::Zero)
    try {
        $dir = Get-EvidenceDir
        if (-not $dir) { return }
        $base = "$($script:Sbx.Name)-$Tag"
        if ($G -and (Test-Path -LiteralPath $G.Dump)) {
            $d = Read-Dump $G.Dump
            if ($d) { Save-DumpPng $d (Join-Path $dir "$base-dump.png") }
        }
        if ($Window) {
            $h = if ($Hwnd -ne [IntPtr]::Zero) { $Hwnd } else { $G.Hwnd }
            $ErrorActionPreference = 'Continue'
            & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:CaptureWindow `
                -Hwnd ('0x{0:X}' -f $h.ToInt64()) -Out (Join-Path $dir "$base-window.png") 2>&1 | Out-Null
        }
    } catch {
        Write-Host "WARN evidence $Tag failed: $($_.Exception.Message)"
    }
}

# The sandbox's ghostty.log, kept next to the evidence of a failing scenario.
function Save-Log {
    try {
        $dir = Get-EvidenceDir
        $log = Join-Path $script:Sbx.Local 'ghostty\logs\ghostty.log'
        if ($dir -and (Test-Path -LiteralPath $log)) {
            Copy-Item -LiteralPath $log -Destination (Join-Path $dir "$($script:Sbx.Name)-ghostty.log") -Force
        }
    } catch {
        Write-Host "WARN could not keep the log: $($_.Exception.Message)"
    }
}

# --- window geometry ----------------------------------------------------------------

function Get-ClientSize([IntPtr]$Hwnd) {
    $r = New-Object GhosttyE2e.Win+RECT
    [void][GhosttyE2e.Win]::GetClientRect($Hwnd, [ref]$r)
    [pscustomobject]@{ Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top }
}

function Set-WindowSize([IntPtr]$Hwnd, [int]$Width, [int]$Height) {
    # SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
    if (-not [GhosttyE2e.Win]::SetWindowPos($Hwnd, [IntPtr]::Zero, 0, 0, $Width, $Height, 0x2 -bor 0x4 -bor 0x10)) {
        throw "SetWindowPos($Width x $Height) failed"
    }
}

# --- clipboard ------------------------------------------------------------------------

# Clipboard access needs an STA thread: the runner starts scenarios with -STA.
function Invoke-ClipboardRetry([scriptblock]$Action) {
    for ($i = 0; $i -lt 20; $i++) {
        try { return (& $Action) } catch [System.Runtime.InteropServices.ExternalException] { Start-Sleep -Milliseconds 100 }
    }
    & $Action
}

# Remembers the clipboard text; SKIPs when the clipboard holds anything we
# could not put back (images, files, ...).
function Save-ClipboardText {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'E2E-SKIP: clipboard needs an STA thread (run with powershell -STA)' }
    $data = Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::GetDataObject() }
    $formats = if ($data) { @($data.GetFormats($false)) } else { @() }
    $textFormats = 'Text', 'UnicodeText', 'OEMText', 'Locale'
    $other = @($formats | Where-Object { $textFormats -notcontains $_ })
    if ($other.Count -gt 0) { throw "E2E-SKIP: clipboard holds non-text data ($($other -join ', ')) that would be lost" }
    $hasText = Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::ContainsText() }
    $text = if ($hasText) { Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::GetText() } } else { $null }
    # A copy on disk for the runner, which puts it back if this scenario is
    # killed before Restore-ClipboardText.
    $root = Get-E2eTempRoot
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $root 'clipboard-backup.txt'), [string]$text, $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'clipboard-backup.meta'), $(if ($hasText) { 'text' } else { 'empty' }), $utf8)
    [pscustomobject]@{ HasText = [bool]$hasText; Text = $text }
}

function Restore-ClipboardText($Saved) {
    if ($null -eq $Saved) { return }
    try {
        if ($Saved.HasText) { Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::SetText($Saved.Text) } }
        else { Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::Clear() } }
    } catch {
        Write-Host "WARN could not restore the clipboard: $($_.Exception.Message)"
        return
    }
    $root = Get-E2eTempRoot
    Remove-Item -LiteralPath (Join-Path $root 'clipboard-backup.txt'), (Join-Path $root 'clipboard-backup.meta') -ErrorAction SilentlyContinue
}

function Set-ClipboardText([string]$Text) {
    Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::SetText($Text) }
}

# --- typing scenarios -----------------------------------------------------------------

function Get-ConfigPath([string]$Name) { Join-Path $script:WinDir "configs\$Name.ghostty" }

# Compares what the shell wrote with the expected text, and says which
# bytes arrived on a mismatch.
function Assert-ShellText([string]$Path, [string]$Expected, [string]$What) {
    if (-not (Wait-File $Path 20)) { throw "${What}: the shell never wrote $Path" }
    $r = Read-ShellFile $Path
    $expHex = ([Text.Encoding]::UTF8.GetBytes($Expected) | ForEach-Object { $_.ToString('x2') }) -join ' '
    if ($r.Utf8 -ceq $Expected) {
        Write-E2eInfo "$What ok, bytes: $($r.Hex)"
        return
    }
    if ($r.Ansi -ceq $Expected) {
        Write-E2eInfo "$What arrived as ANSI bytes, not UTF-8: $($r.Hex)"
        return
    }
    throw "${What}: shell received '$($r.Utf8)' (bytes $($r.Hex)), expected '$Expected' (bytes $expHex)"
}

# Starts Git Bash with the UTF-8 config and returns after the shell runs our
# lines, with the window on the US layout.
function Start-BashE2e([string]$ConfigName = 'gitbash-de', [switch]$NoDump, [string]$ExtraConfig) {
    $text = Get-Content -LiteralPath (Get-ConfigPath $ConfigName) -Raw -Encoding UTF8
    if ($ExtraConfig) { $text = $text.TrimEnd() + "`n" + $ExtraConfig + "`n" }
    $g = Start-E2eGhostty -ConfigText $text -NoDump:$NoDump
    Wait-BashReady $g
    $g
}

# `echo -n '<payload>' > "$TEMP/<file>"`: the prefix and suffix are typed on
# the US layout, the payload by the block, which may switch layouts. The
# window is back on US for the suffix.
function Invoke-PayloadCase($G, [string]$File, [scriptblock]$TypePayload) {
    $path = Join-Path $G.Sandbox.Tmp $File
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    Set-WindowLayout $G.Hwnd '00000409'
    Send-Typed $G.Hwnd "echo -n '"
    & $TypePayload
    Set-WindowLayout $G.Hwnd '00000409'
    Send-Line $G.Hwnd "' > `"`$TEMP/$File`""
    $path
}

# --- shutdown scenarios ----------------------------------------------------------------

# After the process is gone: nothing from the snapshot (a process tree taken
# while it ran) may still be alive, and nothing may still claim the old pid
# as its parent.
# -HostsMayLinger: the pseudo console's host (conhost.exe / OpenConsole.exe) stays
# while a program with a console of its own that inherited handles of it (the
# `start cmd` survivor) runs, so it is no leak until that program ends.
function Assert-NoSurvivors([object[]]$Snapshot, [int]$OldPid, [double]$GraceSec, [int[]]$Except = @(), [switch]$GhosttyAlive, [switch]$HostsMayLinger) {
    $survivors = @()
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $hosts = @('conhost.exe', 'openconsole.exe')
    do {
        $survivors = @(Get-SurvivingProcesses $Snapshot | Where-Object {
            $Except -notcontains [int]$_.ProcessId -and -not ($HostsMayLinger -and $hosts -contains $_.Name.ToLowerInvariant())
        })
        if ($survivors.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ($deadline.Elapsed.TotalSeconds -lt $GraceSec)
    if ($survivors.Count) { throw "processes left behind: $(Format-Procs $survivors)" }
    # Only meaningful once ghostty itself is gone.
    if ($GhosttyAlive -or $HostsMayLinger) { return }
    $orphans = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $OldPid } |
        Select-Object ProcessId, Name)
    if ($orphans.Count) { throw "processes still reporting the old ghostty pid as parent: $(Format-Procs $orphans)" }
}

# A program with a console of its own, as `start cmd` makes it: it must outlive
# the surface it was started from (Windows Terminal behaviour). Typed into the
# focused Git Bash; returns the pid of the new cmd.exe, found by its command
# line. The caller stops it with Stop-Survivor from a `finally`.
function Start-SurvivorConsole($G) {
    $tag = 'gt-survivor-' + ('{0:x8}' -f (Get-Random -Maximum ([int]::MaxValue)))
    # MSYS would turn the lone /k into a path.
    Send-Line $G.Hwnd "cmd //c start `"`" cmd //k echo $tag"
    $found = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition {
        Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" |
            Where-Object { $_.CommandLine -like "*$tag*" -and $_.CommandLine -like '*/k*' -and $_.CommandLine -notlike '*start*' } |
            Select-Object -First 1
    }
    if (-not $found) { throw "the survivor console ($tag) never started" }
    [int]$found.ProcessId
}

# The survivor cmd.exe and the console host it owns.
function Get-SurvivorIds([int]$SurvivorPid) {
    $ids = @($SurvivorPid)
    $ids += @(Get-CimInstance Win32_Process |
        Where-Object { $_.ParentProcessId -eq $SurvivorPid -and @('conhost.exe', 'openconsole.exe') -contains $_.Name.ToLowerInvariant() } |
        ForEach-Object { [int]$_.ProcessId })
    $ids
}

# Kills the survivor and its console host. Only ever the processes
# Start-SurvivorConsole found; safe to call twice or with 0.
function Stop-Survivor([int]$SurvivorPid) {
    if (-not $SurvivorPid) { return }
    foreach ($id in @(Get-SurvivorIds $SurvivorPid)) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
}

function Test-ProcessAlive([int]$ProcessId) {
    [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

# Starts the exe like Start-E2eGhostty does (same sandbox environment, the
# given class) but returns at once, without waiting for a window.
function Start-Launch([string]$Class, [string[]]$LaunchArgs) {
    $sbx = $script:Sbx
    $vars = [ordered]@{
        USERPROFILE            = $sbx.Home
        HOME                   = $sbx.Home
        LOCALAPPDATA           = $sbx.Local
        APPDATA                = $sbx.Roaming
        TEMP                   = $sbx.Tmp
        TMP                    = $sbx.Tmp
        XDG_CONFIG_HOME        = (Join-Path $sbx.Home '.config')
        GHOSTTY_WIN32_TEST_IPC = '1'
    }
    $saved = @{}
    foreach ($n in $vars.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    try {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $vars[$n], 'Process') }
        $proc = Start-Process -FilePath $script:Exe -WorkingDirectory $script:Root -PassThru `
            -ArgumentList (@("--class=$Class") + @($LaunchArgs | Where-Object { $_ }))
    } finally {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
    $null = $proc.Handle
    Register-OwnGhostty -ProcessId $proc.Id
    $proc
}

# --- screen captures ----------------------------------------------------------------
#
# A capture must never contain a window that is not ours (the owner works on
# this desktop): before every capture a grid of WindowFromPoint samples over
# the rect has to hit only this process (the backdrop/distractor forms) or a
# Ghostty started by this run (class ghostty-*). Otherwise it is retried
# three times and then the scenario is SKIPped ("desktop busy"), saving
# nothing. Saved images are crops of the Ghostty window (Save-WindowShot).

if (-not ('GhosttyE2e.Capture' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Capture -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct RC { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(PT p);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
public delegate bool EnumProc(IntPtr h, IntPtr l);
public struct Top { public IntPtr H; public int L, T, R, B; public uint Pid; }
// The visible, uncloaked, non-minimized top-level windows, topmost first.
public static System.Collections.Generic.List<Top> ZOrder() {
    var list = new System.Collections.Generic.List<Top>();
    EnumWindows(delegate (IntPtr h, IntPtr l) {
        if (!IsWindowVisible(h) || IsIconic(h)) return true;
        int cloaked = 0;
        DwmGetWindowAttribute(h, 14, out cloaked, 4);
        if (cloaked != 0) return true;
        RC r; if (!GetWindowRect(h, out r)) return true;
        uint pid; GetWindowThreadProcessId(h, out pid);
        list.Add(new Top { H = h, L = r.Left, T = r.Top, R = r.Right, B = r.Bottom, Pid = pid });
        return true;
    }, IntPtr.Zero);
    return list;
}
"@
}

$script:CaptureOwnerCache = @{}

function Test-OwnCaptureProcess([uint32]$ProcessId) {
    if ($ProcessId -eq $PID) { return $true }
    if ($script:CaptureOwnerCache.ContainsKey($ProcessId)) { return $script:CaptureOwnerCache[$ProcessId] }
    $ok = $false
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($p -and $p.Name -like 'ghostty*' -and [string]$p.CommandLine -like '*--class=ghostty-*') { $ok = $true }
    $script:CaptureOwnerCache[$ProcessId] = $ok
    $ok
}

# Exact z-order check: walking the top-level windows from the top, a window
# that is not ours and intersects the rect is a hit when it is above any of
# our windows that intersect the rect, or when none of ours does (the capture
# would show the owner's desktop).
function Test-CaptureZOrderClear([int]$X, [int]$Y, [int]$W, [int]$H) {
    $r = $X + $W
    $b = $Y + $H
    $foreign = $false
    $ownBelow = $false
    $seenOwn = $false
    $list = [GhosttyE2e.Capture]::ZOrder()
    foreach ($win in $list) {
        if ($win.L -ge $r -or $win.R -le $X -or $win.T -ge $b -or $win.B -le $Y) { continue }
        if (Test-OwnCaptureProcess $win.Pid) { $seenOwn = $true; if ($foreign) { $script:CaptureForeign = "pid $($foreign) above ours"; return $false } }
        elseif (-not $foreign) { $foreign = $win.Pid }
    }
    if (-not $seenOwn) { $script:CaptureForeign = "none of our windows in the rect"; return $false }
    $true
}

# True when every sampled point of the rect belongs to one of our windows.
function Test-CaptureRectClear([int]$X, [int]$Y, [int]$W, [int]$H) {
    $cols = 14
    $rows = 9
    for ($i = 0; $i -lt $cols; $i++) {
        for ($j = 0; $j -lt $rows; $j++) {
            $pt = New-Object GhosttyE2e.Capture+PT
            $pt.X = $X + [int](($W - 1) * $i / ($cols - 1))
            $pt.Y = $Y + [int](($H - 1) * $j / ($rows - 1))
            $hit = [GhosttyE2e.Capture]::WindowFromPoint($pt)
            if ($hit -eq [IntPtr]::Zero) { continue }
            $root = [GhosttyE2e.Capture]::GetAncestor($hit, 2)
            if ($root -eq [IntPtr]::Zero) { $root = $hit }
            $owner = [uint32]0
            [void][GhosttyE2e.Capture]::GetWindowThreadProcessId($root, [ref]$owner)
            if (-not (Test-OwnCaptureProcess $owner)) { $script:CaptureForeign = "pid $owner at $($pt.X),$($pt.Y) in rect $X,$Y,${W}x$H"; return $false }
        }
    }
    $true
}

function Assert-CaptureRectClear([int]$X, [int]$Y, [int]$W, [int]$H) {
    for ($try = 0; $try -lt 3; $try++) {
        if ((Test-CaptureZOrderClear $X $Y $W $H) -and (Test-CaptureRectClear $X $Y $W $H)) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "E2E-SKIP: desktop busy (a window that is not ours is in the capture area: $($script:CaptureForeign))"
}

# Pixels of a screen rect, after the foreign-window guard.
function Get-ScreenShot([int]$X, [int]$Y, [int]$W, [int]$H) {
    Assert-CaptureRectClear $X $Y $W $H
    $bmp = New-Object Drawing.Bitmap $W, $H
    $gfx = [Drawing.Graphics]::FromImage($bmp)
    try { $gfx.CopyFromScreen($X, $Y, 0, 0, (New-Object Drawing.Size $W, $H)) } finally { $gfx.Dispose() }
    $bmp
}

# Saves the window rect of `$Hwnd` plus a small margin (the backdrop around it).
function Save-WindowShot([IntPtr]$Hwnd, [string]$Path, [int]$Margin = 40) {
    $r = New-Object GhosttyE2e.Capture+RC
    [void][GhosttyE2e.Capture]::GetWindowRect($Hwnd, [ref]$r)
    $bmp = Get-ScreenShot ($r.Left - $Margin) ($r.Top - $Margin) ($r.Right - $r.Left + 2 * $Margin) ($r.Bottom - $r.Top + 2 * $Margin)
    try { $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
}
