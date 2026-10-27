# e2e: milestone=M3 timeout=120 order=580
# palette: `toggle_command_palette` opens the palette panel with the EDIT
# focused; typing "split right" puts the "Split Right" entry first, Enter
# runs it (new_split:right): the tab has two surfaces and the palette is
# closed. Toggling again closes it, and Esc does too. Keep this file ASCII
# only (Windows PowerShell 5.1 reads a BOM-less script as ANSI).
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')

Invoke-E2eScenario 'palette' {
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    [void](Wait-SurfaceCount $g 1)

    function Get-Pal {
        $d = Get-IpcData (Get-GhosttyState -Class $g.Class)
        $d.m3.palette
    }

    if ((Get-Pal).open) { throw 'the palette is open before the action' }

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { $p = Get-Pal; $p.open -and $p.visible -and $p.focused })) {
        throw "the palette did not open with the focus in its EDIT: $((Get-Pal) | ConvertTo-Json -Compress)"
    }
    if ((Get-Pal).rows -lt 1) { throw 'the palette lists no commands' }
    Save-Evidence 'palette-open' $g -Window

    Send-Typed $g.Hwnd 'split right'
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Pal).query -eq 'split right' })) {
        throw "the query is '$((Get-Pal).query)', expected 'split right'"
    }
    $p = Get-Pal
    if ($p.first -ne 'Split Right') { throw "the first row is '$($p.first)', expected 'Split Right'" }
    if ($p.sel -ne 0) { throw "the selection is $($p.sel), expected 0" }
    Save-Evidence 'palette-filtered' $g -Window

    # Enter: the palette closes, the command runs on the surface that was focused.
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { -not (Get-Pal).open })) { throw 'Enter did not close the palette' }
    $st = Wait-SurfaceCount $g 2
    if (-not (@($st.Surfaces | Where-Object { $_.focused }).Count -ge 1)) { throw 'no surface has the focus after the command' }

    # Toggle opens and closes; Esc closes.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Pal).open })) { throw 'the palette did not open again' }
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { -not (Get-Pal).open })) { throw 'the second toggle did not close the palette' }

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { $p = Get-Pal; $p.open -and $p.focused })) { throw 'the palette did not open for Esc' }
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc'
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { -not (Get-Pal).open })) { throw 'Esc did not close the palette' }
    [void](Wait-SurfaceCount $g 2)
}
