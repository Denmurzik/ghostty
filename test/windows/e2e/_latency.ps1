# Shared helpers of the latency probes (input-latency, tui-latency,
# output-latency). Dot-source it after _common.ps1. Keep this file ASCII
# only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
#
# The probes only measure: ghostty.exe runs with GHOSTTY_LATENCY_TRACE=<csv>
# (src/os/windows_latency.zig), the harness sends real SendInput keys and
# wheel notches from this process on a QPC schedule and stamps each one
# right before the call, and the stage tables are built from the CSV.
# Ghostty's clock (std.Io awake clock) is QPC in nanoseconds, the same clock
# as [Stopwatch]::GetTimestamp, so the dispatch delay is a plain difference.
#
# Variants: GHOSTTY_E2E_EXE selects the build (ReleaseFast: zig-out-rf);
# GHOSTTY_WIN32_CONPTY_FLAGS / GHOSTTY_WIN32_CONPTY_DLL (set before running
# the scenario) select the ConPTY variant, GHOSTTY_LAT_VARIANT names it in
# the baseline row (default derived from the two variables); GHOSTTY_LAT_SHELL=cmd
# runs input-latency and output-latency against cmd.exe instead of Git Bash.
#
# Rows go to %TEMP%\ghostty-latency/runs.csv. Only GHOSTTY_LAT_RECORD_BASELINE=1
# appends them to the tracked docs/windows/latency-baseline.csv;
# GHOSTTY_LAT_BUILD_VARIANT names the code state in the `variant` column
# (default `asis`: the tree as committed). Gates (Assert-LatencyGate) fail the
# scenario on ReleaseFast builds and only report on Debug.

Set-StrictMode -Version Latest

# Numbers in the CSV and in the messages use a decimal point.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

if (-not ('GhosttyLat.Native' -as [type])) {
    Add-Type -Namespace GhosttyLat -Name Native -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint type);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint ms);
[DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint ms);
[DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long c);
[DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long f);

// QPC stamps (ns) taken right after each SendInput returned.
public static long[] LastAfter;

static long freq;
public static long NowNs() {
    long c;
    if (freq == 0) QueryPerformanceFrequency(out freq);
    QueryPerformanceCounter(out c);
    // Same arithmetic as Zig's awake clock for the 10 MHz case, exact otherwise.
    return (long)((decimal)c * 1000000000m / (decimal)freq);
}

// Sleeps (coarse) and then spins until QPC reaches target.
static void WaitUntil(long target) {
    while (true) {
        long left = target - NowNs();
        if (left <= 0) return;
        if (left > 2500000) Thread.Sleep(1);
    }
}

static INPUT Key(ushort vk, uint flags) {
    INPUT i = new INPUT();
    i.type = 1;
    i.u.ki.wVk = vk;
    i.u.ki.wScan = (ushort)MapVirtualKeyW(vk, 0);
    i.u.ki.dwFlags = flags;
    return i;
}

static void Check(IntPtr hwnd) {
    if (GetForegroundWindow() != hwnd) throw new InvalidOperationException("the target window lost the foreground");
}

// One key press per entry (ctrl[i]: with Ctrl), `gapMs` apart, scheduled from
// a common start. Returns the QPC stamp (ns) taken right before each SendInput.
public static long[] SendKeys(IntPtr hwnd, ushort[] vk, bool[] ctrl, int gapMs) {
    long[] stamps = new long[vk.Length];
    long[] after = new long[vk.Length];
    LastAfter = after;
    long start = NowNs() + 50000000L;
    for (int n = 0; n < vk.Length; n++) {
        WaitUntil(start + (long)n * gapMs * 1000000L);
        Check(hwnd);
        List<INPUT> l = new List<INPUT>();
        if (ctrl[n]) l.Add(Key(0x11, 0));
        l.Add(Key(vk[n], 0));
        l.Add(Key(vk[n], 2));
        if (ctrl[n]) l.Add(Key(0x11, 2));
        INPUT[] arr = l.ToArray();
        stamps[n] = NowNs();
        if (SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT))) != arr.Length) throw new InvalidOperationException("SendInput failed");
        after[n] = NowNs();
    }
    return stamps;
}

// `count` wheel notches of `delta` (120 = up, -120 = down), `gapMs` apart,
// at the current cursor position. Returns the stamps.
public static long[] SendWheel(IntPtr hwnd, int count, int delta, int gapMs) {
    long[] stamps = new long[count];
    long[] after = new long[count];
    LastAfter = after;
    long start = NowNs() + 50000000L;
    for (int n = 0; n < count; n++) {
        WaitUntil(start + (long)n * gapMs * 1000000L);
        Check(hwnd);
        INPUT i = new INPUT();
        i.type = 0;
        i.u.mi.mouseData = unchecked((uint)delta);
        i.u.mi.dwFlags = 0x0800;
        INPUT[] arr = new INPUT[] { i };
        stamps[n] = NowNs();
        if (SendInput(1, arr, Marshal.SizeOf(typeof(INPUT))) != 1) throw new InvalidOperationException("SendInput failed");
        after[n] = NowNs();
    }
    return stamps;
}
"@ -UsingNamespace 'System.Threading', 'System.Collections.Generic'
}

$script:LatCsv = $null
$script:LatVariant = $null
$script:BgCpu = -1

function Get-LatencyVariant {
    if ($env:GHOSTTY_LAT_VARIANT) { return $env:GHOSTTY_LAT_VARIANT }
    $parts = @()
    if ($env:GHOSTTY_WIN32_CONPTY_DLL) { $parts += 'dll-' + (Split-Path -Leaf (Split-Path -Parent $env:GHOSTTY_WIN32_CONPTY_DLL)) } else { $parts += 'inbox' }
    $parts += $(if ($env:GHOSTTY_WIN32_CONPTY_FLAGS) { $env:GHOSTTY_WIN32_CONPTY_FLAGS } else { '0' })
    $parts -join '-'
}

# Git Bash by default, cmd.exe with GHOSTTY_LAT_SHELL=cmd; the tracer needs
# a build that has it.
function Start-LatencyGhostty([string]$Scenario) {
    $csv = Join-Path $script:Sbx.Root 'latency.csv'
    $script:LatCsv = $csv
    $script:LatVariant = Get-LatencyVariant
    $env:GHOSTTY_LATENCY_TRACE = $csv
    $env:GHOSTTY_LATENCY_TAG = $Scenario
    try {
        if ($env:GHOSTTY_LAT_SHELL -eq 'cmd') {
            # cmd.exe edits its line inside conhost: the ConPTY stage without
            # a shell process of our own. input-latency and output-latency use it.
            $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
            Set-WindowLayout $g.Hwnd '00000409'
            Start-Sleep -Seconds 3
            $script:LatVariant += '-cmd'
        } else {
            $g = Start-BashE2e
        }
    } finally {
        Remove-Item Env:\GHOSTTY_LATENCY_TRACE -ErrorAction SilentlyContinue
        Remove-Item Env:\GHOSTTY_LATENCY_TAG -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $csv)) { throw "no latency trace at ${csv}: this build has no tracer" }
    # What the ConPTY overrides did (a rejected flag value falls back to 0).
    if (Test-Path -LiteralPath $g.Log) {
        foreach ($l in @(Select-String -LiteralPath $g.Log -Pattern 'conpty|CreatePseudoConsole' | ForEach-Object { $_.Line })) {
            Write-E2eInfo "ghostty.log: $l"
        }
    }
    $g
}

# Foreground, cursor over the surface (wheel messages go to the window under
# the cursor). Returns the cursor position to restore.
function Enter-LatencyInput($G) {
    if (-not (Set-ForegroundSafe -Hwnd $G.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    $old = New-Object GhosttyLat.Native+POINT
    [void][GhosttyLat.Native]::GetCursorPos([ref]$old)
    $r = New-Object GhosttyLat.Native+RECT
    [void][GhosttyLat.Native]::GetWindowRect($G.Hwnd, [ref]$r)
    [void][GhosttyLat.Native]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
    [void][GhosttyLat.Native]::timeBeginPeriod(1)
    # Other work on the machine skews the numbers: note the load.
    try {
        $c = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples
        $script:BgCpu = [int](($c | Measure-Object CookedValue -Average).Average)
    } catch { $script:BgCpu = -1 }
    $old
}

function Exit-LatencyInput($Cursor) {
    [void][GhosttyLat.Native]::timeEndPeriod(1)
    if ($Cursor) { [void][GhosttyLat.Native]::SetCursorPos($Cursor.X, $Cursor.Y) }
}

function Get-VkOf([string]$Name) {
    switch ($Name) {
        'space' { 0x20 }
        'enter' { 0x0D }
        default { [int][char]$Name.ToUpperInvariant() }
    }
}

# 'j', 'space', 'ctrl+e' -> stamps (ns) of each press.
function Send-TimedKeys($G, [string[]]$Keys, [int]$GapMs) {
    $vk = New-Object 'uint16[]' $Keys.Count
    $ctrl = New-Object 'bool[]' $Keys.Count
    for ($i = 0; $i -lt $Keys.Count; $i++) {
        $k = $Keys[$i]
        if ($k -like 'ctrl+*') { $ctrl[$i] = $true; $k = $k.Substring(5) }
        $vk[$i] = Get-VkOf $k
    }
    [GhosttyLat.Native]::SendKeys($G.Hwnd, $vk, $ctrl, $GapMs)
}

function Send-TimedWheel($G, [int]$Count, [int]$Delta, [int]$GapMs) {
    [GhosttyLat.Native]::SendWheel($G.Hwnd, $Count, $Delta, $GapMs)
}

# Stamps taken after each SendInput returned (of the last Send-Timed* call).
function Get-AfterStamps { [GhosttyLat.Native]::LastAfter }

function Get-NowNs { [GhosttyLat.Native]::NowNs() }

# --- CSV --------------------------------------------------------------------

# Rows of the trace written so far (a half-written last line is dropped).
function Get-LatencyRows([string]$Path = $script:LatCsv) {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
    } finally {
        $fs.Dispose()
    }
    # GHOSTTY_LAT_KEEP=<dir>: keep a copy of the raw trace for inspection.
    if ($env:GHOSTTY_LAT_KEEP) {
        New-Item -ItemType Directory -Force -Path $env:GHOSTTY_LAT_KEEP | Out-Null
        [IO.File]::WriteAllText((Join-Path $env:GHOSTTY_LAT_KEEP ($script:Sbx.Name + '-' + $script:LatVariant + '.csv')), $text)
    }
    $lines = @($text -split "`n")
    if ($lines.Count -gt 0 -and -not $text.EndsWith("`n")) { $lines = $lines[0..($lines.Count - 2)] }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($l in $lines | Select-Object -Skip 1) {
        $f = $l.TrimEnd("`r").Split(',')
        if ($f.Count -lt 21) { continue }
        [pscustomobject]@{
            Build = $f[0]; Tag = $f[1]; Kind = $f[2]; Complete = ($f[3] -eq '1'); Surface = [int]$f[4]
            T0 = [int64]$f[5]
            InputToWrite = [double]::Parse($f[6], $inv); WriteToOutput = [double]::Parse($f[7], $inv)
            OutputToParsed = [double]::Parse($f[8], $inv); ParsedToRender = [double]::Parse($f[9], $inv)
            SlotWait = [double]::Parse($f[10], $inv); RenderToPresent = [double]::Parse($f[11], $inv)
            Total = [double]::Parse($f[12], $inv)
            Writes = [int]$f[13]; WriteBytes = [int64]$f[14]; OutputBytes = [int64]$f[15]
            Slices = [int]$f[16]; Yields = [int]$f[17]; PresentsBetween = [int]$f[18]
            WheelMessages = [int64]$f[19]; ScrollCalls = [int64]$f[20]
        }
    }
}

function Get-Percentile([double[]]$Sorted, [int]$Pct) {
    if ($Sorted.Count -eq 0) { return [double]::NaN }
    $idx = [int][Math]::Ceiling($Sorted.Count * $Pct / 100.0) - 1
    $Sorted[[Math]::Max(0, $idx)]
}

# Completed samples of `kind` that opened at or after `SinceNs`. `StampNs`
# (the harness stamps of the inputs) adds the dispatch delay: each sample is
# paired with the last stamp at or before its t0.
function Get-Samples($Rows, [string]$Kind, [int64]$SinceNs, [int64[]]$StampNs, [int64[]]$AfterNs) {
    $s = @($Rows | Where-Object { $_.Kind -eq $Kind -and $_.Complete -and $_.T0 -ge $SinceNs })
    foreach ($r in $s) {
        $stamp = $null
        $call = 0.0
        if ($StampNs) {
            for ($i = 0; $i -lt $StampNs.Count; $i++) {
                if ($StampNs[$i] -le $r.T0) {
                    $stamp = $StampNs[$i]
                    if ($AfterNs -and $i -lt $AfterNs.Count) { $call = ($AfterNs[$i] - $StampNs[$i]) / 1e6 }
                } else { break }
            }
        }
        $dispatch = if ($null -ne $stamp) { ($r.T0 - $stamp) / 1e6 } else { 0.0 }
        $r | Add-Member -NotePropertyName SendCall -NotePropertyValue $call -Force
        $own = $r.InputToWrite + $r.OutputToParsed + $r.ParsedToRender + $r.RenderToPresent
        $r | Add-Member -NotePropertyName Dispatch -NotePropertyValue $dispatch -Force
        $r | Add-Member -NotePropertyName Owned -NotePropertyValue $own -Force
        $r | Add-Member -NotePropertyName E2e -NotePropertyValue ($dispatch + $r.Total) -Force
    }
    $s
}

$script:Stages = [ordered]@{
    send_call        = 'SendCall'
    dispatch         = 'Dispatch'
    input_to_write   = 'InputToWrite'
    conpty           = 'WriteToOutput'
    output_to_parsed = 'OutputToParsed'
    parsed_to_render = 'ParsedToRender'
    slot_wait        = 'SlotWait'
    render_to_present = 'RenderToPresent'
    ghostty_owned    = 'Owned'
    total            = 'Total'
    e2e              = 'E2e'
}

function Get-StageStats($Samples) {
    foreach ($name in $script:Stages.Keys) {
        $prop = $script:Stages[$name]
        $v = @($Samples | ForEach-Object { [double]$_.$prop } | Sort-Object)
        [pscustomobject]@{
            Stage = $name
            P50 = Get-Percentile $v 50; P95 = Get-Percentile $v 95
            Max = $(if ($v.Count) { $v[-1] } else { [double]::NaN }); N = $v.Count
        }
    }
}

function Get-GpuInfo {
    $v = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentRefreshRate } | Select-Object -First 1
    if (-not $v) { $v = Get-CimInstance Win32_VideoController | Select-Object -First 1 }
    [pscustomobject]@{ Adapter = ($v.Name -replace ',', ' '); Hz = [int]$v.CurrentRefreshRate }
}

# Prints a stage table and appends its rows to the run log in %TEMP%, and to
# docs/windows/latency-baseline.csv when GHOSTTY_LAT_RECORD_BASELINE=1.
function Publish-Latency([string]$Scenario, $Samples) {
    $stats = @(Get-StageStats $Samples)
    $build = if ($Samples) { @($Samples)[0].Build } else { 'unknown' }
    $gpu = Get-GpuInfo
    $commit = (& git -C $script:Root rev-parse --short HEAD 2>$null)
    $date = Get-Date -Format 'yyyy-MM-dd'
    $header = 'date,commit,optimize,adapter,refresh_hz,conpty,variant,scenario,stage,p50_ms,p95_ms,max_ms,n'
    $variant = if ($env:GHOSTTY_LAT_BUILD_VARIANT) { $env:GHOSTTY_LAT_BUILD_VARIANT } else { 'asis' }
    $lines = foreach ($s in $stats) {
        '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9:F3},{10:F3},{11:F3},{12}' -f $date, $commit, $build, $gpu.Adapter, $gpu.Hz,
            $script:LatVariant, $variant, $Scenario, $s.Stage, $s.P50, $s.P95, $s.Max, $s.N
    }
    $outs = @(Join-Path (Join-Path $env:TEMP 'ghostty-latency') 'runs.csv')
    if ($env:GHOSTTY_LAT_RECORD_BASELINE -eq '1') { $outs += Join-Path $script:Root 'docs\windows\latency-baseline.csv' }
    foreach ($out in $outs) {
        $dir = Split-Path -Parent $out
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        if (-not (Test-Path -LiteralPath $out)) { Set-Content -LiteralPath $out -Value $header -Encoding ASCII }
        Add-Content -LiteralPath $out -Value $lines -Encoding ASCII
    }
    Write-E2eInfo ("latency $Scenario build=$build conpty=$($script:LatVariant) hz=$($gpu.Hz) n=$(@($Samples).Count) bg-cpu=$($script:BgCpu)%")
    foreach ($s in $stats) {
        Write-E2eInfo ('  {0,-18} p50 {1,8:F3}  p95 {2,8:F3}  max {3,8:F3}  n {4}' -f $s.Stage, $s.P50, $s.P95, $s.Max, $s.N)
    }
    $stats
}

# Value of one stage in a stats list.
function Get-Stage($Stats, [string]$Name) { @($Stats | Where-Object { $_.Stage -eq $Name })[0] }

# The latency gate of one stage's p95: a miss throws on a ReleaseFast build
# and is only reported on Debug (whose target column is $DebugLimitMs).
# $What names the gate in the message.
function Assert-LatencyGate($Stats, $Samples, [string]$What, [string]$Stage, [double]$LimitMs, [double]$DebugLimitMs) {
    $s = Get-Stage $Stats $Stage
    if (-not $s -or $s.N -eq 0) { throw "latency gate ${What}: no $Stage samples" }
    $build = @($Samples)[0].Build
    $debug = $build -eq 'debug'
    $limit = if ($debug) { $DebugLimitMs } else { $LimitMs }
    $ok = $s.P95 -le $limit
    Write-E2eInfo ('gate {0}: {1} p95 {2:F3} ms <= {3} ms ({4}): {5}' -f $What, $Stage, $s.P95, $limit, $build, $(if ($ok) { 'ok' } else { 'MISS' }))
    if (-not $ok -and -not $debug) { throw ('latency gate {0} missed: {1} p95 {2:F3} ms > {3} ms' -f $What, $Stage, $s.P95, $limit) }
}

function Stop-LatencyShellProgram($G, [string[]]$Keys) {
    Invoke-SendInput -Hwnd $G.Hwnd -Keys $Keys
}
