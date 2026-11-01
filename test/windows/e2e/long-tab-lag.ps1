# e2e: milestone=M8 timeout=1500 order=1230
# long-tab-lag: proves or kills H1 (D3D11 pacer drift with a continuously
# animating cursor shader) from diag-lag.md section 5.
#
# Run 1 (shader animation on): Ghostty with GHOSTTY_LATENCY_TRACE and
# GHOSTTY_D3D11_PACING_LOG, Git Bash -> zsh -f (bash when zsh is not installed),
# custom-shader = test/windows/configs/cursor-trail.glsl. Tab A runs
# `node lag-gen.js 600` (Claude-like output, focused, 10 min). During it: a
# top-level window of ours covers the Ghostty window for 60 s, the window is
# resized 20 times, tabs A and B are switched 50 times. Then 100 keys, 30 ms
# apart, at the prompt of tab A and of a fresh tab C. Per surface from the
# latency CSV: total, render_to_present, slot_wait, presents_between and the
# input/pty/parse stages; from the log: the slot wait of every frame of each
# key phase and the `d3d11 pacer resync ... drained=` lines.
# Verdict (printed): H1 confirmed / H1 killed / fixed. The scenario fails on
# `H1 confirmed` or a p50 difference A - C over 2 ms (budget Task 24 B4) unless
# GHOSTTY_LAG_NOGATE=1.
# Run 2 (control): the same with custom-shader-animation = false and half the
# generator time; reported, not gated (H1 predicts the lag is gone).
#
# Environment: GHOSTTY_LAG_SECS (generator seconds of run 1, default 600),
# GHOSTTY_LAG_NOGATE=1 (report only). Needs node on PATH (E2E-SKIP otherwise).
# The CSV columns named *_ns hold milliseconds. Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_latency.ps1')
. (Join-Path $PSScriptRoot '_backdrop.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'long-tab-lag' {
    if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { throw 'E2E-SKIP: node.exe is not on PATH (lag-gen.js needs it)' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $secs = if ($env:GHOSTTY_LAG_SECS) { [int]$env:GHOSTTY_LAG_SECS } else { 600 }
    $gen = (Join-Path $PSScriptRoot 'lag-gen.js').Replace([char]92, [char]47)
    $glsl = (Join-Path $script:WinDir 'configs\cursor-trail.glsl').Replace([char]92, [char]47)
    $trailCfg = (Get-Content -LiteralPath (Get-ConfigPath 'cursor-trail') -Raw -Encoding UTF8).Replace('cursor-trail.glsl', $glsl)

    # ---- log helpers ----------------------------------------------------------
    function Get-LogPos([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { $fs.Length } finally { $fs.Dispose() }
    }
    function Read-LogRange([string]$Path, [int64]$From, [int64]$To) {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($To -gt $fs.Length) { $To = $fs.Length }
            $n = [int]($To - $From)
            if ($n -le 0) { return '' }
            $buf = New-Object byte[] $n
            [void]$fs.Seek($From, 'Begin')
            $got = 0
            while ($got -lt $n) {
                $k = $fs.Read($buf, $got, $n - $got)
                if ($k -le 0) { break }
                $got += $k
            }
            [Text.Encoding]::UTF8.GetString($buf, 0, $got)
        } finally { $fs.Dispose() }
    }

    # Slot wait of every frame in a log excerpt (`d3d11 pacing slot_wait_ms=..`).
    function Get-PacingStats([string]$Text) {
        $w = New-Object 'System.Collections.Generic.List[double]'
        $timeouts = 0
        foreach ($m in [regex]::Matches($Text, 'd3d11 pacing slot_wait_ms=([0-9.]+) build_ms=([0-9.]+) slot_timeout=([01])')) {
            [void]$w.Add([double]::Parse($m.Groups[1].Value, $inv))
            if ($m.Groups[3].Value -eq '1') { $timeouts++ }
        }
        $n = $w.Count
        $zero = 0
        foreach ($v in $w) { if ($v -lt 0.1) { $zero++ } }
        $sorted = @($w | Sort-Object)
        [pscustomobject]@{
            Frames      = $n
            ZeroFrac    = $(if ($n) { $zero / $n } else { [double]::NaN })
            TimeoutFrac = $(if ($n) { $timeouts / $n } else { [double]::NaN })
            Slot50      = Get-Percentile $sorted 50
            Slot95      = Get-Percentile $sorted 95
        }
    }

    # `d3d11 pacer resync surface=.. drained=..` lines of one surface.
    function Get-ResyncStats([string]$Text, [int]$SurfaceId) {
        $n = 0; $maxDrained = 0; $sumSurplus = 0; $maxCapped = 0; $maxTimeouts = 0
        foreach ($m in [regex]::Matches($Text, 'd3d11 pacer resync surface=(\d+) pending=(\d+) drained=(\d+) surplus=(\d+) capped=(\d+) timeouts=(\d+)')) {
            if ([int]$m.Groups[1].Value -ne $SurfaceId) { continue }
            $n++
            $maxDrained = [Math]::Max($maxDrained, [int]$m.Groups[3].Value)
            $sumSurplus += [int]$m.Groups[4].Value
            $maxCapped = [Math]::Max($maxCapped, [int64]$m.Groups[5].Value)
            $maxTimeouts = [Math]::Max($maxTimeouts, [int64]$m.Groups[6].Value)
        }
        [pscustomobject]@{ Count = $n; MaxDrained = $maxDrained; SumSurplus = $sumSurplus; MaxCapped = $maxCapped; MaxTimeouts = $maxTimeouts }
    }

    # ---- ghostty state / shell helpers ------------------------------------------
    function Get-Win($G) {
        $r = Get-GhosttyState -Class $G.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        @($d.windows)[0]
    }
    function Wait-Win($G, [string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 10) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $w = Get-Win $G
            if ($w -and (& $Predicate $w)) { $w }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $(Get-Win $G | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Invoke-Act($G, [string]$Action) { [void](Invoke-GhosttyAction -Class $G.Class -Action $Action) }

    # Types a marker line until the shell of the focused tab runs it.
    function Wait-ShellRuns($G, [string]$Name) {
        $marker = Join-Path $G.Sandbox.Tmp $Name
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 40) {
            Send-Line $G.Hwnd ('echo ready > "$TEMP/{0}"' -f $Name)
            if (Wait-File $marker 6) { return }
        }
        throw "the shell of the focused tab did not run a typed line within 40 s ($Name)"
    }

    # zsh -f in the focused tab when Git for Windows ships it, else it stays bash.
    function Enter-Zsh($G, [string]$Name) {
        $bash = Find-GitBash
        $zsh = if ($bash) { Join-Path (Split-Path -Parent (Split-Path -Parent $bash)) 'usr\bin\zsh.exe' } else { $null }
        if ($zsh -and (Test-Path -LiteralPath $zsh)) {
            Send-Line $G.Hwnd 'exec /usr/bin/zsh -f'
            Start-Sleep -Seconds 2
            Wait-ShellRuns $G $Name
            return 'zsh'
        }
        'bash'
    }

    # A shader that failed to load leaves no continuous frames (animationWake is off): the run would prove nothing. FAIL, not SKIP.
    function Assert-ShaderLoaded($G, [string]$When) {
        $text = Read-LogRange $G.Log 0 ([int64]::MaxValue)
        $m = [regex]::Match($text, '[^\r\n]*error loading custom shaders[^\r\n]*')
        if ($m.Success) { throw ('the custom shader did not load ({0}): {1}' -f $When, $m.Value.Trim()) }
    }

    # ---- one measured key phase -------------------------------------------------
    function Measure-KeyPhase($G, [string]$Label, [int]$SurfaceId, [bool]$Animation, [double]$RefreshHz) {
        $cursor = Enter-LatencyInput $G
        try {
            $phaseSw = [Diagnostics.Stopwatch]::StartNew()
            $logFrom = Get-LogPos $G.Log
            $since = Get-NowNs
            $keys = @(for ($i = 0; $i -lt 100; $i++) { [string][char](97 + ($i % 26)) })
            $stamps = Send-TimedKeys $G $keys 30
            $after = Get-AfterStamps
            Start-Sleep -Milliseconds 800
            $logTo = Get-LogPos $G.Log
            $phaseSecs = $phaseSw.Elapsed.TotalSeconds
            $rows = @(Get-LatencyRows)
        } finally {
            Exit-LatencyInput $cursor
        }
        try { Invoke-SendInput -Hwnd $G.Hwnd -Keys 'ctrl+u' } catch { }
        $mine = @($rows | Where-Object { $_.Surface -eq $SurfaceId })
        if ($mine.Count -eq 0 -and $rows.Count -gt 0) {
            $ids = (@($rows | ForEach-Object { $_.Surface } | Sort-Object -Unique)) -join ','
            Write-E2eInfo "WARN $Label no trace rows for surface $SurfaceId (trace has surfaces $ids); using the rows of the phase"
            $mine = $rows
        }
        $samples = @(Get-Samples $mine 'key' $since $stamps $after)
        $pacing = Get-PacingStats (Read-LogRange $G.Log $logFrom $logTo)
        # With the animation on a frame is drawn on every vblank: far fewer frames in the phase means the shader did not animate (or the log has no pacing lines).
        $needed = 0.5 * $RefreshHz * $phaseSecs
        $inconclusive = $Animation -and ($pacing.Frames -lt $needed)
        function P50([string]$Prop) { Get-Percentile @($samples | ForEach-Object { [double]$_.$Prop } | Sort-Object) 50 }
        $totals = @($samples | ForEach-Object { [double]$_.Total } | Sort-Object)
        [pscustomobject]@{
            Label = $Label; Surface = $SurfaceId; N = $samples.Count
            Total50 = Get-Percentile $totals 50; Total95 = Get-Percentile $totals 95
            InputToWrite = P50 'InputToWrite'; WriteToOutput = P50 'WriteToOutput'; OutputToParsed = P50 'OutputToParsed'
            ParsedToRender = P50 'ParsedToRender'; SlotWait = P50 'SlotWait'; RenderToPresent = P50 'RenderToPresent'
            Presents = P50 'PresentsBetween'
            PhaseSecs = $phaseSecs; Needed = $needed; Inconclusive = $inconclusive
            Frames = $pacing.Frames; ZeroFrac = $pacing.ZeroFrac; TimeoutFrac = $pacing.TimeoutFrac
            LogSlot50 = $pacing.Slot50; LogSlot95 = $pacing.Slot95
            Samples = $samples
        }
    }

    function Format-Phase($P) {
        '{0,-9} surface {1} n={2,3} total p50 {3,7:F2} p95 {4,7:F2} | input_to_write {5:F2} write_to_output {6:F2} output_to_parsed {7:F2} parsed_to_render {8:F2} slot_wait {9:F2} render_to_present {10:F2} presents_between {11:F1} | log: {12} frames{17}, slot wait ~0 on {13:P0}, p50 {14:F2} p95 {15:F2} ms, timeouts {16:P1}' -f
            $P.Label, $P.Surface, $P.N, $P.Total50, $P.Total95, $P.InputToWrite, $P.WriteToOutput, $P.OutputToParsed,
            $P.ParsedToRender, $P.SlotWait, $P.RenderToPresent, $P.Presents, $P.Frames, $P.ZeroFrac, $P.LogSlot50, $P.LogSlot95, $P.TimeoutFrac, $(if ($P.Inconclusive) { ' (INCONCLUSIVE: need >= {0:F0})' -f $P.Needed } else { '' })
    }

    # H1 confirmed / H1 killed / fixed (diag-lag section 5).
    function Get-LagVerdict($A, $C, $Resync, [double]$PeriodMs) {
        $diff = $A.Total50 - $C.Total50
        if ($A.Inconclusive -or $C.Inconclusive) {
            return [pscustomobject]@{ Name = 'INCONCLUSIVE'; Diff = $diff; Detail = ('frames drawn during the key phases: A {0} (need >= {1:F0}), C {2} (need >= {3:F0}); the shader did not animate or the log has no pacing lines, so no verdict' -f $A.Frames, $A.Needed, $C.Frames, $C.Needed) }
        }
        $stages = [ordered]@{
            input_to_write   = $A.InputToWrite - $C.InputToWrite
            write_to_output  = $A.WriteToOutput - $C.WriteToOutput
            output_to_parsed = $A.OutputToParsed - $C.OutputToParsed
        }
        $worst = $null
        foreach ($k in $stages.Keys) { if ($null -eq $worst -or $stages[$k] -gt $stages[$worst]) { $worst = $k } }
        $zeroA = (-not [double]::IsNaN($A.ZeroFrac)) -and $A.ZeroFrac -ge 0.9
        $zeroC = (-not [double]::IsNaN($C.ZeroFrac)) -and $C.ZeroFrac -ge 0.9
        $resyncText = 'resyncs {0}, max drained {1}, surplus total {2}, max capped {3}' -f $Resync.Count, $Resync.MaxDrained, $Resync.SumSurplus, $Resync.MaxCapped
        if ($diff -ge $PeriodMs -and $zeroA -and -not $zeroC) {
            return [pscustomobject]@{ Name = 'H1 confirmed'; Diff = $diff; Detail = ('A is {0:F2} ms (>= 1 refresh = {1:F2} ms) slower than C, A slot wait ~0 on {2:P0} of frames, C on {3:P0}; {4}' -f $diff, $PeriodMs, $A.ZeroFrac, $C.ZeroFrac, $resyncText) }
        }
        if ($diff -le 2.0) {
            if ($Resync.Count -gt 0) {
                $note = if ($Resync.MaxDrained -le 2) { 'drained small' } else { 'a backlog of ' + $Resync.MaxDrained + ' signals was found and drained' }
                return [pscustomobject]@{ Name = 'fixed'; Diff = $diff; Detail = ('A ~ C (difference {0:F2} ms) with the animation proven ({1} and {2} frames in the key phases) and a resync line seen; {3}; {4}' -f $diff, $A.Frames, $C.Frames, $note, $resyncText) }
            }
            return [pscustomobject]@{ Name = 'H1 killed'; Diff = $diff; Detail = ('same distributions (difference {0:F2} ms), no pacer resync line in the log (a build without Task 1, or no info log); {1}' -f $diff, $resyncText) }
        }
        if ($zeroA -and -not $zeroC) {
            return [pscustomobject]@{ Name = 'H1 signature present, below one refresh (not confirmed)'; Diff = $diff; Detail = ('A is {0:F2} ms slower (< 1 refresh = {1:F2} ms), A slot wait ~0 on {2:P0} of frames, C on {3:P0}; {4}' -f $diff, $PeriodMs, $A.ZeroFrac, $C.ZeroFrac, $resyncText) }
        }
        [pscustomobject]@{ Name = 'H1 killed'; Diff = $diff; Detail = ('A is {0:F2} ms slower than C but the slot wait does not explain it (A ~0 on {1:P0}, C on {2:P0}); the stage that differs most: {3} ({4:F2} ms); {5}' -f $diff, $A.ZeroFrac, $C.ZeroFrac, $worst, $stages[$worst], $resyncText) }
    }

    # ---- the perturbations of tab A's run --------------------------------------
    function Invoke-Cover($G, [int]$Seconds) {
        $r = New-Object GhosttyE2e.Win+RECT
        [void][GhosttyE2e.Win]::GetWindowRect($G.Hwnd, [ref]$r)
        $f = New-BackdropForm $r.Left $r.Top ($r.Right - $r.Left) ($r.Bottom - $r.Top)
        try {
            Show-BackdropForm $f
            Invoke-Pump ($Seconds * 1000)
        } finally {
            $f.Close()
            $f.Dispose()
        }
        if (-not (Set-ForegroundSafe -Hwnd $G.Hwnd)) { throw 'E2E-SKIP: could not take the foreground back after the cover phase' }
    }
    function Invoke-Resizes($G, [int]$Count) {
        $r = New-Object GhosttyE2e.Win+RECT
        [void][GhosttyE2e.Win]::GetWindowRect($G.Hwnd, [ref]$r)
        $w0 = $r.Right - $r.Left
        $h0 = $r.Bottom - $r.Top
        $widths = [int[]](720, 1000, 840, 1100, 780)
        $heights = [int[]](480, 700, 560, 760, 520)
        for ($i = 0; $i -lt $Count; $i++) {
            Set-WindowSize $G.Hwnd $widths[$i % $widths.Count] $heights[($i * 2 + 1) % $heights.Count]
            Start-Sleep -Milliseconds 400
        }
        Set-WindowSize $G.Hwnd $w0 $h0
    }
    function Invoke-TabSwitches($G, [int]$Count) {
        for ($i = 0; $i -lt $Count; $i++) {
            Invoke-Act $G $(if ($i % 2 -eq 0) { 'goto_tab:2' } else { 'goto_tab:1' })
            Start-Sleep -Milliseconds 200
        }
        Invoke-Act $G 'goto_tab:1'
        [void](Wait-Win $G 'tab A active again' { param($w) $w.active_tab -eq 0 })
    }

    # ---- one run ------------------------------------------------------------------
    function Invoke-LagRun([string]$Tag, [bool]$Animation, [int]$GenSecs, [double]$RefreshHz) {
        $extra = $trailCfg.TrimEnd() + "`ncustom-shader-animation = " + $Animation.ToString().ToLowerInvariant() + "`n"
        $env:GHOSTTY_D3D11_PACING_LOG = '1'
        try {
            $g = Start-LatencyGhostty "long-tab-lag-$Tag" -ExtraConfig $extra
        } finally {
            Remove-Item Env:\GHOSTTY_D3D11_PACING_LOG -ErrorAction SilentlyContinue
        }
        $csv = $script:LatCsv
        $w = Get-Win $g
        $aId = [int]@(@($w.tabs)[0].surfaces)[0].id
        $shell = Enter-Zsh $g "gt-lag-zsh-$Tag-a.txt"
        Assert-ShaderLoaded $g 'after start'
        Write-E2eInfo "$Tag run: animation=$Animation, shell=$shell, generator $GenSecs s, surface A = $aId"

        # Tab B (idle, hidden behind A), then A again with the focus.
        Invoke-Act $g 'new_tab'
        [void](Wait-Win $g 'tab B' { param($w) @($w.tabs).Count -eq 2 })
        Invoke-Act $g 'goto_tab:1'
        [void](Wait-Win $g 'tab A active' { param($w) $w.active_tab -eq 0 })
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }

        $done = Join-Path $g.Sandbox.Tmp "gt-lag-done-$Tag.txt"
        Remove-Item -LiteralPath $done -Force -ErrorAction SilentlyContinue
        Send-Line $g.Hwnd ('node "{0}" {1}; echo done > "$TEMP/gt-lag-done-{2}.txt"' -f $gen, $GenSecs, $Tag)

        # Offsets (s) of the perturbations, in proportion to the generator time.
        $coverSecs = [Math]::Min(60, [int]($GenSecs * 0.1))
        $events = @(
            @{ At = $GenSecs * 0.10; Name = 'cover' },
            @{ At = $GenSecs * 0.25; Name = 'resize' },
            @{ At = $GenSecs * 0.42; Name = 'switch' }
        )
        $next = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $done)) {
            if ($g.Process.HasExited) { throw 'ghostty exited during the generator run' }
            if ($sw.Elapsed.TotalSeconds -gt $GenSecs + 120) { throw "the generator did not end within $($GenSecs + 120) s" }
            if ($next -lt $events.Count -and $sw.Elapsed.TotalSeconds -ge $events[$next].At) {
                $name = $events[$next].Name
                $next++
                $t = $sw.Elapsed.TotalSeconds
                switch ($name) {
                    'cover' { Invoke-Cover $g $coverSecs }
                    'resize' { Invoke-Resizes $g 20 }
                    'switch' { Invoke-TabSwitches $g 50 }
                }
                Write-E2eInfo ('{0}: {1} done at t+{2:F0} s ({3:F1} s long)' -f $Tag, $name, $t, ($sw.Elapsed.TotalSeconds - $t))
                continue
            }
            Start-Sleep -Milliseconds 250
        }
        if ($sw.Elapsed.TotalSeconds -lt [Math]::Min(20, $GenSecs / 2)) { throw "lag-gen.js ended after $([int]$sw.Elapsed.TotalSeconds) s (node missing in the shell?)" }
        if ($next -lt $events.Count) { Write-E2eInfo "WARN $Tag run: the generator ended before $($events.Count - $next) perturbation(s) ran" }
        Start-Sleep -Seconds 1
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
        Save-Evidence "$Tag-after-gen" $g -Window

        # Keys at the prompt of tab A, then in a fresh tab C.
        $a = Measure-KeyPhase $g 'A (long)' $aId $Animation $RefreshHz
        Invoke-Act $g 'new_tab'
        $w = Wait-Win $g 'tab C' { param($w) @($w.tabs).Count -eq 3 -and $w.active_tab -eq 2 }
        $cId = [int]@(@($w.tabs)[2].surfaces)[0].id
        if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
        [void](Enter-Zsh $g "gt-lag-zsh-$Tag-c.txt")
        $c = Measure-KeyPhase $g 'C (fresh)' $cId $Animation $RefreshHz

        Assert-ShaderLoaded $g 'end of run'
        $resync = Get-ResyncStats (Read-LogRange $g.Log 0 ([int64]::MaxValue)) $aId
        Save-Evidence "$Tag-end" $g -Window
        Stop-OwnGhostty
        Start-Sleep -Seconds 2

        # Keep the raw trace and log of the run (the next run starts new ones).
        $keep = Get-EvidenceDir
        foreach ($pair in @(@($csv, "long-tab-lag-$Tag-latency.csv"), @($g.Log, "long-tab-lag-$Tag-ghostty.log"))) {
            if ($keep -and (Test-Path -LiteralPath $pair[0])) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $keep $pair[1]) -Force }
            Remove-Item -LiteralPath $pair[0] -Force -ErrorAction SilentlyContinue
        }
        [pscustomobject]@{ Tag = $Tag; A = $a; C = $c; Resync = $resync }
    }

    function Publish-Run($R, [double]$PeriodMs, [switch]$Control) {
        foreach ($p in $R.A, $R.C) { Write-E2eInfo ('{0}: {1}' -f $R.Tag, (Format-Phase $p)) }
        foreach ($p in $R.A, $R.C) { [void](Publish-Latency ("long-tab-lag-{0}-{1}" -f $R.Tag, ($p.Label -replace '[^A-Za-z]', '')) $p.Samples) }
        $v = Get-LagVerdict $R.A $R.C $R.Resync $PeriodMs
        if ($Control) {
            # No continuous frames in the control: both slot waits may be ~0 whatever the cause, so it is never given a verdict name.
            Write-E2eInfo ('{0}: control, numbers only (not a verdict): A - C p50 = {1:F2} ms; slot wait ~0 on A {2:P0}, C {3:P0}; frames A {4}, C {5}' -f $R.Tag, $v.Diff, $R.A.ZeroFrac, $R.C.ZeroFrac, $R.A.Frames, $R.C.Frames)
            return [pscustomobject]@{ Name = 'control'; Diff = ($R.A.Total50 - $R.C.Total50); Detail = '' }
        }
        Write-E2eInfo ('{0}: VERDICT {1} - {2}' -f $R.Tag, $v.Name, $v.Detail)
        $v
    }

    # ---- scenario ---------------------------------------------------------------
    $hz = (Get-GpuInfo).Hz
    $hzEff = if ($hz -gt 1) { [double]$hz } else { 60.0 }
    $period = 1000.0 / $hzEff
    Write-E2eInfo ('display {0} Hz, one refresh {1:F2} ms' -f $hz, $period)

    $main = Invoke-LagRun 'anim' $true $secs $hzEff
    foreach ($p in $main.A, $main.C) {
        if ($p.N -lt 20) { throw "$($p.Label): only $($p.N) complete key samples of 100, the comparison is not meaningful" }
    }
    $vMain = Publish-Run $main $period

    $control = Invoke-LagRun 'control' $false ([Math]::Max(120, [int]($secs / 2))) $hzEff
    foreach ($p in $control.A, $control.C) {
        if ($p.N -lt 20) { Write-E2eInfo "WARN control $($p.Label): only $($p.N) complete key samples" }
    }
    if ($control.A.N -ge 20 -and $control.C.N -ge 20) {
        $vCtl = Publish-Run $control $period -Control
        $diffCtl = $control.A.Total50 - $control.C.Total50
        if ($vMain.Name -eq 'INCONCLUSIVE') {
            Write-E2eInfo 'main run INCONCLUSIVE: no comparison with the control'
        } else {
        Write-E2eInfo ('control (animation=false): A - C = {0:F2} ms; main (animation=true): A - C = {1:F2} ms. H1 predicts the lag is gone in the control: {2}' -f
            $diffCtl, $vMain.Diff, $(if ($diffCtl -le 2.0 -and $vMain.Diff -gt 2.0) { 'yes, consistent with H1' } elseif ($diffCtl -gt 2.0) { 'no, the lag stays without animation' } else { 'no lag in either run' }))
        }
    }

    $keep = Get-EvidenceDir
    if ($keep) {
        $lines = @("verdict: $($vMain.Name)", $vMain.Detail, '', (Format-Phase $main.A), (Format-Phase $main.C))
        Set-Content -LiteralPath (Join-Path $keep 'long-tab-lag-summary.txt') -Value $lines -Encoding ASCII
    }

    if ($vMain.Name -eq 'INCONCLUSIVE') { throw "long tab lag: INCONCLUSIVE - $($vMain.Detail)" }
    if ($env:GHOSTTY_LAG_NOGATE -ne '1') {
        if ($vMain.Name -eq 'H1 confirmed') { throw "long tab lag: H1 confirmed - $($vMain.Detail)" }
        if ($vMain.Diff -gt 2.0) { throw ('long tab lag: key echo of the long tab is {0:F2} ms slower at p50 than a fresh tab (budget 2 ms): {1}' -f $vMain.Diff, $vMain.Detail) }
    }
}
