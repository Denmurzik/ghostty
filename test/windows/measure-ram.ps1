<#
.SYNOPSIS
Measures the RAM of a freshly started ghostty.exe and appends one row to
docs/windows/ram-baseline.csv (SPEC section 14).

.DESCRIPTION
Starts ghostty.exe with an isolated sandbox (own USERPROFILE, LOCALAPPDATA,
APPDATA, TEMP and XDG_CONFIG_HOME; the user's config is never read) and the
config `command = direct:cmd.exe /k`, waits until the window is visible, lets
the process idle for 10 s and samples ghostty.exe only (shells and conhost are
not counted): PrivateMemorySize64 (Private Bytes, the budgeted number) and
WorkingSet64.

Scenarios:
  one-surface  one window, one surface, idle.
  scrollback   first runs `cmd /c "for /L %i in (1,1,200000) do @echo %i"` in
               the surface (cmd has no `seq`), so the scrollback is full, then
               idles. Needs a usable foreground window to type into; without
               one it is reported and no row is written.
  tabs         one window with 11 tabs (10 x `new_tab`), idle. Driven by the
               test IPC `action` op, no keyboard input. The per-tab cost is
               (tabs - one-surface) / 10.
  splits       one tab with 11 split panes (10 x `new_split`, right/down
               alternating), idle. Per split: (splits - one-surface) / 10.
  windows      5 windows (4 x `new_window`), idle. Per extra window:
               (windows - one-surface) / 4.
  close-10     idles, samples (`close-10-before` row), opens 10 tabs, closes
               them again (10 x `close_tab`), idles 30 s and samples the
               `close-10` row. Gate: within +10 % of the before value.
  zero-windows one window opened then closed with the Windows default
               `quit-after-last-window-closed = false`: the process stays
               resident (tray, Task 28) and is sampled. A build whose process
               exits with its last window (before Task 28) records `n/a`.

Budgeted numbers come from a ReleaseFast build. Debug rows may be recorded
with -Optimize Debug but are never gated.

The run takes the shared desktop lock (%TEMP%\gui-e2e.lock, see README.md)
and kills only the ghostty.exe it started.

CSV columns: date,commit,optimize,adapter,scenario,private_mb,ws_mb. The
commit is the short HEAD at measure time, with `-dirty` when the tree has
uncommitted changes (the file is written with LF line endings). The
adapter is read from the `d3d11 adapter=` line of the sandbox's ghostty.log.

.PARAMETER Driver
hardware (default) or warp (GHOSTTY_D3D11_DRIVER=warp).

.PARAMETER Scenario
one-surface (default), scrollback, tabs, splits, windows, close-10 or
zero-windows.

.PARAMETER Optimize
ReleaseFast (default) or Debug: which build to measure and what the row says.

.PARAMETER Exe
The ghostty.exe to measure. Default: zig-out-rf\bin\ghostty.exe for
ReleaseFast (zig build -Doptimize=ReleaseFast --prefix zig-out-rf),
zig-out\bin\ghostty.exe for Debug.

.PARAMETER Csv
Where the row goes. Default: docs\windows\ram-baseline.csv.

.PARAMETER IdleSeconds
Idle time before sampling (default 10).

.PARAMETER ConfigExtra
Extra config lines appended to the test config (for example
`font-family = Consolas`). Rows measured with it are not baseline rows: pass
-Csv elsewhere.

.PARAMETER LogCopy
Copy the run's ghostty.log here before the sandbox is deleted. A Debug build
logs the three `private usage after ...` lines (Device.init, first surface,
first frame) there.

.EXAMPLE
powershell -NoProfile -File test/windows/measure-ram.ps1 -Driver warp -Scenario one-surface
#>
param(
    [ValidateSet('hardware', 'warp')][string]$Driver = 'hardware',
    [ValidateSet('one-surface', 'scrollback', 'tabs', 'splits', 'windows', 'close-10', 'zero-windows')][string]$Scenario = 'one-surface',
    [ValidateSet('ReleaseFast', 'Debug')][string]$Optimize = 'ReleaseFast',
    [string]$Exe,
    [string]$Csv,
    [int]$IdleSeconds = 10,
    [string]$ConfigExtra,
    [string]$LogCopy
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\GhosttyIpc.psm1') -Force

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Exe) {
    $Exe = if ($Optimize -eq 'Debug') { Join-Path $root 'zig-out\bin\ghostty.exe' } else { Join-Path $root 'zig-out-rf\bin\ghostty.exe' }
}
if (-not (Test-Path -LiteralPath $Exe)) { throw "missing $Exe (build it first, see -Exe)" }
if (-not $Csv) { $Csv = Join-Path $root 'docs\windows\ram-baseline.csv' }

$commit = (& git -C $root rev-parse --short HEAD 2>$null)
if (-not $commit) { $commit = 'unknown' }
elseif (& git -C $root status --porcelain 2>$null) { $commit += '-dirty' }

# Sandbox: nothing of the user's profile is read or written.
$sbx = Join-Path $env:TEMP ('ghostty-ram\' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dirs = @{
    Home    = Join-Path $sbx 'home'
    Local   = Join-Path $sbx 'local'
    Roaming = Join-Path $sbx 'roaming'
    Tmp     = Join-Path $sbx 'tmp'
}
foreach ($d in $dirs.Values) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$configHome = Join-Path $dirs.Home '.config'
New-Item -ItemType Directory -Force -Path (Join-Path $configHome 'ghostty') | Out-Null
# zero-windows needs the Windows default (the process outlives its last window).
$quitLine = if ($Scenario -eq 'zero-windows') { '' } else { "quit-after-last-window-closed = true`n" }
$ramClass = 'ghostty-ram-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
[IO.File]::WriteAllText((Join-Path $configHome 'ghostty\config.ghostty'),
    (New-GhosttyConfigText -Class $ramClass -Extra "command = direct:cmd.exe /k`nconfirm-close-surface = false`n$quitLine$ConfigExtra"),
    (New-Object Text.UTF8Encoding $false))

$vars = [ordered]@{
    USERPROFILE          = $dirs.Home
    HOME                 = $dirs.Home
    LOCALAPPDATA         = $dirs.Local
    APPDATA              = $dirs.Roaming
    TEMP                 = $dirs.Tmp
    TMP                  = $dirs.Tmp
    XDG_CONFIG_HOME      = $configHome
    GHOSTTY_D3D11_DRIVER = $(if ($Driver -eq 'warp') { 'warp' } else { $null })
    GHOSTTY_D3D11_DUMP   = $null
    GHOSTTY_WIN32_TEST_IPC = $(if ($Scenario -in 'tabs', 'splits', 'windows', 'close-10', 'zero-windows') { '1' } else { $null })
}

$lock = Enter-GuiLock -Owner 'measure-ram.ps1' -TimeoutMinutes 30
$proc = $null
try {
    $saved = @{}
    foreach ($n in $vars.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    try {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $vars[$n], 'Process') }
        $proc = Start-Process -FilePath $Exe -WorkingDirectory $root -ArgumentList "--class=$ramClass" -PassThru
    } finally {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
    Register-OwnGhostty -ProcessId $proc.Id

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
        $proc.Refresh()
        if ($proc.HasExited) { throw "ghostty exited early with code $($proc.ExitCode)" }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'no main window within 20 s' }
        Start-Sleep -Milliseconds 100
    }
    $hwnd = $proc.MainWindowHandle

    if ($Scenario -eq 'scrollback') {
        if (-not (Test-InteractiveSession)) { throw "scrollback needs an interactive session: $(Get-SkipReason)" }
        # Let the cmd prompt come up before typing.
        Start-Sleep -Seconds 3
        $done = Join-Path $dirs.Tmp 'ram-done.txt'
        $cmdline = 'cmd /c "for /L %i in (1,1,200000) do @echo %i" & echo x > "' + $done + '"'
        $sendInput = Join-Path $PSScriptRoot 'send-input.ps1'
        $r = & $sendInput -Hwnd ('0x{0:X}' -f $hwnd.ToInt64()) -Text $cmdline
        if ("$r" -match '^SKIP') { throw "$r" }
        $r = & $sendInput -Hwnd ('0x{0:X}' -f $hwnd.ToInt64()) -Keys 'enter'
        if ("$r" -match '^SKIP') { throw "$r" }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $done)) {
            if ($proc.HasExited) { throw 'ghostty exited during the scrollback fill' }
            if ($sw.Elapsed.TotalSeconds -gt 300) { throw 'the 200000-line loop did not finish within 300 s' }
            Update-GuiLock $lock
            Start-Sleep -Milliseconds 500
        }
        Write-Host ('INFO scrollback filled in {0:N1} s' -f $sw.Elapsed.TotalSeconds)
    }

    # The IPC `state` op: windows, tabs and surfaces as the app sees them.
    function Get-RamState {
        $r = Get-GhosttyState -Class $ramClass
        if ($r.PSObject.Properties['data'] -and $null -ne $r.data) { $r.data } else { $r }
    }
    function Invoke-RamAction([string]$Action) {
        $r = Invoke-GhosttyAction -Class $ramClass -Action $Action
        if ($r.PSObject.Properties['code'] -and $r.code -ne 0) { throw "action '$Action' failed: $($r.stderr)" }
        $d = if ($r.PSObject.Properties['data'] -and $null -ne $r.data) { $r.data } else { $r }
        if ($d.PSObject.Properties['performed'] -and -not $d.performed) { throw "action '$Action' was not performed" }
        Start-Sleep -Milliseconds 700
    }

    $notApplicable = $false
    $beforeMb = $null
    $beforeWs = $null
    switch ($Scenario) {
        'tabs' {
            for ($i = 0; $i -lt 10; $i++) { Invoke-RamAction 'new_tab' }
            $w = @((Get-RamState).windows)[0]
            if (@($w.tabs).Count -ne 11) { throw "expected 11 tabs, state shows $(@($w.tabs).Count)" }
        }
        'splits' {
            for ($i = 0; $i -lt 10; $i++) { Invoke-RamAction $(if ($i % 2 -eq 0) { 'new_split:right' } else { 'new_split:down' }) }
            $w = @((Get-RamState).windows)[0]
            $n = @(@($w.tabs)[[int]$w.active_tab].surfaces).Count
            if ($n -ne 11) { throw "expected 11 surfaces, state shows $n" }
        }
        'windows' {
            for ($i = 0; $i -lt 4; $i++) { Invoke-RamAction 'new_window' }
            $n = @((Get-RamState).windows).Count
            if ($n -ne 5) { throw "expected 5 windows, state shows $n" }
        }
        'close-10' {
            Start-Sleep -Seconds $IdleSeconds
            $proc.Refresh()
            $beforeMb = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
            $beforeWs = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            for ($i = 0; $i -lt 10; $i++) { Invoke-RamAction 'new_tab' }
            if (@(@((Get-RamState).windows)[0].tabs).Count -ne 11) { throw 'expected 11 tabs before closing' }
            for ($i = 0; $i -lt 10; $i++) { Invoke-RamAction 'close_tab' }
            if (@(@((Get-RamState).windows)[0].tabs).Count -ne 1) { throw 'expected 1 tab after closing' }
            $IdleSeconds = 30
        }
        'zero-windows' {
            Invoke-RamAction 'close_window'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $proc.HasExited -and $sw.Elapsed.TotalSeconds -lt 3) { Start-Sleep -Milliseconds 100 }
            if ($proc.HasExited) {
                Write-Host 'INFO the process ended with its last window (no resident tray yet): n/a'
                $notApplicable = $true
            } else {
                $windows = @((Get-RamState).windows)
                if ($windows.Count -ne 0) { throw "expected no windows after close_window, state shows $($windows.Count)" }
            }
        }
    }

    if ($notApplicable) {
        $privateMb = 'n/a'
        $wsMb = 'n/a'
    } else {
    Start-Sleep -Seconds $IdleSeconds
    $proc.Refresh()
    if ($proc.HasExited) { throw 'ghostty exited before it could be sampled' }
    $privateMb = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
    $wsMb = [math]::Round($proc.WorkingSet64 / 1MB, 1)
    }

    $adapter = 'unknown'
    $log = Join-Path $dirs.Local 'ghostty\logs\ghostty.log'
    if (Test-Path -LiteralPath $log) {
        $m = Select-String -LiteralPath $log -Pattern 'd3d11 adapter=(.+?) vendor=' | Select-Object -First 1
        if ($m) { $adapter = $m.Matches[0].Groups[1].Value.Trim() }
        if ($LogCopy) { Copy-Item -LiteralPath $log -Destination $LogCopy -Force }
    }
} finally {
    # taskkill can fail on a tree that is changing under it; whatever it
    # leaves of the process this run started is killed here (the job object
    # of the pty takes the shell with it).
    try { Stop-OwnGhostty } catch { }
    if ($proc) {
        $proc.Refresh()
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
    Exit-GuiLock $lock
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $sbx -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $Csv)) {
    [IO.File]::WriteAllText($Csv, "date,commit,optimize,adapter,scenario,private_mb,ws_mb`n", (New-Object Text.UTF8Encoding $false))
}
# Adapter names have no commas in practice; keep the file parseable anyway.
$row = '{0},{1},{2},{3},{4},{5},{6}' -f (Get-Date -Format 'yyyy-MM-dd'), $commit, $Optimize,
    ($adapter -replace ',', ' '), $Scenario,
    ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $privateMb)),
    ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $wsMb))
if ($null -ne $beforeMb) {
    $before = '{0},{1},{2},{3},close-10-before,{4},{5}' -f (Get-Date -Format 'yyyy-MM-dd'), $commit, $Optimize,
        ($adapter -replace ',', ' '),
        ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $beforeMb)),
        ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $beforeWs))
    [IO.File]::AppendAllText($Csv, $before + "`n", (New-Object Text.UTF8Encoding $false))
    Write-Output $before
    Write-Host ('INFO close-10: {0} MB after vs {1} MB before = {2:P1}' -f $privateMb, $beforeMb, ($privateMb / $beforeMb - 1))
}
[IO.File]::AppendAllText($Csv, $row + "`n", (New-Object Text.UTF8Encoding $false))
Write-Output $row
