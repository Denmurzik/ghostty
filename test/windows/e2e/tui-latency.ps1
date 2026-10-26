# tui-latency: (b1) key navigation, (b2) mouse wheel and (b3) a wheel burst in
# `less` (alternate-scroll and --mouse) and `vim -u NONE -c 'set mouse=a'` on a
# 50 000 line file. Real SendInput keys and MOUSEEVENTF_WHEEL notches over the
# surface. Gates (ReleaseFast, Task 37): Ghostty-owned p95 <= 6 ms for b1/b2
# and, for plain less, the last notch of the b3 burst presented within 50 ms.
# The shell-side stage (vim, less --mouse) is recorded, not gated. A missing
# less or vim skips that half.
# e2e: milestone=M2 timeout=300 order=151
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_latency.ps1')

Invoke-E2eScenario 'tui-latency' {
    $g = Start-LatencyGhostty 'tui-latency'
    $tmp = $g.Sandbox.Tmp
    $cursor = $null
    try {
        # What exists in this Git Bash.
        $have = @{}
        foreach ($p in 'less', 'vim') {
            $f = Join-Path $tmp "gt-has-$p.txt"
            Send-Line $g.Hwnd "(command -v $p >/dev/null && echo yes || echo no) > `"`$TEMP/gt-has-$p.txt`""
            $have[$p] = (Wait-File $f 15) -and ((Get-Content -LiteralPath $f -Raw).Trim() -eq 'yes')
            Write-E2eInfo "$p available: $($have[$p])"
        }
        if (-not $have.less -and -not $have.vim) { throw 'E2E-SKIP: neither less nor vim is installed in Git Bash' }

        $done = Join-Path $tmp 'gt-big-done.txt'
        Send-Line $g.Hwnd 'seq 1 50000 | sed "s/$/ the quick brown fox jumps over the lazy dog 0123456789/" > "$TEMP/gt-big.txt"; echo done > "$TEMP/gt-big-done.txt"'
        if (-not (Wait-File $done 60)) { throw 'the 50 000 line file was not generated' }

        $cursor = Enter-LatencyInput $g

        # One measurement block. $Keys: the b1 key sequence; Wheel: whether to
        # run b2/b3. $Tag names the rows.
        $script:LatGates = @()
        $script:LatMisses = @()
        function Measure-Tui($Tag, [string[]]$Keys, [bool]$Wheel) {
            if ($Keys) {
                $since = Get-NowNs
                $stamps = Send-TimedKeys $g $Keys 150
                $after = Get-AfterStamps
                Start-Sleep -Milliseconds 800
                $rows = @(Get-LatencyRows)
                $s = @(Get-Samples $rows 'key' $since $stamps $after | Where-Object { $_.Writes -gt 0 })
                Write-E2eInfo "$Tag b1: $($s.Count) of $($Keys.Count) key samples"
                if ($s.Count -gt 0) {
                    $st = Publish-Latency "b1-$Tag" $s
                    $script:LatGates += ,@($st, $s, "b1-$Tag owned", 'ghostty_owned', 6, 20)
                } else {
                    $script:LatMisses += "b1-$Tag closed no key sample"
                }
            }
            if ($Wheel) {
                # b2: 60 notches 50 ms apart.
                $rows0 = @(Get-LatencyRows)
                $since = Get-NowNs
                $stamps = Send-TimedWheel $g 60 -120 50
                $after = Get-AfterStamps
                Start-Sleep -Milliseconds 800
                $rows = @(Get-LatencyRows)
                $s = @(Get-Samples $rows 'wheel' $since $stamps $after | Where-Object { $_.Writes -gt 0 })
                Write-E2eInfo "$Tag b2: $($s.Count) of 60 wheel samples"
                if ($s.Count -eq 0) { $script:LatMisses += "b2-$Tag closed no wheel sample" }
                if ($s.Count -gt 0) {
                    $st = Publish-Latency "b2-$Tag" $s
                    $script:LatGates += ,@($st, $s, "b2-$Tag owned", 'ghostty_owned', 6, 20)
                    $inWindow = @($rows | Where-Object { $_.T0 -ge $since })
                    $before = @($rows0 | Select-Object -Last 1)
                    $m0 = if ($before) { $before[0].WheelMessages } else { 0 }
                    $c0 = if ($before) { $before[0].ScrollCalls } else { 0 }
                    $last = $inWindow[-1]
                    $w = ($s | Measure-Object Writes -Average).Average
                    $b = ($s | Measure-Object WriteBytes -Average).Average
                    $sl = ($s | Measure-Object Slices -Average).Average
                    Write-E2eInfo ("$Tag wheel coalescing: WM_MOUSEWHEEL +{0} scrollCallback +{1} (60 sent); per notch writes {2:F2} bytes {3:F1} slices {4:F2}" -f
                        ($last.WheelMessages - $m0), ($last.ScrollCalls - $c0), $w, $b, $sl)
                }
                # b3: 30 notches 8 ms apart (back up); the last notch to the last present.
                $since = Get-NowNs
                $stamps = Send-TimedWheel $g 30 120 8
                $after = Get-AfterStamps
                Start-Sleep -Milliseconds 1500
                $rows = @(Get-LatencyRows)
                $all = @($rows | Where-Object { $_.Kind -eq 'wheel' -and $_.T0 -ge $since })
                $inc = @($all | Where-Object { -not $_.Complete }).Count
                $lastRow = if ($all) { $all[-1] } else { $null }
                if ($lastRow -and $lastRow.Complete) {
                    Write-E2eInfo ("$Tag b3: last notch -> last present {0:F3} ms ({1} wheel rows, {2} incomplete)" -f $lastRow.Total, $all.Count, $inc)
                    $one = @(Get-Samples $rows 'wheel' $since $stamps $after | Select-Object -Last 1)
                    $st = Publish-Latency "b3-$Tag" $one
                    if ($Tag -eq 'less') { $script:LatGates += ,@($st, $one, 'b3-less burst', 'total', 50, 150) }
                } else {
                    Write-E2eInfo "$Tag b3: the last notch did not close a sample ($($all.Count) wheel rows, $inc incomplete)"
                    $script:LatMisses += "b3-${Tag}: the last notch did not close a sample"
                }
            }
        }

        $lessKeys = @(for ($i = 0; $i -lt 25; $i++) { 'j', 'k', 'space', 'b' })
        $vimKeys = @(for ($i = 0; $i -lt 34; $i++) { 'j', 'ctrl+e', 'ctrl+d' })[0..99]

        # GHOSTTY_LAT_PROGRAMS=less,less-mouse,vim limits the run (default: all).
        $want = if ($env:GHOSTTY_LAT_PROGRAMS) { $env:GHOSTTY_LAT_PROGRAMS -split ',' } else { @('less', 'less-mouse', 'vim') }

        if ($have.less -and $want -contains 'less') {
            Send-Line $g.Hwnd 'less "$TEMP/gt-big.txt"'
            Start-Sleep -Milliseconds 3000
            Measure-Tui 'less' $lessKeys $true
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'q'
            Start-Sleep -Milliseconds 800
        }
        if ($have.less -and $want -contains 'less-mouse') {
            Send-Line $g.Hwnd 'less --mouse "$TEMP/gt-big.txt"'
            Start-Sleep -Milliseconds 3000
            Measure-Tui 'less-mouse' $null $true
            Invoke-SendInput -Hwnd $g.Hwnd -Keys 'q'
            Start-Sleep -Milliseconds 800
        }
        if ($have.vim -and $want -contains 'vim') {
            Send-Line $g.Hwnd "vim -u NONE -c 'set mouse=a' `"`$TEMP/gt-big.txt`""
            Start-Sleep -Milliseconds 4000
            Measure-Tui 'vim' $vimKeys $true
            Invoke-SendInput -Hwnd $g.Hwnd -Keys (@('esc') + (ConvertTo-KeyList ':q!') + 'enter')
            Start-Sleep -Milliseconds 800
        }

        # Gates after every program ran, so one miss does not hide the rest.
        $missed = @($script:LatMisses)
        foreach ($g1 in $script:LatGates) {
            try { Assert-LatencyGate @g1 } catch { $missed += $_.Exception.Message }
        }
        if ($missed) { throw ($missed -join '; ') }
    } finally {
        Exit-LatencyInput $cursor
    }
}
