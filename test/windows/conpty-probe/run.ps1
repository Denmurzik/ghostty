<#
.SYNOPSIS
Probes which escape sequences survive the inbox ConPTY on their way to
Ghostty, with and without PSEUDOCONSOLE_PASSTHROUGH_MODE.

.DESCRIPTION
For every case (cases/probe-<name>.sh: `printf` only, then `exec sleep 600`)
and every flags value, one Debug ghostty.exe is started through the e2e
harness (shared desktop lock, own sandbox, `class = ghostty-cprobe-<hex>`,
GHOSTTY_WIN32_CONPTY_FLAGS=<flags>) running the case as its command. Arrival
is judged by one oracle per case, all of them observations of Ghostty, never
of the shell:

  kitty-apc  a frame dump (GHOSTTY_D3D11_DUMP) holds the image's #ff00ff
             pixels; the debug log line `kitty graphics response` is kept as
             a second witness
  osc9       log: `deferred action=.desktop_notification`
  osc777     log: `deferred action=.desktop_notification`
  osc133     log: `deferred action=.command_finished`
  osc8       Ctrl held, the pointer over the link: log `deferred action=.mouse_over_link`
             and the system cursor is IDC_HAND
  osc22      the pointer over the surface: the system cursor is IDC_CROSS
             (the sequence asks for `crosshair`)

Verdict per row: arrived (oracle satisfied), dropped (no trace of the
sequence in Ghostty), mangled (a trace, but not the one the oracle needs: the
sequence reached the parser in another shape).

The rows go to <OutDir>\results.csv (case, flags, run, verdict, evidence) and
to the console. Exit code: 1 when a case does not exist or a run failed
outright (no window, no oracle could be evaluated); 0 otherwise - "dropped"
is a result, not a failure.

Safety: GUI only through Invoke-E2eScenario (desktop lock, isolated
sandbox/config/class, only own processes killed). The pointer is moved over
the probe's own window for osc8/osc22.

.PARAMETER Flags
GHOSTTY_WIN32_CONPTY_FLAGS values to run (default 0 and 8).

.PARAMETER Only
Case names without the `probe-` prefix (osc9, osc777, osc133, osc8, osc22,
kitty-apc). Default: all.

.PARAMETER Repeat
Runs of every (case, flags) pair, to see determinism.

.PARAMETER OutDir
Where results.csv and the evidence logs go (default %TEMP%\conpty-probe).

.EXAMPLE
powershell -NoProfile -File test/windows/conpty-probe/run.ps1 -Only osc9 -Flags 0
#>
param(
    [string[]]$Flags = @(0, 8),
    [string[]]$Only,
    [ValidateRange(1, 10)][int]$Repeat = 1,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# powershell -File passes "a,b" as one string.
$Flags = @($Flags | ForEach-Object { $_ -split "," } | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($Only) { $Only = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ }) }
$caseDir = Join-Path $PSScriptRoot 'cases'
$names = @(if ($Only) {
    @($Only | ForEach-Object { ($_ -replace '^probe-', '') -replace '\.sh$', '' })
} else {
    @(Get-ChildItem -LiteralPath $caseDir -Filter 'probe-*.sh' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName -replace '^probe-', '' } | Sort-Object)
})
foreach ($n in $names) {
    if (-not (Test-Path -LiteralPath (Join-Path $caseDir "probe-$n.sh"))) {
        Write-Output "no case: $n (expected cases/probe-$n.sh)"
        exit 1
    }
}
if ($names.Count -eq 0) {
    Write-Output 'no case: cases/ holds no probe-*.sh'
    exit 1
}

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'conpty-probe' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$csv = Join-Path $OutDir 'results.csv'

. (Join-Path $PSScriptRoot '..\e2e\_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

if (-not ('GhosttyProbe.Native' -as [type])) {
    Add-Type -Namespace GhosttyProbe -Name Native -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT pt; }
[DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern short GetKeyState(int vk);
[DllImport("user32.dll")] public static extern IntPtr LoadCursorW(IntPtr inst, IntPtr name);

public static IntPtr CurrentCursor() {
    CURSORINFO ci = new CURSORINFO();
    ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
    return GetCursorInfo(ref ci) ? ci.hCursor : IntPtr.Zero;
}
// Top pixel row (from the first row of the bitmap data, bottom-up BMP) holding a pixel near (r, g, b):
// returns the row counted from the top of the image, or -1.
public static int FirstRowWithColor(byte[] bmp, int r, int g, int b, int tol) {
    int w = BitConverter.ToInt32(bmp, 18);
    int hRaw = BitConverter.ToInt32(bmp, 22);
    int h = Math.Abs(hRaw);
    for (int y = 0; y < h; y++) {
        int row = hRaw < 0 ? y : h - 1 - y;
        int o = 54 + row * w * 4;
        for (int x = 0; x < w; x++, o += 4) {
            if (Math.Abs(bmp[o + 2] - r) <= tol && Math.Abs(bmp[o + 1] - g) <= tol && Math.Abs(bmp[o] - b) <= tol) return y;
        }
    }
    return -1;
}
public static IntPtr SystemCursor(int id) { return LoadCursorW(IntPtr.Zero, (IntPtr)id); }

// Pixels of a 32-bit BI_RGB bitmap (54 byte header) within tol of (r, g, b).
public static int CountColor(byte[] bmp, int r, int g, int b, int tol) {
    int n = 0;
    for (int o = 54; o + 3 < bmp.Length; o += 4) {
        if (Math.Abs(bmp[o + 2] - r) <= tol && Math.Abs(bmp[o + 1] - g) <= tol && Math.Abs(bmp[o] - b) <= tol) n++;
    }
    return n;
}
"@
}

# Physical pixels everywhere: the state op, the frame dump and the pointer all
# speak them, a DPI-unaware process would see scaled coordinates.
[void][GhosttyProbe.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))

$IDC_ARROW = 32512; $IDC_CROSS = 32515; $IDC_HAND = 32649

# Starts ghostty.exe running one case as its command, like Start-E2eGhostty
# but with the probe's class and the ConPTY flags in the environment.
function Start-ProbeGhostty([string]$CasePath, [int]$ConptyFlags) {
    $bash = Find-GitBash
    if (-not $bash) { throw 'E2E-SKIP: Git Bash is not installed, the probe cases are bash scripts' }
    $sbx = $script:Sbx
    $class = 'ghostty-cprobe-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $configHome = Join-Path $sbx.Home '.config'
    $dir = Join-Path $configHome 'ghostty'
    New-Item -ItemType Directory -Force -Path $dir, $sbx.Dump | Out-Null
    $extra = @(
        'quit-after-last-window-closed = true',
        'background = #102030',
        'foreground = #e0e0e0',
        'confirm-close-surface = false',
        ('command = direct:"{0}" "{1}"' -f ($bash -replace '\\', '/'), ($CasePath -replace '\\', '/'))
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $dir 'config.ghostty'), (New-GhosttyConfigText -Class $class -Extra $extra), (New-Object Text.UTF8Encoding $false))

    $vars = [ordered]@{
        USERPROFILE                = $sbx.Home
        HOME                       = $sbx.Home
        LOCALAPPDATA               = $sbx.Local
        APPDATA                    = $sbx.Roaming
        TEMP                       = $sbx.Tmp
        TMP                        = $sbx.Tmp
        XDG_CONFIG_HOME            = $configHome
        GHOSTTY_D3D11_DUMP         = $sbx.Dump
        GHOSTTY_WIN32_TEST_IPC     = '1'
        GHOSTTY_WIN32_CONPTY_FLAGS = [string]$ConptyFlags
    }
    $saved = @{}
    foreach ($n in $vars.Keys) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    try {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $vars[$n], 'Process') }
        $proc = Start-Process -FilePath $script:Exe -WorkingDirectory $script:Root -PassThru -ArgumentList @("--class=$class")
    } finally {
        foreach ($n in $vars.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
    Register-OwnGhostty -ProcessId $proc.Id

    $cmdLine = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine
    if ($cmdLine -notlike "*--class=$class*") { throw "ghostty was not started with --class=${class}: $cmdLine" }

    $hwnd = [IntPtr]::Zero
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 20) {
        $proc.Refresh()
        if ($proc.HasExited) { throw "ghostty exited early with code $($proc.ExitCode)" }
        $first = Find-GhosttyWindows $proc.Id | Select-Object -First 1
        if ($first) { $hwnd = $first; break }
        Start-Sleep -Milliseconds 20
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'no main window within 20 s' }
    $global:E2eLast = [pscustomobject]@{
        Process = $proc; Pid = $proc.Id; Hwnd = $hwnd; Sandbox = $sbx; Class = $class
        Log     = Join-Path $sbx.Local 'ghostty\logs\ghostty.log'
        Dump    = Join-Path $sbx.Dump 'surface-1.bmp'
    }
    $global:E2eLast
}

function Get-LogLines($G, [string]$Pattern) {
    if (-not (Test-Path -LiteralPath $G.Log)) { return @() }
    $fs = $null
    try {
        $fs = [IO.File]::Open($G.Log, 'Open', 'Read', 'ReadWrite')
        $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    @($text -split "`r?`n" | Where-Object { $_ -match $Pattern })
}

# The surface rect (client coordinates of the top-level window) from the state op.
function Get-SurfaceRect($G) {
    $st = Get-GhosttyState -Class $G.Class
    $w = @($st.windows)[0]
    $s = @(@($w.tabs)[0].surfaces)[0]
    @($s.rect | ForEach-Object { [int]$_ })
}

# Pointer to the surface at the given offset; returns the system cursor handle after WM_SETCURSOR ran.
function Get-CursorAt($G, [int]$Dx, [int]$Dy) {
    $r = Get-SurfaceRect $G
    Send-MouseMove -Hwnd $G.Hwnd -X ($r[0] + $Dx) -Y ($r[1] + $Dy) -Steps 3
    Start-Sleep -Milliseconds 250
    [GhosttyProbe.Native]::CurrentCursor()
}

# One probe run: returns @{ Verdict; Evidence }.
function Invoke-ProbeRun([string]$Name, [string]$CasePath, [int]$ConptyFlags) {
    $g = Start-ProbeGhostty $CasePath $ConptyFlags
    # The case is done writing once its `exec sleep` runs (the shell is replaced).
    $sleeper = Wait-ChildNamed $g @('sleep.exe') 30
    if (-not $sleeper) { throw 'the case never reached its sleep (bash did not run the script)' }
    Start-Sleep -Milliseconds 2500

    $evidence = New-Object System.Collections.Generic.List[string]
    $arrived = $false
    $trace = $false
    switch ($Name) {
        'kitty-apc' {
            # The dump file is named after the surface id; take the newest one.
            $g.Dump = Wait-Until -TimeoutSec 8 -PollMs 200 -Condition {
                Get-ChildItem -LiteralPath $g.Sandbox.Dump -Filter 'surface-*.bmp' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc | Select-Object -Last 1 -ExpandProperty FullName
            }
            if (-not $g.Dump) { throw 'no frame dump was written' }
            $hit = Wait-Dump $g { param($d) [GhosttyProbe.Native]::CountColor($d.Bytes, 255, 0, 255, 8) -ge 64 } 6
            $resp = @(Get-LogLines $g 'kitty graphics')
            foreach ($l in $resp) { $evidence.Add($l) }
            if ($hit) {
                $arrived = $true
                $evidence.Add(('frame dump: {0} pixels #ff00ff' -f [GhosttyProbe.Native]::CountColor($hit.Bytes, 255, 0, 255, 8)))
            } else {
                $evidence.Add('frame dump: no #ff00ff pixels')
                # Did the terminal place the image anyway? The case prints "PROBE kitty sent"
                # after it: with 4 image rows the text lands on row 4, without it on row 1.
                $d = Read-Dump $g.Dump
                $cellH = 0
                $cm = Get-LogLines $g 'cell = \.\{ \.width = \d+, \.height = \d+' | Select-Object -First 1
                if ($cm -match 'cell = \.\{ \.width = \d+, \.height = (\d+)') { $cellH = [int]$Matches[1] }
                $y = [GhosttyProbe.Native]::FirstRowWithColor($d.Bytes, 224, 224, 224, 24)
                if ($y -ge 0 -and $cellH -gt 0) {
                    $textRow = [int][Math]::Floor(($y - 4) / $cellH)
                    $evidence.Add("text 'PROBE kitty sent' is on grid row $textRow (image placement moves it to row 4, a dropped APC leaves it on row 1)")
                    if ($textRow -ge 3) { $trace = $true }
                } else {
                    $evidence.Add('text row not measurable')
                }
                $trace = $trace -or ($resp.Count -gt 0)
            }
        }
        { $_ -in 'osc9', 'osc777' } {
            $log = Wait-Until -TimeoutSec 4 -PollMs 250 -Condition { $l = @(Get-LogLines $g 'action=.?desktop_notification'); if ($l.Count) { $l } }
            if ($log) { $arrived = $true; foreach ($l in $log) { $evidence.Add($l) } }
        }
        'osc133' {
            $log = Wait-Until -TimeoutSec 4 -PollMs 250 -Condition { $l = @(Get-LogLines $g 'action=.?command_finished'); if ($l.Count) { $l } }
            if ($log) { $arrived = $true; foreach ($l in $log) { $evidence.Add($l) } }
            foreach ($l in @(Get-LogLines $g 'command took')) { $evidence.Add($l) }
        }
        'osc8' {
            $hand = [GhosttyProbe.Native]::SystemCursor($IDC_HAND)
            $cur = [IntPtr]::Zero
            # The link is on row 0; the row height is not known, so scan down it.
            # Ghostty only treats an OSC 8 cell as a link while Ctrl is held.
            # Key state only reaches a focused window.
            $fg = Set-ForegroundSafe -Hwnd $g.Hwnd
            Start-Sleep -Milliseconds 300
            $fgNow = [GhosttyProbe.Native]::GetForegroundWindow() -eq $g.Hwnd
            $evidence.Add("foreground set=$fg now=$fgNow")
            [GhosttyProbe.Native]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
            try {
                Start-Sleep -Milliseconds 200
                foreach ($dy in 20, 14, 26, 8, 32) {
                    $cur = Get-CursorAt $g 60 $dy
                    $evidence.Add(('dy={0} cursor=0x{1:x} ctrl={2}' -f $dy, $cur.ToInt64(), [GhosttyProbe.Native]::GetKeyState(0x11)))
                    if ($cur -eq $hand) { $evidence.Add("Ctrl held, pointer at +60,+$dy is IDC_HAND"); break }
                }
            } finally {
                [GhosttyProbe.Native]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
            }
            $log = @(Get-LogLines $g 'action=.?mouse_over_link')
            foreach ($l in $log) { $evidence.Add($l) }
            if ($cur -eq $hand -or $log.Count) { $arrived = $true }
            if (-not $arrived) { $evidence.Add(('cursor handle 0x{0:x} (hand 0x{1:x})' -f $cur.ToInt64(), $hand.ToInt64())) }
        }
        'osc22' {
            $cross = [GhosttyProbe.Native]::SystemCursor($IDC_CROSS)
            $cur = Get-CursorAt $g 120 80
            if ($cur -eq $cross) {
                $arrived = $true
                $evidence.Add('pointer over the surface is IDC_CROSS')
            } else {
                $evidence.Add(('cursor handle 0x{0:x} (cross 0x{1:x}, arrow 0x{2:x}, ibeam 0x{3:x})' -f $cur.ToInt64(), $cross.ToInt64(),
                    [GhosttyProbe.Native]::SystemCursor($IDC_ARROW).ToInt64(), [GhosttyProbe.Native]::SystemCursor(32513).ToInt64()))
            }
        }
        default { throw "no oracle for case $Name" }
    }

    # Anything about the sequence in the log that is not the oracle: the
    # parser saw it in another shape.
    $other = @(Get-LogLines $g '(?i)(unimplemented|invalid|unknown|failed|error|ignoring).*(osc|apc|kitty|hyperlink|notif|shape|semantic)')
    foreach ($l in $other) { $evidence.Add("log: $l") }
    if (-not $arrived -and $other.Count) { $trace = $true }

    # Keep the log excerpt next to the csv for the write-up.
    if (Test-Path -LiteralPath $g.Log) {
        Copy-Item -LiteralPath $g.Log -Destination (Join-Path $OutDir ("{0}-flags{1}-{2}.log" -f $Name, $ConptyFlags, $script:RunNo)) -Force
    }
    Save-Evidence -Tag "$Name-f$ConptyFlags" -G $g -Window

    $verdict = if ($arrived) { 'arrived' } elseif ($trace) { 'mangled' } else { 'dropped' }
    @{ Verdict = $verdict; Evidence = ($evidence -join ' | ') }
}

if (-not (Test-Path -LiteralPath $csv)) {
    Set-Content -LiteralPath $csv -Value 'case,flags,run,verdict,evidence' -Encoding UTF8
}

$failed = 0
foreach ($name in $names) {
    foreach ($f in $Flags) {
        for ($run = 1; $run -le $Repeat; $run++) {
            $script:RunNo = $run
            $global:ProbeCur = @{ Name = $name; Case = (Join-Path $caseDir "probe-$name.sh"); Flags = $f; Run = $run; Row = $null }
            Invoke-E2eScenario "conpty-probe-$name-f$f-r$run" {
                $c = $global:ProbeCur
                $c.Row = Invoke-ProbeRun $c.Name $c.Case $c.Flags
            }
            $row = $global:ProbeCur.Row
            if ($null -eq $row) {
                $failed++
                Write-Output "ROW $name flags=$f run=$run -> no verdict (run failed)"
                continue
            }
            $ev = ($row.Evidence -replace '"', "'") -replace "[\r\n]+", ' '
            Add-Content -LiteralPath $csv -Value ('{0},{1},{2},{3},"{4}"' -f $name, $f, $run, $row.Verdict, $ev) -Encoding UTF8
            Write-Output ("ROW {0} flags={1} run={2} -> {3}" -f $name, $f, $run, $row.Verdict)
        }
    }
}

exit $(if ($failed) { 1 } else { 0 })
