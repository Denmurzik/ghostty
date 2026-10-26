# e2e: milestone=M2 timeout=120 order=230
# splits-basic: new_split right/down give three panes that tile the content
# area with gaps of gapPx(dpi); goto_split, resize_split, equalize_splits and
# toggle_split_zoom do what they say. Driven by the test IPC ops.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')

Invoke-E2eScenario 'splits-basic' {
    $g = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'cmd')
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }

    $st = Wait-SurfaceCount $g 1
    $content = ConvertTo-Box $st.Surfaces[0]
    Write-E2eInfo "content rect [$($content.L),$($content.T),$($content.R),$($content.B)]"

    # A | (B / C)
    Invoke-SplitAction $g 'new_split:right'
    Invoke-SplitAction $g 'new_split:down'
    $st = Wait-SurfaceCount $g 3
    $gap = Get-SplitGap $st
    $boxes = Get-SurfaceBoxes $st
    foreach ($x in $boxes) { if (-not $x.Visible) { throw "surface $($x.Id) is not visible" } }
    Assert-NoOverlap $boxes

    $a = $boxes | Sort-Object L, T | Select-Object -First 1
    $rest = @($boxes | Where-Object { $_.Id -ne $a.Id } | Sort-Object T)
    $b = $rest[0]; $c = $rest[1]
    $bb = Get-BoundingBox $boxes
    if ($bb.L -ne $content.L -or $bb.T -ne $content.T -or $bb.R -ne $content.R -or $bb.B -ne $content.B) {
        throw "panes do not span the content rect: [$($bb.L),$($bb.T),$($bb.R),$($bb.B)] vs [$($content.L),$($content.T),$($content.R),$($content.B)]"
    }
    if ($b.L - $a.R -ne $gap) { throw "gap between A and B is $($b.L - $a.R), expected $gap" }
    if ($c.T - $b.B -ne $gap) { throw "gap between B and C is $($c.T - $b.B), expected $gap" }
    if ($b.L -ne $c.L -or $b.R -ne $c.R) { throw 'B and C do not share a column' }
    if ($a.T -ne $content.T -or $a.B -ne $content.B) { throw 'A does not span the full height' }
    if (-not $c.Focused) { throw 'the newest pane (C) is not focused' }
    Save-Evidence 'three-panes' $g -Window

    # goto_split:left -> the first pane.
    Invoke-SplitAction $g 'goto_split:left'
    $focused = @(Get-SurfaceBoxes (Get-SplitState $g) | Where-Object { $_.Focused })
    if ($focused.Count -ne 1 -or $focused[0].Id -ne $a.Id) { throw "goto_split:left did not focus A (focused: $(($focused | ForEach-Object { $_.Id }) -join ','))" }
    # Already leftmost: SplitTree.nearestWrapped wraps to the rightmost column.
    Invoke-SplitAction $g 'goto_split:left'
    $focused = @(Get-SurfaceBoxes (Get-SplitState $g) | Where-Object { $_.Focused })
    if ($focused.Count -ne 1 -or $focused[0].Id -eq $a.Id) { throw 'goto_split:left from the leftmost pane did not wrap' }
    Invoke-SplitAction $g 'goto_split:left'
    $focused = @(Get-SurfaceBoxes (Get-SplitState $g) | Where-Object { $_.Focused })
    if ($focused.Count -ne 1 -or $focused[0].Id -ne $a.Id) { throw 'goto_split:left after the wrap did not return to A' }

    # resize_split:right,100 -> A is 100 px wider (+-2).
    $aBefore = (Get-SurfaceBoxes (Get-SplitState $g) | Where-Object { $_.Id -eq $a.Id }).W
    Invoke-SplitAction $g 'resize_split:right,100'
    $st = Get-SplitState $g
    $aAfter = (Get-SurfaceBoxes $st | Where-Object { $_.Id -eq $a.Id }).W
    Write-E2eInfo "A width $aBefore -> $aAfter"
    if ([Math]::Abs(($aAfter - $aBefore) - 100) -gt 2) { throw "A grew by $($aAfter - $aBefore) px, expected 100 +-2" }
    Assert-NoOverlap (Get-SurfaceBoxes $st)

    # equalize_splits weighs by leaf count of same-layout children only
    # (SplitTree.weight counts a nested split of the other layout as 1): in
    # A | (B / C) A gets half the width.
    Invoke-SplitAction $g 'equalize_splits'
    $st = Get-SplitState $g
    $total = $content.R - $content.L - $gap
    $aEq = (Get-SurfaceBoxes $st | Where-Object { $_.Id -eq $a.Id }).W
    Write-E2eInfo "A width after equalize $aEq of $total (half is $([int]($total / 2)))"
    if ([Math]::Abs($aEq - $total / 2) -gt 2) { throw "A is $aEq px after equalize, expected $([int]($total / 2)) +-2" }

    # toggle_split_zoom -> one visible pane with the full content rect.
    Invoke-SplitAction $g 'toggle_split_zoom'
    $vis = @(Get-SurfaceBoxes (Get-SplitState $g) | Where-Object { $_.Visible })
    if ($vis.Count -ne 1) { throw "zoom left $($vis.Count) visible panes, expected 1" }
    $z = $vis[0]
    if ($z.Id -ne $a.Id) { throw 'the zoomed pane is not the focused one' }
    if ($z.L -ne $content.L -or $z.T -ne $content.T -or $z.R -ne $content.R -or $z.B -ne $content.B) {
        throw "zoomed rect [$($z.L),$($z.T),$($z.R),$($z.B)] is not the content rect"
    }
    Save-Evidence 'zoomed' $g -Window

    Invoke-SplitAction $g 'toggle_split_zoom'
    $boxes = Get-SurfaceBoxes (Get-SplitState $g)
    if (@($boxes | Where-Object { $_.Visible }).Count -ne 3) { throw 'zoom off did not show all three panes' }
    Assert-NoOverlap $boxes

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "error lines in ghostty.log: $($errors -join ' | ')" }
}
