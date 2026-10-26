# e2e: milestone=M2 timeout=120 order=380
# dpi-sim: the test IPC `dpi` op simulates a per-monitor DPI change. Two tabs
# (the second hidden) and a zoomed split in tab 1: at 144 every surface,
# hidden ones included, reports scale 1.5, the strip is 60 px high and the
# cell height is about 1.5x; 192 gives 2.0; back at 96 the original cell size
# returns; maximized and fullscreen windows refit to the work area / monitor
# and the visible surface fills the content rect. Surfaces created after the change (new_tab, new_split) start at
# the current scale. Screenshots at 96/144/192 are kept as evidence.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'dpi-sim' {
    $g = Start-BashE2e
    # powershell.exe is DPI-unaware: ask for physical coordinates so Screen.* matches the state.
    if (-not ('GhosttyE2e.DpiCtx' -as [type])) { Add-Type -Namespace GhosttyE2e -Name DpiCtx -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);' }
    [void][GhosttyE2e.DpiCtx]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))

    function Get-Win {
        $d = Get-GhosttyState -Class $g.Class
        @($d.windows)[0]
    }
    function Wait-Win([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 8) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and (& $Predicate $w)) { $w }
        }
        if (-not $w) {
            $now = Get-Win | ConvertTo-Json -Depth 8 -Compress
            throw "timeout waiting for: $What; state: $now"
        }
        $w
    }
    function Invoke-Act([string]$Action) { [void](Invoke-GhosttyAction -Class $g.Class -Action $Action) }
    function Set-Dpi([int]$Dpi) {
        $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'dpi'; dpi = $Dpi }
        if ($r.code -ne 0) { throw "ipc dpi ${Dpi}: code $($r.code): $($r.stderr)" }
    }
    function Get-AllSurfaces($w) { foreach ($t in @($w.tabs)) { foreach ($s in @($t.surfaces)) { $s } } }

    # The visible surface fills the content rect (client below the strip).
    function Assert-Fills($w, [string]$What) {
        $vis = @(Get-AllSurfaces $w | Where-Object { $_.visible })
        if ($vis.Count -ne 1) { throw "${What}: $($vis.Count) visible surfaces, want 1 (zoomed)" }
        $r = @($vis[0].rect)
        $cw = $w.client[2] - $w.client[0]
        $ch = $w.client[3] - $w.client[1]
        $top = @($w.strip.bounds)[3]
        if ($r[0] -ne 0 -or $r[2] -ne $cw -or $r[1] -ne $top -or $r[3] -ne $ch) {
            throw "${What}: surface rect [$($r -join ',')] != content rect [0,$top,$cw,$ch]"
        }
    }
    Add-Type -AssemblyName System.Windows.Forms
    function Get-Screen($w) { [Windows.Forms.Screen]::FromHandle([IntPtr][Convert]::ToInt64(([string]$w.hwnd).Substring(2), 16)) }
    function Assert-Scale($w, [double]$Scale, [string]$What) {
        foreach ($s in Get-AllSurfaces $w) {
            if ([math]::Abs([double]$s.scale - $Scale) -gt 0.001) { throw "${What}: surface $($s.id) scale $($s.scale), want $Scale" }
        }
    }
    function Assert-Dpi([int]$Dpi, [double]$Scale, [int]$StripH) {
        $w = Wait-Win "dpi $Dpi" { param($w) $w.dpi -eq $Dpi }
        Assert-Scale $w $Scale "dpi $Dpi"
        $b = @($w.strip.bounds)
        $h = $b[3] - $b[1]
        if ($StripH -gt 0 -and [math]::Abs($h - $StripH) -gt 1) { throw "dpi ${Dpi}: strip height $h, want $StripH" }
        $w
    }

    # Tab 1 with a zoomed split, then a second (hidden) tab.
    Invoke-Act 'new_split:right'
    [void](Wait-Win 'two panes' { param($w) @(@($w.tabs)[0].surfaces).Count -eq 2 })
    Invoke-Act 'toggle_split_zoom'
    [void](Wait-Win 'zoomed' { param($w) @($w.tabs)[0].zoomed })
    Invoke-Act 'new_tab'
    [void](Wait-Win 'two tabs' { param($w) @($w.tabs).Count -eq 2 })
    Invoke-Act 'goto_tab:1'
    $w0 = Wait-Win 'tab 0 active' { param($w) $w.active_tab -eq 0 -and $w.cell[1] -gt 0 }
    $baseCell = [int]$w0.cell[1]
    $baseStrip = @($w0.strip.bounds)[3] - @($w0.strip.bounds)[1]
    $baseDpi = [int]$w0.dpi
    $baseScale = $baseDpi / 96.0
    Assert-Scale $w0 $baseScale 'start'
    Save-Evidence 'dpi-96' $g -Window

    # 144
    Set-Dpi 144
    $w = Assert-Dpi 144 1.5 60
    $cell = [int]$w.cell[1]
    if ([math]::Abs($cell - $baseCell * 1.5 / $baseScale) -gt 1.5) { throw "cell height at 144: $cell, want about $($baseCell * 1.5 / $baseScale)" }
    if (-not @($w.tabs)[0].zoomed) { throw 'the split zoom was lost by the dpi change' }
    Save-Evidence 'dpi-144' $g -Window

    # Surfaces created after the change start at the current scale.
    Invoke-Act 'new_tab'
    $w = Wait-Win 'third tab' { param($w) @($w.tabs).Count -eq 3 }
    Assert-Scale $w 1.5 'after new_tab at 144'
    Invoke-Act 'new_split:right'
    $w = Wait-Win 'split in the new tab' { param($w) @(@($w.tabs)[$w.active_tab].surfaces).Count -eq 2 }
    Assert-Scale $w 1.5 'after new_split at 144'

    # 192
    Set-Dpi 192
    $w = Assert-Dpi 192 2.0 0
    $cell = [int]$w.cell[1]
    if ([math]::Abs($cell - $baseCell * 2.0 / $baseScale) -gt 2) { throw "cell height at 192: $cell, want about $($baseCell * 2.0 / $baseScale)" }
    Save-Evidence 'dpi-192' $g -Window

    # Back at 96: the original cell size and strip.
    Set-Dpi $baseDpi
    $w = Assert-Dpi $baseDpi $baseScale $baseStrip
    if ([int]$w.cell[1] -ne $baseCell) { throw "cell height back at 96: $($w.cell[1]), want $baseCell" }

    # New tabs open next to the active one: go back to the zoomed first tab.
    Invoke-Act 'goto_tab:1'
    [void](Wait-Win 'tab 0 active again' { param($w) $w.active_tab -eq 0 })

    # Maximized: the dpi change refits the window to the work area.
    Invoke-Act 'toggle_maximize'
    [void](Wait-Win 'maximized' { param($w) $w.maximized })
    foreach ($dpi in 144, $baseDpi) {
        Set-Dpi $dpi
        $w = Wait-Win "maximized at $dpi" { param($w) $w.dpi -eq $dpi -and $w.maximized }
        $wa = (Get-Screen $w).WorkingArea
        $cw = $w.client[2] - $w.client[0]
        $ch = $w.client[3] - $w.client[1]
        if ($cw -gt $wa.Width + 4 -or $ch -gt $wa.Height + 4 -or $cw -lt $wa.Width - 40 -or $ch -lt $wa.Height - 40) {
            throw "maximized at ${dpi}: client ${cw}x${ch} does not fill the work area $($wa.Width)x$($wa.Height)"
        }
        if ($w.window[0] -gt $wa.Left -or $w.window[2] -lt $wa.Right) { throw "maximized at ${dpi}: window [$($w.window -join ',')] does not cover the work area" }
        Assert-Fills $w "maximized at $dpi"
    }
    Invoke-Act 'toggle_maximize'
    [void](Wait-Win 'restored' { param($w) -not $w.maximized })

    # Fullscreen: the client covers the monitor after a dpi change.
    Invoke-Act 'toggle_fullscreen'
    [void](Wait-Win 'fullscreen' { param($w) $w.fullscreen })
    foreach ($dpi in 144, $baseDpi) {
        Set-Dpi $dpi
        $w = Wait-Win "fullscreen at $dpi" { param($w) $w.dpi -eq $dpi -and $w.fullscreen }
        $mon = (Get-Screen $w).Bounds
        $cw = $w.client[2] - $w.client[0]
        $ch = $w.client[3] - $w.client[1]
        if ($cw -ne $mon.Width -or $ch -ne $mon.Height) { throw "fullscreen at ${dpi}: client ${cw}x${ch}, monitor $($mon.Width)x$($mon.Height)" }
        Assert-Fills $w "fullscreen at $dpi"
    }
    Invoke-Act 'toggle_fullscreen'
    [void](Wait-Win 'windowed again' { param($w) -not $w.fullscreen })

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
}
