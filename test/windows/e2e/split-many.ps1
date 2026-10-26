# e2e: milestone=M2 timeout=300 order=250 surfaces=16
# split-many: 15 alternating splits give 16 surfaces whose visible rects
# neither overlap nor go negative, with no error in the log and a window
# that still answers. Pacing (pre-flight 22): four panes stream while 20 keys
# are typed into a fifth, with the latency tracer on. Close (pre-flight 13):
# `close_window` with the four streams still running hides the window
# within 300 ms and a second window of the process stays responsive.
#
# The tracer keeps ONE global open sample (src/os/windows_latency.zig), so
# a sample opened by the typed pane may be closed by a present of a
# streaming pane. Rows are therefore filtered by the `surface` column (the
# surface that presented) and only the typed pane's rows count: samples lost
# to that cross-closing are missing, never wrongly attributed.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
. (Join-Path $PSScriptRoot '_latency.ps1')
. (Join-Path $PSScriptRoot '_stream.ps1')

Invoke-E2eScenario 'split-many' {
    $g = Start-LatencyGhostty 'split-many'
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }

    Wait-SurfaceCount $g 1 | Out-Null
    for ($i = 0; $i -lt 15; $i++) {
        Invoke-SplitAction $g $(if ($i % 2 -eq 0) { 'new_split:right' } else { 'new_split:down' })
    }
    $st = Wait-SurfaceCount $g 16 30
    $boxes = Get-SurfaceBoxes $st
    Assert-NoOverlap $boxes
    $visible = @($boxes | Where-Object { $_.Visible })
    Write-E2eInfo "16 surfaces, $($visible.Count) visible, smallest $((($visible | Measure-Object W -Minimum).Minimum))x$((($visible | Measure-Object H -Minimum).Minimum))"
    foreach ($x in $boxes) {
        if ($x.W -lt 0 -or $x.H -lt 0) { throw "surface $($x.Id) has a negative size $($x.W)x$($x.H)" }
        if (-not $x.Visible -and ($x.W -gt 0 -and $x.H -gt 0)) { throw "surface $($x.Id) is hidden with a non-empty rect" }
    }

    $ms = 0L
    if (-not [GhosttyE2e.Win]::Responsive($g.Hwnd, 2000, [ref]$ms)) { throw 'the window did not answer WM_NULL within 2 s with 16 panes' }
    Write-E2eInfo "WM_NULL answered in $ms ms"
    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "error lines in ghostty.log after 16 splits: $($errors -join ' | ')" }

    # --- pacing: 4 streaming panes, 20 keys in a fifth ---------------------
    $typed = @($boxes | Where-Object { $_.Focused })
    if ($typed.Count -ne 1) { throw 'expected one focused pane for the typing' }
    $typed = $typed[0]
    $streamers = @($boxes | Where-Object { $_.Visible -and $_.Id -ne $typed.Id } | Select-Object -First 4)
    if ($streamers.Count -lt 4) { throw "only $($streamers.Count) visible panes to stream into" }

    $null = New-CheckedStream (Join-Path $g.Sandbox.Tmp 'gt-stream.txt') 4
    foreach ($s in $streamers) {
        Invoke-SplitAction $g 'text:while :; do cat "$TEMP/gt-stream.txt"; done\r' -Surface $s.CoreId
    }
    Start-Sleep -Seconds 2

    $cursor = Enter-LatencyInput $g
    try {
        $keys = @(for ($i = 0; $i -lt 20; $i++) { [string][char](97 + ($i % 26)) })
        $since = Get-NowNs
        $stamps = Send-TimedKeys $g $keys 150
        $after = Get-AfterStamps
        Start-Sleep -Milliseconds 800
        $rows = @(Get-LatencyRows | Where-Object { $_.Surface -eq $typed.Id })
        $samples = @(Get-Samples $rows 'key' $since $stamps $after)
        Write-E2eInfo "typed pane $($typed.Id): $($samples.Count) complete key samples of 20"
        if ($samples.Count -lt 5) { throw "only $($samples.Count) key samples of the typed pane closed" }

        $keyToPresent = @($samples | ForEach-Object { [double]$_.E2e } | Sort-Object)
        # pty output -> present of the echo (Task 36 scenario c2).
        $outToPresent = @($samples | ForEach-Object { [double]($_.Total - $_.InputToWrite - $_.WriteToOutput) } | Sort-Object)
        $keyP95 = Get-Percentile $keyToPresent 95
        $outP95 = Get-Percentile $outToPresent 95
        $build = @($samples)[0].Build
        Write-E2eInfo ("pacing build=$build keypress->present p95 {0:F1} ms, output->present p95 {1:F1} ms" -f $keyP95, $outP95)
        if ($build -eq 'ReleaseFast') {
            if ($keyP95 -gt 33) { throw "keypress->present p95 $keyP95 ms with 4 streaming panes (limit 33 ms)" }
            if ($outP95 -gt 20) { throw "output->present p95 $outP95 ms of the typed pane (limit 20 ms)" }
        } else {
            Write-E2eInfo "build ${build}: pacing recorded, not gated"
        }
    } finally {
        Exit-LatencyInput $cursor
    }

    # --- close with the streams still running -------------------------------
    # A second window of the same process, opened through the IPC op.
    $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ v = 1; op = 'new-window'; args = @() }
    if ($r.PSObject.Properties['code'] -and $r.code -ne 0) { throw "new-window failed: $($r.stderr)" }
    $second = Wait-Until -TimeoutSec 10 -PollMs 100 -Condition {
        @(Find-GhosttyWindows $g.Pid | Where-Object { $_ -ne $g.Hwnd }) | Select-Object -First 1
    }
    if (-not $second) { throw 'the second window never appeared' }
    $second = [IntPtr]$second

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-SplitAction $g 'close_window' -Surface $streamers[0].CoreId
    $hiddenMs = -1
    $worst = 0L
    $slow = 0
    while ($sw.Elapsed.TotalSeconds -lt 15) {
        if ($hiddenMs -lt 0 -and -not [GhosttyE2e.Win]::IsWindowVisible($g.Hwnd)) { $hiddenMs = $sw.ElapsedMilliseconds }
        $ans = 0L
        if (-not [GhosttyE2e.Win]::Responsive($second, 100, [ref]$ans)) { $slow++ }
        if ($ans -gt $worst) { $worst = $ans }
        if (-not [GhosttyE2e.Win]::IsWindow($g.Hwnd)) { break }
        Start-Sleep -Milliseconds 10
    }
    Write-E2eInfo "first window hidden after $hiddenMs ms; second window worst WM_NULL $worst ms, $slow timeouts"
    if ($hiddenMs -lt 0 -or $hiddenMs -gt 300) { throw "the closing window was not invisible within 300 ms (took $hiddenMs ms)" }
    if ($slow -gt 0 -or $worst -gt 100) { throw "the second window stalled during the teardown (worst $worst ms, $slow timeouts; limit 100 ms)" }
}
