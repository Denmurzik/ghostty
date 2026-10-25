# resize-while-streaming: 200 SetWindowPos calls while a child streams
# output. A watchdog keeps sending WM_NULL (2000 ms timeout): the window must
# answer throughout, and the run must end within 10 s of the last resize
# (closing the window then ends the process).
# The measurements are reported whether it passes or not. A hang means SPEC
# section 6.4 (fallback) applies.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'resize-while-streaming' {
    $count = 200
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'stream') -NoDump:(-not $env:GHOSTTY_E2E_DUMP)
    if (-not (Wait-ChildNamed $g @('cmd.exe') 15)) { throw 'the streaming cmd.exe never started' }
    # Let the stream get going. The frame dump is off: reading every
    # frame back would add its own cost to the timings measured here
    # (set GHOSTTY_E2E_DUMP=1 to turn it on).
    Start-Sleep -Milliseconds 2000

    # Outer window sizes, wandering between small and large.
    $widths = [int[]](420, 900, 640, 1200, 520, 1000, 760, 1100)
    $heights = [int[]](320, 700, 480, 800, 380, 650, 560, 760)

    # The resizing runs on a worker thread, so a SetWindowPos that never
    # returns cannot stop this watchdog.
    $resizer = New-Object GhosttyE2e.Win+Resizer
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $resizer.Start($g.Hwnd, $count, $widths, $heights)

    $probes = 0
    $maxAnswerMs = 0L
    $unresponsive = 0
    $lastDone = 0
    $lastProgress = [Diagnostics.Stopwatch]::StartNew()
    $hung = $false
    $tooSlow = $false
    while (-not $resizer.Finished -and -not $resizer.WindowGone) {
        $ms = 0L
        $ok = [GhosttyE2e.Win]::Responsive($g.Hwnd, 2000, [ref]$ms)
        $probes++
        if ($ms -gt $maxAnswerMs) { $maxAnswerMs = $ms }
        if (-not $ok -and [GhosttyE2e.Win]::IsWindow($g.Hwnd)) { $unresponsive++ }
        if ($resizer.Done -ne $lastDone) {
            $lastDone = $resizer.Done
            $lastProgress.Restart()
        } elseif ($lastProgress.Elapsed.TotalSeconds -gt 20) {
            $hung = $true
            break
        }
        if ($g.Process.HasExited) { break }
        # 200 resizes at the expected ~400 ms each take 80 s: stop at 150 s.
        if ($watch.Elapsed.TotalSeconds -gt 150) {
            $tooSlow = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    $loopMs = $watch.ElapsedMilliseconds

    $done = $resizer.Done
    $avg = if ($done) { [int]($resizer.TotalCallMs / $done) } else { 0 }
    $ended = $resizer.WindowGone -or $g.Process.HasExited
    Write-E2eInfo ("{0} of {1} resizes in {2} ms (SetWindowPos avg {3} ms, max {4} ms); {5} WM_NULL probes, max answer {6} ms, {7} unanswered; stream ended during the loop: {8}" -f
        $done, $count, $loopMs, $avg, $resizer.MaxCallMs, $probes, $maxAnswerMs, $unresponsive, $ended)
    Save-Evidence 'after-loop' $g

    if ($hung) {
        throw "HANG: resize $($done + 1) did not return for 20 s ($done done; WM_NULL unanswered $unresponsive of $probes probes, max $maxAnswerMs ms) - SPEC section 6.4 fallback"
    }
    if ($tooSlow) {
        throw "only $done of $count resizes in 150 s (SetWindowPos avg $avg ms, max $($resizer.MaxCallMs) ms; WM_NULL unanswered $unresponsive of $probes probes, max answer $maxAnswerMs ms)"
    }
    if ($unresponsive -gt 0) {
        throw "window did not answer WM_NULL within 2000 ms $unresponsive of $probes times (max answer $maxAnswerMs ms; $done resizes in $loopMs ms)"
    }

    # The stream (2M lines) outlasts the loop by minutes, so "the run ends"
    # is: the window answers again right after the loop, and closing it ends
    # the process within 10 s.
    $ms = 0L
    if ($g.Process.HasExited) {
        Write-E2eInfo 'the stream finished during the loop'
    } else {
        $answers = [GhosttyE2e.Win]::Responsive($g.Hwnd, 2000, [ref]$ms)
        if (-not $answers) { throw "the window does not answer WM_NULL right after the resize loop (waited 2000 ms)" }
        Write-E2eInfo "window answers after the loop in $ms ms"
        [void]$g.Process.CloseMainWindow()
        $exit = Wait-ProcessExit $g 10
        Write-E2eInfo "ghostty exited $($exit.Ms) ms after closing at the end of the loop: $($exit.Exited)"
        if (-not $exit.Exited) { throw 'ghostty still running 10 s after the window was closed at the end of the resize loop' }
    }
    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
}
