# e2e: milestone=M2 timeout=120 order=380
# dpi-sim: the test IPC `dpi` op simulates a per-monitor DPI change. Two tabs
# (the second hidden) and a zoomed split in tab 1: at 144 every surface,
# hidden ones included, reports scale 1.5, the strip is 60 px high and the
# cell height is about 1.5x; 192 gives 2.0; back at 96 the original cell size
# returns. Surfaces created after the change (new_tab, new_split) start at
# the current scale. Screenshots at 96/144/192 are kept as evidence.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'dpi-sim' {
    $g = Start-BashE2e

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
    Assert-Scale $w0 1.0 'start'
    Save-Evidence 'dpi-96' $g -Window

    # 144
    Set-Dpi 144
    $w = Assert-Dpi 144 1.5 60
    $cell = [int]$w.cell[1]
    if ([math]::Abs($cell - $baseCell * 1.5) -gt 1.5) { throw "cell height at 144: $cell, want about $($baseCell * 1.5)" }
    if (-not @($w.tabs)[0].zoomed) { throw 'the split zoom was lost by the dpi change' }
    Save-Evidence 'dpi-144' $g -Window

    # Surfaces created after the change start at the current scale.
    Invoke-Act 'new_tab'
    $w = Wait-Win 'third tab' { param($w) @($w.tabs).Count -eq 3 }
    Assert-Scale $w 1.5 'after new_tab at 144'
    Invoke-Act 'new_split:right'
    $w = Wait-Win 'split in the new tab' { param($w) @(@($w.tabs)[2].surfaces).Count -eq 2 }
    Assert-Scale $w 1.5 'after new_split at 144'

    # 192
    Set-Dpi 192
    $w = Assert-Dpi 192 2.0 0
    $cell = [int]$w.cell[1]
    if ([math]::Abs($cell - $baseCell * 2.0) -gt 2) { throw "cell height at 192: $cell, want about $($baseCell * 2.0)" }
    Save-Evidence 'dpi-192' $g -Window

    # Back at 96: the original cell size and strip.
    Set-Dpi 96
    $w = Assert-Dpi 96 1.0 $baseStrip
    if ([int]$w.cell[1] -ne $baseCell) { throw "cell height back at 96: $($w.cell[1]), want $baseCell" }

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
}
