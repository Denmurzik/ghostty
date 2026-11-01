<#
.SYNOPSIS
Measures the RAM (and with -Gpu the GPU memory, CPU and GPU load) of a freshly
started ghostty.exe and appends rows to docs/windows/ram-baseline.csv (SPEC
section 14) or docs/windows/gpu-baseline.csv.

.DESCRIPTION
Starts ghostty.exe with an isolated sandbox (own USERPROFILE, LOCALAPPDATA,
APPDATA, TEMP and XDG_CONFIG_HOME; the user's config is never read) and the
config `command = direct:cmd.exe /k`, waits until the window is visible, lets
the process idle for 10 s and samples ghostty.exe only (shells and conhost are
not counted): PrivateMemorySize64 (Private Bytes, the budgeted number) and
WorkingSet64.

Scenarios:
  one-surface  one window, one surface, idle.
  scrollback   first runs `cmd /c "for /L %i in (1,1,<ScrollbackLines>) do @echo %i"`
               in the surface (cmd has no `seq`), so the scrollback is full
               (the default `scrollback-limit-bytes` is 50 MB: 1200000 lines are
               well past it; the fill size is logged), then idles. Needs a
               usable foreground window to type into; without one it is
               reported and no row is written.
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

Hidden-surface scenarios (M8; they imply -Gpu and write gpu-baseline.csv):
  hidden-tabs  the window at a fixed client size (-ClientWidth x -ClientHeight,
               default 1600x900; -Maximized: maximized instead, row tag
               `-max`), 11 tabs (-Tabs). A 1-tab baseline row, then
               `-Sample "all@wait:10,one-visible@goto_tab:1,after-trim@wait:5"`
               (the default). Prints the GPU memory per hidden tab,
               (total(11 tabs) - total(1 tab)) / 10, against the R-M8-21 gate
               (keep the swap chain shrink if a hidden tab holds >= 8 MB at the
               default size or >= 30 MB maximized at 1080p before the shrink).
  hidden-flood every tab runs `cmd /c "for /L %i in (1,1,2000000000) do @echo %i"`,
               -Tabs (default 11) of them, tab 1 selected. Compare cpu_pct and
               gpu_3d_pct with `-Tabs 1` (one visible flooding tab): the hidden
               floods should add termio cost only, no render.
  hidden-anim  the Kitty animation of vt-smoke/cases/kitty-anim.sh (Git Bash,
               `windows-conpty = bundled`) plays in tab 1 only; samples
               `anim-visible`, `anim-hidden` (after `new_tab`), `anim-shown`
               (after `goto_tab:1`). gpu_3d_pct of the hidden row should be
               idle.
  minimized    one window; samples `visible`, `minimized`, `restored`
               (the ops `minimize` / `restore` are done on the window handle,
               not through IPC). gpu_3d_pct of the minimized row ~ 0, memory
               unchanged (the swap chain is kept).
  show_ms      -Tabs (default 2) tabs, 20 `goto_tab` switches alternating
               between tab 1 and 2: the time from sending the IPC action to
               the target surface's `presents` increment (IPC overhead
               included) -> show_ms_p50 / show_ms_p95. Empty columns when the
               build has no `presents` field.

Budgeted numbers come from a ReleaseFast build. Debug rows may be recorded
with -Optimize Debug but are never gated.

The run takes the shared desktop lock (%TEMP%\gui-e2e.lock, see README.md)
and kills only the ghostty.exe it started.

CSV columns: date,commit,optimize,adapter,scenario,private_mb,ws_mb. With -Gpu
(or a hidden-surface scenario) the file is docs\windows\gpu-baseline.csv and the
columns are date,commit,optimize,adapter,scenario,private_mb,ws_mb,
gpu_dedicated_mb,gpu_shared_mb,cpu_pct,gpu_3d_pct,show_ms_p50,show_ms_p95:
  gpu_dedicated_mb / gpu_shared_mb  CIM Win32_PerfFormattedData_GPUPerformanceCounters_
                                    GPUProcessMemory, instances pid_<PID>_luid_*, summed.
  cpu_pct       TotalProcessorTime delta / wall / logical CPUs (percent of the
                whole machine) over the -GpuSeconds window after the sample.
  gpu_3d_pct    ..._GPUEngine instances pid_<PID>_*_engtype_3D, summed per
                second, mean of -GpuSeconds (10) samples.
The GPU columns are empty (and an INFO line says so) when the performance
classes are absent (WARP, some VMs and drivers). Only the ghostty.exe this
script started is sampled. The commit is the short HEAD at measure time, with
`-dirty` when the tree has uncommitted changes (the file is written with LF line
endings). The adapter is read from the `d3d11 adapter=` line of the sandbox's
ghostty.log.

.PARAMETER Driver
hardware (default) or warp (GHOSTTY_D3D11_DRIVER=warp).

.PARAMETER Scenario
one-surface (default), scrollback, tabs, splits, windows, close-10,
zero-windows, hidden-tabs, hidden-flood, hidden-anim, minimized or show_ms.

.PARAMETER Optimize
ReleaseFast (default) or Debug: which build to measure and what the row says.

.PARAMETER Exe
The ghostty.exe to measure. Default: zig-out-rf\bin\ghostty.exe for
ReleaseFast (zig build -Doptimize=ReleaseFast --prefix zig-out-rf),
zig-out\bin\ghostty.exe for Debug.

.PARAMETER Csv
Where the row goes. Default: docs\windows\ram-baseline.csv, with -Gpu or a
hidden-surface scenario docs\windows\gpu-baseline.csv.

.PARAMETER IdleSeconds
Idle time before sampling (default 10).

.PARAMETER ExtraConfig
Extra config lines appended to the test config (for example
`font-family = Consolas`; alias ConfigExtra). Rows measured with it are not
baseline rows: pass -Csv elsewhere.

.PARAMETER Actions
Comma separated `op:arg` actions (`new_split:right,toggle_readonly`) run in
order through the test IPC after the scenario's own setup, before the idle
time and the sample. Implies GHOSTTY_WIN32_TEST_IPC=1. An action the app does
not perform is reported (INFO) and the run goes on.

.PARAMETER Tag
Written to the CSV `scenario` column instead of the scenario name (rows with
-Sample: `<tag>:<label>`). Use it to keep config/feature rows apart from the
baseline rows.

.PARAMETER Sample
Multi-point sampling: `label@op,label@op`. `op` is an action, `wait:<seconds>`,
or (window handle ops) `minimize` / `restore`; after each op one row is sampled
with the scenario `<tag>:<label>` (the tag defaults to the scenario name).
Replaces the single idle-then-sample row. Implies GHOSTTY_WIN32_TEST_IPC=1.

.PARAMETER LogCopy
Copy the run's ghostty.log here before the sandbox is deleted. A Debug build
logs the three `private usage after ...` lines (Device.init, first surface,
first frame) there.

.PARAMETER Gpu
Add the GPU memory, CPU and GPU 3D columns (see above) and write
gpu-baseline.csv. Implied by the hidden-surface scenarios.

.PARAMETER GpuSeconds
Length of the CPU / GPU 3D window after each sample (default 10: ten 1 s GPU
samples).

.PARAMETER Tabs
Tab count of hidden-tabs / hidden-flood (default 11), hidden-anim (1) and
show_ms (2).

.PARAMETER Maximized
hidden-tabs: maximize the window (toggle_maximize) instead of the fixed client
size; the row names get the suffix `-max`.

.PARAMETER ClientWidth
.PARAMETER ClientHeight
hidden-tabs: the client size in pixels (default 1600x900).

.PARAMETER ScrollbackLines
scrollback: lines of the fill (default 1200000).

.PARAMETER DryRun
Prints the plan (config, environment, setup, sample points, CSV) and exits
before anything is started. No window, no lock.

.PARAMETER SelfTest
Runs the pure helpers (CSV rows, percentiles, CPU percent, sample parsing, GPU
instance filter) and exits. No window, no lock.

.EXAMPLE
powershell -NoProfile -File test/windows/measure-ram.ps1 -Driver warp -Scenario one-surface

.EXAMPLE
powershell -NoProfile -File test/windows/measure-ram.ps1 -Scenario hidden-tabs -Maximized

.EXAMPLE
powershell -NoProfile -File test/windows/measure-ram.ps1 -Scenario show_ms -DryRun
#>
param(
    [ValidateSet('hardware', 'warp')][string]$Driver = 'hardware',
    [ValidateSet('one-surface', 'scrollback', 'tabs', 'splits', 'windows', 'close-10', 'zero-windows',
        'hidden-tabs', 'hidden-flood', 'hidden-anim', 'minimized', 'show_ms')][string]$Scenario = 'one-surface',
    [ValidateSet('ReleaseFast', 'Debug')][string]$Optimize = 'ReleaseFast',
    [string]$Exe,
    [string]$Csv,
    [int]$IdleSeconds = 10,
    [Alias('ConfigExtra')][string]$ExtraConfig,
    [string[]]$Actions,
    [string]$Tag,
    [string[]]$Sample,
    [string]$LogCopy,
    [switch]$Gpu,
    [int]$GpuSeconds = 10,
    [int]$Tabs = 0,
    [switch]$Maximized,
    [int]$ClientWidth = 1600,
    [int]$ClientHeight = 900,
    [int]$ScrollbackLines = 1200000,
    [switch]$DryRun,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\GpuCounters.psm1') -Force

# --- pure helpers (SelfTest covers them) --------------------------------------

# `label@op,label@op` -> objects. `powershell -File` hands over `a,b` as one string.
function ConvertTo-SamplePoints([string[]]$Spec) {
    $items = @($Spec | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    @(foreach ($s in $items) {
        $at = $s.IndexOf('@')
        if ($at -lt 1 -or $at -eq $s.Length - 1) { throw "-Sample entry '$s' is not label@op" }
        [pscustomobject]@{ Label = $s.Substring(0, $at); Op = $s.Substring($at + 1) }
    })
}

# Bytes `cmd /c "for /L %i in (1,1,N) do @echo %i"` prints: every number plus CR LF.
function Get-CountedBytes([int64]$N) {
    $total = [int64]0
    $lo = [int64]1
    $digits = 1
    while ($lo -le $N) {
        $hi = [math]::Min($N, $lo * 10 - 1)
        $total += ($hi - $lo + 1) * ($digits + 2)
        $lo *= 10
        $digits++
    }
    $total
}

function New-RamRow([string]$Name, $Private, $Ws) {
    [pscustomobject]@{
        Name = $Name; Private = $Private; Ws = $Ws
        GpuDedicated = $null; GpuShared = $null; Cpu = $null; Gpu3d = $null; ShowP50 = $null; ShowP95 = $null
    }
}

# One CSV line. Adapter and scenario names have no commas in practice; keep the
# file parseable anyway. An empty (null) value is an empty column.
function ConvertTo-CsvLine {
    param($Row, [string]$Date, [string]$Commit, [string]$Optimize, [string]$Adapter, [bool]$GpuColumns)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $f = { param($v) if ($null -eq $v) { '' } else { [string]::Format($inv, '{0}', $v) } }
    $cols = @($Date, $Commit, $Optimize, ($Adapter -replace ',', ' '), ($Row.Name -replace ',', ' '),
        (& $f $Row.Private), (& $f $Row.Ws))
    if ($GpuColumns) {
        $cols += @((& $f $Row.GpuDedicated), (& $f $Row.GpuShared), (& $f $Row.Cpu), (& $f $Row.Gpu3d),
            (& $f $Row.ShowP50), (& $f $Row.ShowP95))
    }
    $cols -join ','
}

$gpuHeader = 'date,commit,optimize,adapter,scenario,private_mb,ws_mb,gpu_dedicated_mb,gpu_shared_mb,cpu_pct,gpu_3d_pct,show_ms_p50,show_ms_p95'
$ramHeader = 'date,commit,optimize,adapter,scenario,private_mb,ws_mb'

if ($SelfTest) {
    $fail = 0
    function Check([string]$What, [bool]$Ok) {
        if ($Ok) { Write-Host "PASS $What" } else { Write-Host "FAIL $What"; $script:fail++ }
    }
    Check 'percentile p50 of 1..10 is 5' ((Get-Percentile -Values (1..10) -P 50) -eq 5)
    Check 'percentile p95 of 1..10 is 10' ((Get-Percentile -Values (1..10) -P 95) -eq 10)
    Check 'percentile of one value' ((Get-Percentile -Values @(7) -P 95) -eq 7)
    Check 'percentile of nothing is null' ($null -eq (Get-Percentile -Values @() -P 50))
    Check 'cpu percent of one core' ([math]::Abs((ConvertTo-CpuPercent -CpuSeconds 0.5 -WallSeconds 10) - 5) -lt 1e-9)
    Check 'cpu percent of the machine' ([math]::Abs((ConvertTo-CpuPercent -CpuSeconds 0.5 -WallSeconds 10 -LogicalCpus 8 -PerMachine) - 0.625) -lt 1e-9)
    $rows = @(
        [pscustomobject]@{ Name = 'pid_12_luid_0x0_0x1_phys_0' }
        [pscustomobject]@{ Name = 'pid_123_luid_0x0_0x1_phys_0' }
        [pscustomobject]@{ Name = 'pid_12_luid_0x0_0x1_phys_0_eng_0_engtype_3D' }
        [pscustomobject]@{ Name = 'pid_12_luid_0x0_0x1_phys_0_eng_1_engtype_Copy' }
    )
    Check 'gpu rows: pid 12 does not take pid 123' (@(Select-GpuPidRows -Rows $rows -ProcessId 12).Count -eq 3)
    Check 'gpu rows: 3D engines only' (@(Select-GpuPidRows -Rows $rows -ProcessId 12 -NameRegex '_engtype_3D$').Count -eq 1)
    $pts = @(ConvertTo-SamplePoints 'all@wait:10,one-visible@goto_tab:1,after-trim@wait:5')
    Check 'sample points: three, ops kept' ($pts.Count -eq 3 -and $pts[1].Label -eq 'one-visible' -and $pts[1].Op -eq 'goto_tab:1')
    $threw = $false
    try { [void](ConvertTo-SamplePoints 'broken') } catch { $threw = $true }
    Check 'sample points: label@op is required' $threw
    Check 'counted bytes of 1..9' ((Get-CountedBytes 9) -eq 27)
    Check 'counted bytes of 1..10' ((Get-CountedBytes 10) -eq 31)
    Check 'counted bytes of 1..200000' ((Get-CountedBytes 200000) -eq (1..200000 | ForEach-Object { ([string]$_).Length + 2 } | Measure-Object -Sum).Sum)
    $r = New-RamRow 'x,y' 66.1 96.4
    $line = ConvertTo-CsvLine -Row $r -Date '2026-11-01' -Commit 'abc' -Optimize 'ReleaseFast' -Adapter 'A,B' -GpuColumns $false
    Check 'ram csv line: 7 columns, commas replaced' ($line -eq '2026-11-01,abc,ReleaseFast,A B,x y,66.1,96.4')
    $r.GpuShared = 12.5; $r.Cpu = 0.31; $r.ShowP95 = 18
    $line = ConvertTo-CsvLine -Row $r -Date '2026-11-01' -Commit 'abc' -Optimize 'ReleaseFast' -Adapter 'A' -GpuColumns $true
    Check 'gpu csv line: 13 columns, empty values stay empty' (($line -split ',').Count -eq 13 -and $line -eq '2026-11-01,abc,ReleaseFast,A,x y,66.1,96.4,,12.5,0.31,,,18')
    Check 'gpu header has 13 columns' (($gpuHeader -split ',').Count -eq 13)
    $headerFile = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'docs\windows\gpu-baseline.csv'
    Check 'docs/windows/gpu-baseline.csv starts with the header' ((Test-Path -LiteralPath $headerFile) -and ((Get-Content -LiteralPath $headerFile -TotalCount 1) -eq $gpuHeader))
    if ($fail) { Write-Host "selftest FAILED ($fail)"; exit 1 }
    Write-Host 'selftest PASS'
    return
}

# --- plan ------------------------------------------------------------------------

$hiddenScenarios = @('hidden-tabs', 'hidden-flood', 'hidden-anim', 'minimized', 'show_ms')
$useGpu = $Gpu.IsPresent -or ($Scenario -in $hiddenScenarios)
$tabCount = if ($Tabs -gt 0) { $Tabs } else {
    switch ($Scenario) { 'hidden-tabs' { 11 } 'hidden-flood' { 11 } 'hidden-anim' { 1 } 'show_ms' { 2 } default { 1 } }
}
$defaultSamples = switch ($Scenario) {
    'hidden-tabs' { 'all@wait:10,one-visible@goto_tab:1,after-trim@wait:5' }
    'hidden-anim' { 'anim-visible@wait:2,anim-hidden@new_tab,anim-shown@goto_tab:1' }
    'minimized' { 'visible@wait:2,minimized@minimize,restored@restore' }
    default { $null }
}
$Actions = @($Actions | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$samplePoints = @(ConvertTo-SamplePoints $Sample)
if (-not $samplePoints.Count -and $defaultSamples) { $samplePoints = @(ConvertTo-SamplePoints $defaultSamples) }
$rowName = if ($Tag) { $Tag } else { $Scenario }
if (-not $Tag -and $Scenario -in 'hidden-tabs', 'hidden-flood' -and $Tabs -gt 0 -and $Tabs -ne 11) { $rowName += "-$Tabs" }
if (-not $Tag -and $Scenario -eq 'hidden-tabs' -and $Maximized) { $rowName += '-max' }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Exe) {
    $Exe = if ($Optimize -eq 'Debug') { Join-Path $root 'zig-out\bin\ghostty.exe' } else { Join-Path $root 'zig-out-rf\bin\ghostty.exe' }
}
if (-not $DryRun -and -not (Test-Path -LiteralPath $Exe)) { throw "missing $Exe (build it first, see -Exe)" }
if (-not $Csv) { $Csv = Join-Path $root $(if ($useGpu) { 'docs\windows\gpu-baseline.csv' } else { 'docs\windows\ram-baseline.csv' }) }

# Git Bash the way src/os/windows_shell.zig finds it (hidden-anim plays the
# animation through it, on the bundled ConPTY).
function Find-GitBash {
    $cands = @()
    foreach ($base in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)}, $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' }))) {
        if ($base) { $cands += (Join-Path $base 'Git\bin\bash.exe') }
    }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $gd = Split-Path -Parent (Split-Path -Parent $git.Source)
        $cands += (Join-Path $gd 'bin\bash.exe')
        $cands += (Join-Path (Split-Path -Parent $gd) 'bin\bash.exe')
    }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $null
}

$animScript = (Join-Path $PSScriptRoot 'vt-smoke\cases\kitty-anim.sh') -replace '\\', '/'
$gitBash = $null
if ($Scenario -eq 'hidden-anim') {
    $gitBash = Find-GitBash
    if (-not $gitBash -and -not $DryRun) { throw 'hidden-anim needs Git Bash (bash.exe) to play the Kitty animation' }
}

# The scenario's own config lines (the sandbox adds the class).
$commandLine = switch ($Scenario) {
    'hidden-flood' { 'command = direct:cmd.exe /c "for /L %i in (1,1,2000000000) do @echo %i"' }
    'hidden-anim' { 'command = direct:"' + $(if ($gitBash) { $gitBash } else { '<Git Bash>' }) + '" --noprofile --norc ' + $animScript + "`nwindows-conpty = bundled" }
    default { 'command = direct:cmd.exe /k' }
}
# zero-windows needs the Windows default (the process outlives its last window).
$quitLine = if ($Scenario -eq 'zero-windows') { '' } else { "quit-after-last-window-closed = true`n" }
$configExtra = "$commandLine`nconfirm-close-surface = false`n$quitLine$ExtraConfig"

$needsIpc = ($Scenario -in 'tabs', 'splits', 'windows', 'close-10', 'zero-windows') -or ($Scenario -in $hiddenScenarios) -or $Actions.Count -or $samplePoints.Count

$commit = (& git -C $root rev-parse --short HEAD 2>$null)
if (-not $commit) { $commit = 'unknown' }
elseif (& git -C $root status --porcelain 2>$null) { $commit += '-dirty' }

if ($DryRun) {
    Write-Host "DRYRUN scenario=$Scenario row=$rowName gpu=$useGpu tabs=$tabCount maximized=$($Maximized.IsPresent) optimize=$Optimize driver=$Driver"
    Write-Host "DRYRUN exe=$Exe (exists: $(Test-Path -LiteralPath $Exe))"
    Write-Host "DRYRUN csv=$Csv"
    Write-Host "DRYRUN test ipc: $needsIpc; gpu counters present: $(Test-GpuCounters)"
    Write-Host 'DRYRUN config:'
    foreach ($l in ($configExtra -split "`n")) { if ($l) { Write-Host "DRYRUN   $l" } }
    if ($Scenario -eq 'hidden-anim') { Write-Host "DRYRUN   env KITTY_ANIM_ONCE=<sandbox tmp>\anim-once (only the first tab plays the animation)" }
    $setup = switch ($Scenario) {
        'hidden-tabs' { "client size $(if ($Maximized) { 'maximized' } else { "${ClientWidth}x${ClientHeight}" }); 1-tab baseline row; $($tabCount - 1) x new_tab" }
        'hidden-flood' { "$($tabCount - 1) x new_tab" }
        'show_ms' { "$($tabCount - 1) x new_tab; 20 x goto_tab (alternating 1, 2) timed to the presents increment" }
        'scrollback' { "type the fill of $ScrollbackLines lines (~$(Get-CountedBytes $ScrollbackLines) bytes printed)" }
        default { 'none' }
    }
    Write-Host "DRYRUN setup: $setup"
    Write-Host "DRYRUN actions: $($Actions -join ', ')"
    Write-Host "DRYRUN samples: $((@($samplePoints | ForEach-Object { "$($_.Label)@$($_.Op)" })) -join ', ') (idle $IdleSeconds s, load window $GpuSeconds s)"
    return
}

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
$ramClass = 'ghostty-ram-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
[IO.File]::WriteAllText((Join-Path $configHome 'ghostty\config.ghostty'),
    (New-GhosttyConfigText -Class $ramClass -Extra $configExtra),
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
    GHOSTTY_WIN32_TEST_IPC = $(if ($needsIpc) { '1' } else { $null })
    # kitty-anim.sh: only the first tab plays the animation (a later tab finds the marker).
    KITTY_ANIM_ONCE      = $(if ($Scenario -eq 'hidden-anim') { Join-Path $dirs.Tmp 'anim-once' } else { $null })
}

# Window handle helpers for the fixed client size and minimize / restore.
function Initialize-RamWin {
    if ('GhosttyRam.Win' -as [type]) { return }
    Add-Type -Namespace GhosttyRam -Name Win -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
'@
    # Real pixels, not the 96-DPI view a DPI-unaware script would get.
    try { [void][GhosttyRam.Win]::SetProcessDPIAware() } catch { }
}

function Get-RamClientSize([IntPtr]$Hwnd) {
    $c = New-Object GhosttyRam.Win+RECT
    [void][GhosttyRam.Win]::GetClientRect($Hwnd, [ref]$c)
    [pscustomobject]@{ Width = $c.Right - $c.Left; Height = $c.Bottom - $c.Top }
}

function Set-RamClientSize([IntPtr]$Hwnd, [int]$Width, [int]$Height) {
    $w = New-Object GhosttyRam.Win+RECT
    [void][GhosttyRam.Win]::GetWindowRect($Hwnd, [ref]$w)
    $c = Get-RamClientSize $Hwnd
    $outerW = ($w.Right - $w.Left) - $c.Width + $Width
    $outerH = ($w.Bottom - $w.Top) - $c.Height + $Height
    # SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
    if (-not [GhosttyRam.Win]::SetWindowPos($Hwnd, [IntPtr]::Zero, 0, 0, $outerW, $outerH, 0x2 -bor 0x4 -bor 0x10)) {
        Write-Host "INFO SetWindowPos to a ${Width}x${Height} client failed"
    }
    Start-Sleep -Milliseconds 1500
    Get-RamClientSize $Hwnd
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
        $printed = Get-CountedBytes $ScrollbackLines
        Write-Host ("INFO scrollback fill: {0} lines, {1} bytes printed (scrollback-limit-bytes default 50000000{2})" -f $ScrollbackLines, $printed, $(if ($ExtraConfig -match 'scrollback-limit') { '; overridden by -ExtraConfig' } else { '' }))
        $cmdline = 'cmd /c "for /L %i in (1,1,' + $ScrollbackLines + ') do @echo %i" & echo x > "' + $done + '"'
        $sendInput = Join-Path $PSScriptRoot 'send-input.ps1'
        $r = & $sendInput -Hwnd ('0x{0:X}' -f $hwnd.ToInt64()) -Text $cmdline
        if ("$r" -match '^SKIP') { throw "$r" }
        $r = & $sendInput -Hwnd ('0x{0:X}' -f $hwnd.ToInt64()) -Keys 'enter'
        if ("$r" -match '^SKIP') { throw "$r" }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $done)) {
            if ($proc.HasExited) { throw 'ghostty exited during the scrollback fill' }
            if ($sw.Elapsed.TotalSeconds -gt 900) { throw "the $ScrollbackLines-line loop did not finish within 900 s" }
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
    # The first surface of the tab at `$Index` (0-based) of the first window.
    function Get-RamTabSurface([int]$Index) {
        $w = @((Get-RamState).windows)[0]
        $t = @($w.tabs)[$Index]
        @($t.surfaces)[0]
    }
    function Get-RamField($Obj, [string]$Name) {
        if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { $Obj.$Name } else { $null }
    }

    if ($useGpu -and -not (Test-GpuCounters)) {
        Write-Host 'INFO GPU performance counter classes (GPUProcessMemory / GPUEngine) are absent: the GPU columns stay empty'
    }

    # One sample row: Private and WS now, GPU memory now, then (-Gpu) the CPU and
    # GPU 3D load over -GpuSeconds.
    $gpuNoted = $false
    function Get-RamSample([string]$Name, [bool]$WithLoad) {
        $proc.Refresh()
        if ($proc.HasExited) { throw "ghostty exited before sample '$Name'" }
        $row = New-RamRow $Name ([math]::Round($proc.PrivateMemorySize64 / 1MB, 1)) ([math]::Round($proc.WorkingSet64 / 1MB, 1))
        if ($useGpu) {
            $m = Get-GpuProcessMemoryMb -ProcessId $proc.Id
            if ($m) {
                if ($m.Instances -eq 0 -and -not $script:gpuNoted) {
                    Write-Host "INFO no GPUProcessMemory instance for pid $($proc.Id) (software adapter?): GPU memory is 0"
                    $script:gpuNoted = $true
                }
                $row.GpuDedicated = $m.Dedicated
                $row.GpuShared = $m.Shared
            }
            if ($WithLoad) {
                $l = Measure-ProcessLoad -Process $proc -Seconds $GpuSeconds -Tick { Update-GuiLock $lock }
                $row.Cpu = [math]::Round($l.CpuMachine, 2)
                $row.Gpu3d = $l.Gpu3d
                Write-Host ("INFO {0}: cpu {1:N2} % of the machine ({2:N1} % of one core), gpu 3d {3} % over {4} s" -f $Name, $l.CpuMachine, $l.CpuCore, $(if ($null -eq $l.Gpu3d) { 'n/a' } else { $l.Gpu3d }), $l.Seconds)
            }
        }
        $row
    }

    $notApplicable = $false
    $beforeMb = $null
    $beforeWs = $null
    $showMs = @()
    $baselineRow = $null
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
        'hidden-tabs' {
            Initialize-RamWin
            if ($Maximized) {
                Invoke-RamAction 'toggle_maximize'
                Start-Sleep -Milliseconds 1500
                $cs = Get-RamClientSize $hwnd
                Write-Host ("INFO hidden-tabs: maximized, client {0}x{1} px" -f $cs.Width, $cs.Height)
            } else {
                $cs = Set-RamClientSize $hwnd $ClientWidth $ClientHeight
                Write-Host ("INFO hidden-tabs: client {0}x{1} px (asked {2}x{3})" -f $cs.Width, $cs.Height, $ClientWidth, $ClientHeight)
            }
            # The 1-tab baseline: the per-hidden-tab cost is measured against it.
            Start-Sleep -Seconds 3
            $baselineRow = Get-RamSample "${rowName}:baseline-1-tab" $false
            for ($i = 1; $i -lt $tabCount; $i++) { Invoke-RamAction 'new_tab' }
            if (@(@((Get-RamState).windows)[0].tabs).Count -ne $tabCount) { throw "expected $tabCount tabs, state shows $(@(@((Get-RamState).windows)[0].tabs).Count)" }
        }
        'hidden-flood' {
            for ($i = 1; $i -lt $tabCount; $i++) { Invoke-RamAction 'new_tab' }
            if (@(@((Get-RamState).windows)[0].tabs).Count -ne $tabCount) { throw "expected $tabCount tabs" }
            # Tab 1 stays the visible one.
            if ($tabCount -gt 1) { Invoke-RamAction 'goto_tab:1' }
        }
        'hidden-anim' {
            # Give the shell and the animation time to come up.
            Start-Sleep -Seconds 4
        }
        'minimized' {
            Initialize-RamWin
        }
        'show_ms' {
            for ($i = 1; $i -lt $tabCount; $i++) { Invoke-RamAction 'new_tab' }
            if ($tabCount -lt 2) { throw 'show_ms needs at least 2 tabs' }
            Start-Sleep -Seconds 2
            $noPresents = $false
            for ($i = 0; $i -lt 20 -and -not $noPresents; $i++) {
                $target = $i % 2
                $before = Get-RamField (Get-RamTabSurface $target) 'presents'
                if ($null -eq $before) { $noPresents = $true; break }
                $sw = [Diagnostics.Stopwatch]::StartNew()
                if (-not (Invoke-GhosttyAction -Class $ramClass -Action ('goto_tab:' + ($target + 1)))) { Write-Host "INFO goto_tab:$($target + 1) was not performed" }
                $ms = $null
                while ($sw.Elapsed.TotalMilliseconds -lt 2000) {
                    $now = Get-RamField (Get-RamTabSurface $target) 'presents'
                    if ($null -ne $now -and [uint64]$now -gt [uint64]$before) { $ms = $sw.Elapsed.TotalMilliseconds; break }
                }
                if ($null -eq $ms) { Write-Host "INFO switch $($i + 1): no present within 2 s" } else { $showMs += $ms }
                Update-GuiLock $lock
                Start-Sleep -Milliseconds 400
            }
            if ($noPresents) {
                Write-Host 'INFO show_ms: the surface state has no presents field (build before Task 15): show_ms columns stay empty'
            } else {
                Write-Host ('INFO show_ms: {0} of 20 switches saw a present; ms: {1}' -f $showMs.Count, ((@($showMs | ForEach-Object { [math]::Round($_, 1) })) -join ' '))
            }
        }
    }

    # -Actions / -Sample ops: an action the app does not perform is reported, not fatal.
    function Invoke-RamOp([string]$Op) {
        if ($Op -match '^wait:(\d+(\.\d+)?)$') {
            Start-Sleep -Milliseconds ([int]([double]$Matches[1] * 1000))
            return
        }
        # Window handle ops, not IPC: the window of the process this script started.
        if ($Op -eq 'minimize') {
            Initialize-RamWin
            [void][GhosttyRam.Win]::ShowWindowAsync($hwnd, 6)
            Start-Sleep -Milliseconds 2500
            return
        }
        if ($Op -eq 'restore') {
            Initialize-RamWin
            [void][GhosttyRam.Win]::ShowWindowAsync($hwnd, 9)
            Start-Sleep -Milliseconds 2000
            return
        }
        if (-not (Invoke-GhosttyAction -Class $ramClass -Action $Op)) { Write-Host "INFO action '$Op' was not performed" }
        Start-Sleep -Milliseconds 700
    }
    $pointRows = @()
    if ($null -ne $baselineRow) { $pointRows += $baselineRow }
    if (-not $notApplicable) {
        foreach ($a in $Actions) { Invoke-RamOp $a }
        foreach ($pt in $samplePoints) {
            Invoke-RamOp $pt.Op
            $pointRows += (Get-RamSample "${rowName}:$($pt.Label)" $true)
        }
    }

    $singleRow = $null
    if ($notApplicable) {
        $singleRow = New-RamRow $rowName 'n/a' 'n/a'
    } elseif (-not $samplePoints.Count) {
        Start-Sleep -Seconds $IdleSeconds
        $singleRow = Get-RamSample $rowName $true
    }
    # The show times belong to the row that closes the run: the single row, or with an explicit -Sample the last sample row.
    if ($showMs.Count) {
        $target = if ($singleRow) { $singleRow } elseif ($pointRows.Count) { $pointRows[$pointRows.Count - 1] } else { $null }
        if ($target) {
            $target.ShowP50 = [math]::Round((Get-Percentile -Values $showMs -P 50), 1)
            $target.ShowP95 = [math]::Round((Get-Percentile -Values $showMs -P 95), 1)
        }
    }

    # R-M8-21: the GPU memory a hidden tab holds, against the gate for keeping the swap chain shrink.
    if ($Scenario -eq 'hidden-tabs' -and $null -ne $baselineRow -and $pointRows.Count -gt 1 -and $tabCount -gt 1 -and $null -ne $baselineRow.GpuDedicated) {
        $last = $pointRows[$pointRows.Count - 1]
        $hidden = $tabCount - 1
        $dDed = ($last.GpuDedicated - $baselineRow.GpuDedicated) / $hidden
        $dShr = ($last.GpuShared - $baselineRow.GpuShared) / $hidden
        $perTab = $dDed + $dShr
        $gate = if ($Maximized) { 30 } else { 8 }
        Write-Host ('INFO R-M8-21 hidden tab ({0}): {1:N1} MB GPU per hidden tab ({2:N1} dedicated + {3:N1} shared), {4} hidden tabs, from {5}' -f $(if ($Maximized) { 'maximized' } else { "${ClientWidth}x${ClientHeight} client" }), $perTab, $dDed, $dShr, $hidden, $last.Name)
        Write-Host ('INFO R-M8-21 gate: keep the shrink if a hidden tab holds >= {0} MB before the shrink ({1}); budget after the shrink <= 2 MB per hidden tab. Measured: {2:N1} MB -> {3}' -f $gate, $(if ($Maximized) { 'maximized at 1080p' } else { 'default size' }), $perTab, $(if ($perTab -ge $gate) { 'AT OR ABOVE the gate' } elseif ($perTab -le 2) { 'within the 2 MB budget' } else { 'below the gate, above the budget' }))
        $pc = (Get-RamTabSurface 1)
        $cp = Get-RamField $pc 'chain_px'
        if ($null -ne $cp) { Write-Host ('INFO chain_px of the surface in tab 2 (hidden): {0}' -f ($cp -join 'x')) }
    } elseif ($Scenario -eq 'hidden-tabs') {
        Write-Host 'INFO R-M8-21: GPU memory unavailable, no per-hidden-tab number'
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
    [IO.File]::WriteAllText($Csv, ($(if ($useGpu) { $gpuHeader } else { $ramHeader }) + "`n"), (New-Object Text.UTF8Encoding $false))
}
$today = Get-Date -Format 'yyyy-MM-dd'
function Write-CsvRow($Row) {
    $line = ConvertTo-CsvLine -Row $Row -Date $today -Commit $commit -Optimize $Optimize -Adapter $adapter -GpuColumns $useGpu
    [IO.File]::AppendAllText($Csv, $line + "`n", (New-Object Text.UTF8Encoding $false))
    Write-Output $line
}
if ($pointRows.Count -and -not $singleRow) {
    foreach ($p in $pointRows) { Write-CsvRow $p }
    return
}
if ($null -ne $beforeMb) {
    Write-CsvRow (New-RamRow 'close-10-before' $beforeMb $beforeWs)
    Write-Host ('INFO close-10: {0} MB after vs {1} MB before = {2:P1}' -f $singleRow.Private, $beforeMb, ($singleRow.Private / $beforeMb - 1))
}
foreach ($p in $pointRows) { Write-CsvRow $p }
Write-CsvRow $singleRow
