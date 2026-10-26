# e2e: milestone=M2 timeout=120 order=280
# split-divider-drag: dragging the divider of two splits moves it with the
# mouse (left pane +150 px +-3), dragging to the window edge stops at the
# minimum (two cells, at least 16 px), and with focus-follows-mouse the
# keyboard focus moves to the pane under the pointer without a click.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

Invoke-E2eScenario 'split-divider-drag' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nfocus-follows-mouse = true`n"
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }

    [void](Wait-SurfaceCount $g 1)
    Invoke-SplitAction $g 'new_split:right'
    $st = Wait-SurfaceCount $g 2
    $gap = Get-SplitGap $st
    $boxes = @(Get-SurfaceBoxes $st | Sort-Object L)
    $left = $boxes[0]; $right = $boxes[1]
    $cy = [int](($left.T + $left.B) / 2)
    $cx = $left.R + [int]($gap / 2)
    Write-E2eInfo "left width $($left.W), divider at x=$cx y=$cy"

    # 1. Drag the divider 150 px to the right.
    Send-MouseDrag -Hwnd $g.Hwnd -X $cx -Y $cy -ToX ($cx + 150) -ToY $cy -Steps 15 -HoldMs 100
    $st = Get-SplitState $g
    $l = Get-SurfaceBoxes $st | Where-Object { $_.Id -eq $left.Id }
    Write-E2eInfo "left width $($left.W) -> $($l.W)"
    if ([Math]::Abs(($l.W - $left.W) - 150) -gt 3) { throw "left pane grew by $($l.W - $left.W) px, expected 150 +-3" }
    Assert-NoOverlap (Get-SurfaceBoxes $st)
    Save-Evidence 'dragged' $g -Window

    # 2. Drag to the window edge: the left pane keeps its minimum.
    $cx2 = $l.R + [int]($gap / 2)
    Send-MouseDrag -Hwnd $g.Hwnd -X $cx2 -Y $cy -ToX 1 -ToY $cy -Steps 20 -HoldMs 100
    $st = Get-SplitState $g
    $l = Get-SurfaceBoxes $st | Where-Object { $_.Id -eq $left.Id }
    Write-E2eInfo "left width at the edge $($l.W)"
    if ($l.W -lt 16) { throw "left pane shrank to $($l.W) px, below the 16 px minimum" }
    if ($l.W -gt 80) { throw "left pane is $($l.W) px after dragging to the edge, expected the minimum" }
    if (-not $l.Visible) { throw 'left pane is not visible' }

    # 3. focus-follows-mouse: moving over the unfocused pane focuses it.
    $boxes = @(Get-SurfaceBoxes (Get-SplitState $g) | Sort-Object L)
    $foc = @($boxes | Where-Object { $_.Focused })
    $target = if ($foc.Count -eq 1 -and $foc[0].Id -eq $boxes[0].Id) { $boxes[1] } else { $boxes[0] }
    Send-MouseMove -Hwnd $g.Hwnd -X ([int](($target.L + $target.R) / 2)) -Y ([int](($target.T + $target.B) / 2)) -Steps 5
    $ok = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
        $f = @(Get-SurfaceBoxes (Get-SplitState $g) | Where-Object { $_.Focused })
        $f.Count -eq 1 -and $f[0].Id -eq $target.Id
    }
    if (-not $ok) { throw "focus did not follow the mouse to surface $($target.Id)" }

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "error lines in ghostty.log: $($errors -join ' | ')" }
}
