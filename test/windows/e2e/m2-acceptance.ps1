# e2e: milestone=M2 timeout=240 order=495
# m2-acceptance: idle CPU of a one-surface window over 30 s (recorded), then
# one window with 3 tabs and 4 splits in the active tab, captured dark and
# light (the test IPC `color-scheme` op) at 96 / 144 / 192 dpi (the `dpi` op),
# plus a maximized and a fullscreen capture, for the M2 screenshot review
# (-EvidenceDir). Checks only that the state matches the layout it built.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'm2-acceptance' {
    $dir = Join-Path $script:Sbx.Home '.config\ghostty'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $utf8 = New-Object Text.UTF8Encoding $false
    $light = Join-Path $dir 'gt-light'
    $dark = Join-Path $dir 'gt-dark'
    [IO.File]::WriteAllText($light, "background = #fafafa`nforeground = #202020`n", $utf8)
    [IO.File]::WriteAllText($dark, "background = #1e2230`nforeground = #e0e0e0`n", $utf8)
    $l = $light.Replace('\', '/')
    $d = $dark.Replace('\', '/')

    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`ntheme = light:$l,dark:$d`ncommand = direct:cmd.exe /k`n"
    function Get-Win { @((Get-GhosttyState -Class $g.Class).windows)[0] }
    function Wait-Win([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 10) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition { $w = Get-Win; if ($w -and (& $Predicate $w)) { $w } }
        if (-not $w) { throw "timeout waiting for: $What; state: $(Get-Win | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Invoke-Act([string]$Action) { [void](Invoke-GhosttyAction -Class $g.Class -Action $Action) }
    function Set-Scheme([string]$Scheme) {
        $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'color-scheme'; scheme = $Scheme }
        if ($r.code -ne 0) { throw "color-scheme ${Scheme}: code $($r.code)" }
        Start-Sleep -Milliseconds 600
    }
    function Set-Dpi([int]$Dpi) {
        $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'dpi'; dpi = $Dpi }
        if ($r.code -ne 0) { throw "dpi ${Dpi}: code $($r.code)" }
        [void](Wait-Win "dpi $Dpi" { param($w) $w.dpi -eq $Dpi })
        Start-Sleep -Milliseconds 600
    }

    # Idle CPU: one surface, nothing drawing, 30 s of process CPU time.
    Start-Sleep -Seconds 3
    $p = Get-Process -Id $g.Pid
    $cpu0 = $p.TotalProcessorTime.TotalSeconds
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 30
    $p.Refresh()
    $cpu = ($p.TotalProcessorTime.TotalSeconds - $cpu0) / $sw.Elapsed.TotalSeconds * 100 / [Environment]::ProcessorCount
    Write-E2eInfo ("idle CPU one-surface: {0:N2} s over {1:N1} s = {2:N2} % of the machine ({3} logical CPUs)" -f
        ($p.TotalProcessorTime.TotalSeconds - $cpu0), $sw.Elapsed.TotalSeconds, $cpu, [Environment]::ProcessorCount)

    # 3 tabs, 4 splits in the active one (the middle tab).
    Invoke-Act 'new_tab'
    Invoke-Act 'new_tab'
    [void](Wait-Win 'three tabs' { param($w) @($w.tabs).Count -eq 3 })
    Invoke-Act 'goto_tab:2'
    foreach ($a in 'new_split:right', 'new_split:down', 'goto_split:previous', 'new_split:down') { Invoke-Act $a }
    $w = Wait-Win 'four panes' { param($w) @(@($w.tabs)[$w.active_tab].surfaces).Count -eq 4 }
    Start-Sleep -Seconds 1

    foreach ($scheme in 'dark', 'light') {
        Set-Scheme $scheme
        foreach ($dpi in 96, 144, 192) {
            Set-Dpi $dpi
            Save-Evidence "$scheme-$dpi" $g -Window
        }
    }
    Set-Dpi 96
    Set-Scheme 'dark'
    Invoke-Act 'toggle_maximize'
    [void](Wait-Win 'maximized' { param($w) $w.maximized })
    Start-Sleep -Seconds 1
    Save-Evidence 'maximized' $g -Window
    Invoke-Act 'toggle_maximize'
    [void](Wait-Win 'restored' { param($w) -not $w.maximized })
    Invoke-Act 'toggle_fullscreen'
    [void](Wait-Win 'fullscreen' { param($w) $w.fullscreen })
    Start-Sleep -Seconds 1
    Save-Evidence 'fullscreen' $g -Window
    Invoke-Act 'toggle_fullscreen'
    [void](Wait-Win 'windowed' { param($w) -not $w.fullscreen })

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
}
