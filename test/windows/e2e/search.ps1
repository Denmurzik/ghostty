# e2e: milestone=M3 timeout=120 order=570
# search: `start_search` shows the search bar focused over the surface; typing
# `alpha` makes core report 3 matches (state.m3.search.total); Enter advances
# the selected match; Esc hides the bar and the keyboard goes back to the shell.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'search' {
    if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
    $g = Start-BashE2e

    function Get-Search {
        $r = Get-GhosttyState -Class $g.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        $d.m3.search
    }

    Send-Line $g.Hwnd 'echo alpha beta alpha gamma alpha'
    Start-Sleep -Milliseconds 500

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'start_search')
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { $s = Get-Search; $s.visible -and $s.focused })) {
        throw "the search bar is not visible and focused: $((Get-Search) | ConvertTo-Json -Compress)"
    }

    Send-Typed $g.Hwnd 'alpha'
    # The command line itself holds `alpha` once more: 3 in the output + 1 typed.
    if (-not (Wait-Until -TimeoutSec 1 -PollMs 50 -Condition { (Get-Search).total -ge 3 })) {
        throw "search total did not reach 3 within 1 s: $((Get-Search) | ConvertTo-Json -Compress)"
    }
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { $null -ne (Get-Search).selected })) {
        throw 'no match is selected'
    }
    $first = (Get-Search).selected
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { (Get-Search).selected -ne $first })) {
        throw "Enter did not advance the selected match (still $first)"
    }
    $second = (Get-Search).selected
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { (Get-Search).selected -ne $second })) {
        throw "the second Enter did not advance the selected match (still $second)"
    }

    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc'
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not (Get-Search).visible })) {
        throw 'Esc did not hide the search bar'
    }

    # Echo oracle: the keyboard reaches the shell again.
    $file = Join-Path $g.Sandbox.Tmp 'gt-search.txt'
    Send-Line $g.Hwnd "echo search-ok > '$($file -replace '\','/')'"
    if (-not (Wait-File $file 10)) { throw 'typing after Esc did not reach the shell' }
}
