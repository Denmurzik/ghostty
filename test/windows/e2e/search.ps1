# e2e: milestone=M3 timeout=120 order=570
# search: `start_search` shows the search bar focused over the surface; typing
# `alpha` makes core report matches (state.m3.search.total); Enter advances
# the selected match; Esc with text only gives the focus back to the surface
# (the bar stays); the `end_search` action hides it, and the keyboard reaches
# the shell. The main window is never foregrounded while the bar is driven:
# the keys are only sent while state.m3.search.focused says the EDIT has them.
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
    function Assert-BarFocused([string]$What) {
        if (-not (Get-Search).focused) {
            throw "the search EDIT lost the focus before $What : $((Get-Search) | ConvertTo-Json -Compress)"
        }
    }

    Send-Line $g.Hwnd 'echo alpha beta alpha gamma alpha'
    Start-Sleep -Milliseconds 500

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'start_search')
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { $s = Get-Search; $s.visible -and $s.focused })) {
        throw "the search bar is not visible and focused: $((Get-Search) | ConvertTo-Json -Compress)"
    }

    Assert-BarFocused 'typing'
    Invoke-SendInput -Hwnd $g.Hwnd -Text 'alpha'
    # The command line itself holds `alpha` once more: 3 in the output + 1 typed.
    if (-not (Wait-Until -TimeoutSec 1 -PollMs 50 -Condition { (Get-Search).total -ge 3 })) {
        throw "search total did not reach 3 within 1 s: $((Get-Search) | ConvertTo-Json -Compress)"
    }
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { $null -ne (Get-Search).selected })) {
        throw 'no match is selected'
    }
    foreach ($round in 1, 2) {
        $before = (Get-Search).selected
        Assert-BarFocused "Enter $round"
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
        if (-not (Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { (Get-Search).selected -ne $before })) {
            throw "Enter $round did not advance the selected match (still $before)"
        }
    }

    # Esc with text in the field: the bar stays, the surface has the focus.
    Assert-BarFocused 'Esc'
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc'
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { $s = Get-Search; $s.visible -and -not $s.focused })) {
        throw "Esc with text did not move the focus to the surface and keep the bar: $((Get-Search) | ConvertTo-Json -Compress)"
    }

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'end_search')
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not (Get-Search).visible })) {
        throw 'end_search did not hide the search bar'
    }

    # Echo oracle: the keyboard reaches the shell again.
    $file = Join-Path $g.Sandbox.Tmp 'gt-search.txt'
    Send-Line $g.Hwnd "echo search-ok > '$($file -replace '\','/')'"
    if (-not (Wait-File $file 10)) { throw 'typing after the search reached no shell' }
}
