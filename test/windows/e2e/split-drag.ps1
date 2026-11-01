# e2e: milestone=M8 timeout=240 order=1280
# split-drag: a pane dragged by its grab handle (the three dots at the top
# centre) moves within its tab, into another tab, onto the tab strip, into
# another window and out to a window of its own. The surface's hwnd and its
# cmd.exe stay through every move. Interactive only (real mouse input).
#
#   1. Window A, tab T0 split right: P0 | P1.
#   2. Hover P1's top band: the IPC state shows the handle dim, then bright on
#      the handle itself. A double click on the handle starts no drag.
#      `drag-handle = never`: no handle, and a press there starts no drag.
#   3. P1's handle onto P0's top quarter: a drag ghost is visible and the zone
#      is P0's top half; after the drop the tree is vertical, P1 on top.
#   4. P1 dragged 250 px below A: a new window B with one tab holding P1, the
#      size of the pane it was.
#   5. B's only pane onto A's P0 right zone: B closes, A is P0 | P1 again.
#   6. A new tab T1; P1 onto the strip right of T1: a tab T2 with P1.
#   7. Spring-loading: P0 (T0 single-pane) held 700 ms over T2's chip makes T2
#      the shown tab; dropped on P1's left zone T0 is gone and T2 = P0 | P1.
#   8. Esc during a drag over a pane changes nothing.
#   9. A drop on the source pane itself changes nothing.
#  10. The quick terminal has no handle and takes no drop.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Add-Type -AssemblyName System.Windows.Forms
if (-not ('GhosttyE2e.SplitDrag' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name SplitDrag -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int cx, uint flags);
public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R, r.B }; }
"@
}

Invoke-E2eScenario 'split-drag' {
    $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'cmd') -Raw -Encoding UTF8) +
        "`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n" +
        "quick-terminal-position = bottom`nquick-terminal-size = 150px`nquick-terminal-autohide = false`n" +
        "quick-terminal-animation-duration = 0.1`nshell-integration = none`n"
    $g = Start-E2eGhostty -ConfigText $cfg
    $global:E2eLast = $g
    [void](Wait-ChildNamed $g @('cmd.exe') 15)
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    $cfgPath = Join-Path $script:Sbx.Home '.config\ghostty\config.ghostty'

    # -- state helpers ---------------------------------------------------------
    function Get-St { Get-GhosttyState -Class $g.Class }
    function Get-Wins { @((Get-St).windows) }
    function Get-Hwnd($W) { [IntPtr][Convert]::ToInt64(([string]$W.hwnd), 16) }
    function Get-Ghosts { @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDragGhost') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) }) }
    function Get-CmdPids { @(Get-ProcessTree $g.Pid | Where-Object { $_.Name -ieq 'cmd.exe' } | ForEach-Object { [int]$_.ProcessId } | Sort-Object) }
    function Format-Short($St) {
        ([pscustomobject]@{ windows = @($St.windows | ForEach-Object { [pscustomobject]@{ id = $_.id; active_tab = $_.active_tab; tabs = @($_.tabs | ForEach-Object { , @($_.surfaces | ForEach-Object { "$($_.hwnd)@$(@($_.rect) -join ',')" }) }) } }); drag = $St.m8.split_drag }) |
            ConvertTo-Json -Depth 9 -Compress
    }
    function Wait-For([string]$What, [scriptblock]$Pred, [double]$TimeoutSec = 8) {
        $r = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $st = Get-St
            if (& $Pred $st) { $st }
        }
        if (-not $r) { throw "timeout waiting for: $What; state: $(Format-Short (Get-St))" }
        $r
    }

    # A pane by its surface hwnd text: its window, tab and state row.
    function Find-Pane([string]$SurfHwnd) {
        foreach ($w in Get-Wins) {
            $ti = 0
            foreach ($t in @($w.tabs)) {
                foreach ($s in @($t.surfaces)) {
                    if ([string]$s.hwnd -eq $SurfHwnd) { return [pscustomobject]@{ Win = $w; TabIndex = $ti; Tab = $t; Surf = $s } }
                }
                $ti++
            }
            $ti = 0
        }
        $null
    }
    function Get-Pane([string]$SurfHwnd) {
        $p = Find-Pane $SurfHwnd
        if (-not $p) { throw "pane $SurfHwnd is gone; state: $(Format-Short (Get-St))" }
        $p
    }
    # The pane's box in the client coordinates of its window.
    function Get-Box($P) {
        $r = @($P.Surf.rect)
        [pscustomobject]@{ L = [int]$r[0]; T = [int]$r[1]; R = [int]$r[2]; B = [int]$r[3]; W = [int]$r[2] - [int]$r[0]; H = [int]$r[3] - [int]$r[1] }
    }
    # The same box in screen pixels (what `m8.split_drag.zone` is in).
    function Get-ScreenBox($P) {
        $b = Get-Box $P
        $c = @($P.Win.client)
        [pscustomobject]@{ L = $b.L + [int]$c[0]; T = $b.T + [int]$c[1]; W = $b.W; H = $b.H }
    }
    # The middle of the handle, in window client pixels.
    function Get-HandlePoint($P) {
        $b = Get-Box $P
        $dy = [int][Math]::Round(6 * [double]$P.Win.dpi / 96.0)
        , @([int](($b.L + $b.R) / 2), ($b.T + $dy))
    }
    function Test-Near($A, $B, [int]$Tol = 3) {
        $x = @($A); $y = @($B)
        if ($x.Count -ne $y.Count) { return $false }
        for ($i = 0; $i -lt $x.Count; $i++) { if ([Math]::Abs([int]$x[$i] - [int]$y[$i]) -gt $Tol) { return $false } }
        $true
    }
    function Get-GrabRow([int]$SurfaceId) {
        @(@((Get-St).m8.grab) | Where-Object { [int]$_.surface -eq $SurfaceId })
    }

    # -- mouse helpers ---------------------------------------------------------
    # Hover the handle, press, and move far enough to start the drag.
    function Start-PaneDrag($P) {
        $hw = Get-Hwnd $P.Win
        $hp = Get-HandlePoint $P
        Send-MouseMove -Hwnd $hw -X $hp[0] -Y $hp[1]
        Start-Sleep -Milliseconds 250
        Send-MouseDown
        # Whatever throws after the press must not leave the button held.
        try {
            Start-Sleep -Milliseconds 60
            $sp = Convert-ClientToScreen $hw $hp[0] $hp[1]
            Send-MouseMove -ScreenX ($sp.X + 14) -ScreenY ($sp.Y + 14) -Steps 4
            Start-Sleep -Milliseconds 120
        } catch {
            Send-MouseUp
            throw
        }
    }
    function Move-DragTo([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$Steps = 20) {
        $sp = Convert-ClientToScreen $Hwnd $X $Y
        Send-MouseMove -ScreenX $sp.X -ScreenY $sp.Y -Steps $Steps
        Start-Sleep -Milliseconds 150
    }
    # A point of a pane box (client pixels): the middle of the side, an eighth in.
    function Get-ZonePoint($Box, [string]$Side) {
        $cx = [int](($Box.L + $Box.R) / 2); $cy = [int](($Box.T + $Box.B) / 2)
        switch ($Side) {
            'top' { , @($cx, ($Box.T + [int]($Box.H / 8))) }
            'bottom' { , @($cx, ($Box.B - [int]($Box.H / 8))) }
            'left' { , @(($Box.L + [int]($Box.W / 8)), $cy) }
            'right' { , @(($Box.R - [int]($Box.W / 8)), $cy) }
            default { , @($cx, $cy) }
        }
    }
    # The zone the machine should show for a side: that half of the box.
    function Get-ZoneRect($SBox, [string]$Side) {
        switch ($Side) {
            'top' { , @($SBox.L, $SBox.T, $SBox.W, [int][Math]::Floor($SBox.H / 2)) }
            'bottom' { , @($SBox.L, ($SBox.T + [int][Math]::Floor($SBox.H / 2)), $SBox.W, [int][Math]::Ceiling($SBox.H / 2)) }
            'left' { , @($SBox.L, $SBox.T, [int][Math]::Floor($SBox.W / 2), $SBox.H) }
            default { , @(($SBox.L + [int][Math]::Floor($SBox.W / 2)), $SBox.T, [int][Math]::Ceiling($SBox.W / 2), $SBox.H) }
        }
    }
    function Assert-NoDragLeft([string]$What) {
        $st = Wait-For "${What}: the drag session is over" { param($s) -not $s.m8.split_drag.active -and $null -eq $s.m8.split_drag.zone -and $null -eq $s.m8.split_drag.ghost -and $null -eq $s.m8.split_drag.marker } 5
        if (@(Get-Ghosts).Count -ne 0) { throw "$What : a drag ghost window is still visible" }
        $st
    }
    function Assert-Pids([string]$What) {
        if ((@(Get-CmdPids) -join ',') -ne ($script:Pids -join ',')) { throw "$What : cmd.exe pids changed: $((Get-CmdPids) -join ',') vs $($script:Pids -join ',')" }
    }
    # Type into the pane and read the answer back in its title: the pane is
    # alive, in the place the state says, and is the one with that hwnd.
    $script:Oracle = 0
    function Assert-Oracle([string]$SurfHwnd, [string]$What) {
        $p = Get-Pane $SurfHwnd
        $hw = Get-Hwnd $p.Win
        [void](Set-ForegroundSafe -Hwnd $hw)
        $b = Get-Box $p
        Send-MouseClick -Hwnd $hw -X ([int](($b.L + $b.R) / 2)) -Y ([int](($b.T + $b.B) / 2))
        Start-Sleep -Milliseconds 150
        $script:Oracle++
        $tag = "sd$($script:Oracle)"
        $file = Join-Path (Get-E2eTempRoot) "split-drag-$tag.txt"
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        Send-Line $hw "title $tag"
        Send-Line $hw "echo $tag> `"$file`""
        if (-not (Wait-File $file 10)) { throw "$What : the echo oracle in pane $SurfHwnd produced nothing" }
        $ok = Wait-Until -TimeoutSec 6 -PollMs 100 -Condition {
            $q = Find-Pane $SurfHwnd
            if ($q -and ([string]$q.Surf.title) -like "*$tag*") { $true }
        }
        if (-not $ok) { throw "$What : pane $SurfHwnd did not take the title $tag (the typing went to another pane)" }
    }
    function Save-Shot([string]$Tag) {
        $dir = Get-EvidenceDir
        if (-not $dir) { return }
        try { Save-WindowShot $g.Hwnd (Join-Path $dir "split-drag-$Tag.png") 40 } catch { Write-E2eInfo "shot $Tag failed: $($_.Exception.Message)" }
    }

    # -- window A --------------------------------------------------------------
    # At a fixed place, at most half the work area's height, so that 250 px
    # below it is on screen.
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $h = [Math]::Min(500, [int]($wa.Height / 2))
    [void][GhosttyE2e.SplitDrag]::SetWindowPos($g.Hwnd, [IntPtr]::Zero, $wa.X + 40, $wa.Y + 20, 900, $h, 0x14)
    Start-Sleep -Milliseconds 300

    # 1. T0 = P0 | P1.
    Invoke-SplitAction $g 'new_split:right'
    $st = Wait-For 'two panes in T0' { param($s) @($s.windows).Count -eq 1 -and @(@($s.windows)[0].tabs).Count -eq 1 -and @(@(@($s.windows)[0].tabs)[0].surfaces).Count -eq 2 }
    $aId = [int]@($st.windows)[0].id
    $panes = @(@(@($st.windows)[0].tabs)[0].surfaces | Sort-Object { [int]@($_.rect)[0] })
    $p0h = [string]$panes[0].hwnd
    $p1h = [string]$panes[1].hwnd
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 200 -Condition { @(Get-CmdPids).Count -ge 2 })) { throw 'expected two cmd.exe processes' }
    $script:Pids = @(Get-CmdPids)
    Write-E2eInfo "panes $p0h | $p1h, cmd.exe pids $($script:Pids -join ',')"

    # 2. The handle.
    $p1 = Get-Pane $p1h
    $b1 = Get-Box $p1
    $hw = Get-Hwnd $p1.Win
    $sid1 = [int]$p1.Surf.id
    # In the band, off the handle: dim.
    $dim = Wait-Until -TimeoutSec 4 -PollMs 100 -Condition {
        Send-MouseMove -Hwnd $hw -X ($b1.L + 12) -Y ($b1.T + 8)
        $r = @(Get-GrabRow $sid1)
        if ($r.Count -eq 1 -and [string]$r[0].shown -eq 'dim') { $r }
    }
    if (-not $dim) { throw "the handle of P1 is not dim in the band: $(Format-Short (Get-St))" }
    # On the handle: bright.
    $hp = Get-HandlePoint $p1
    $bright = Wait-Until -TimeoutSec 4 -PollMs 100 -Condition {
        Send-MouseMove -Hwnd $hw -X $hp[0] -Y $hp[1]
        $r = @(Get-GrabRow $sid1)
        if ($r.Count -eq 1 -and [string]$r[0].shown -eq 'bright') { $r }
    }
    if (-not $bright) { throw "the handle of P1 is not bright on the handle: $(Format-Short (Get-St))" }
    # Off the pane: gone.
    Send-MouseMove -Hwnd $hw -X ($b1.L + 40) -Y ($b1.B - 40)
    if (-not (Wait-Until -TimeoutSec 4 -PollMs 100 -Condition { @(Get-GrabRow $sid1).Count -eq 0 })) { throw 'the handle did not go away with the pointer' }
    Write-E2eInfo 'handle hover ok'

    # A double click on the handle (the second press is a press on the handle
    # too, and the releases are eaten): no drag stays, the pane still works.
    Send-MouseClick -Hwnd $hw -X $hp[0] -Y $hp[1] -Double
    Start-Sleep -Milliseconds 300
    [void](Assert-NoDragLeft 'double click on the handle')
    Assert-Oracle $p1h 'after the double click'
    Write-E2eInfo 'double click ok'

    # drag-handle = never: no handle, a press there starts no drag.
    Add-Content -LiteralPath $cfgPath -Value "drag-handle = never`n" -Encoding UTF8
    Invoke-SplitAction $g 'reload_config'
    Start-Sleep -Milliseconds 400
    Send-MouseMove -Hwnd $hw -X $hp[0] -Y $hp[1]
    Start-Sleep -Milliseconds 300
    if (@(Get-GrabRow $sid1).Count -ne 0) { throw 'drag-handle = never still shows a handle' }
    Send-MouseDown
    try {
        Start-Sleep -Milliseconds 60
        $sp = Convert-ClientToScreen $hw $hp[0] $hp[1]
        Send-MouseMove -ScreenX ($sp.X + 30) -ScreenY ($sp.Y + 30) -Steps 5
        Start-Sleep -Milliseconds 200
        $s = (Get-St).m8.split_drag
        if ($s.active -or $s.ghost) { throw "a press on the handle area started a drag although drag-handle = never: $($s | ConvertTo-Json -Compress)" }
        if (@(Get-Ghosts).Count -ne 0) { throw 'a drag ghost showed although drag-handle = never' }
    } finally {
        Send-MouseUp
    }
    Assert-Oracle $p1h 'with drag-handle = never'
    Add-Content -LiteralPath $cfgPath -Value "drag-handle = auto`n" -Encoding UTF8
    Invoke-SplitAction $g 'reload_config'
    Start-Sleep -Milliseconds 400
    Write-E2eInfo 'drag-handle = never ok'

    # 3. P1's handle onto P0's top quarter.
    $p0 = Get-Pane $p0h
    $p1 = Get-Pane $p1h
    $hw = Get-Hwnd $p0.Win
    $b0 = Get-Box $p0
    $want = Get-ZoneRect (Get-ScreenBox $p0) 'top'
    $zp = Get-ZonePoint $b0 'top'
    Start-PaneDrag $p1
    try {
        $ghost = Wait-Until -TimeoutSec 3 -PollMs 50 -Condition { @(Get-Ghosts).Count -ge 1 }
        if (-not $ghost) { throw 'no visible GhosttyDragGhost during the pane drag' }
        Move-DragTo $hw $zp[0] $zp[1]
        $st = Wait-For 'the zone over the top half of P0' { param($s) $s.m8.split_drag.active -and $null -ne $s.m8.split_drag.zone -and (Test-Near $s.m8.split_drag.zone $want 3) } 4
        if ([string]$st.m8.split_drag.ghost -notin @('image', 'chip')) { throw "no ghost kind in the state: $($st.m8.split_drag | ConvertTo-Json -Compress)" }
        Save-Shot 'zone-and-ghost'
    } finally {
        Send-MouseUp
    }
    [void](Assert-NoDragLeft 'drop on the top of P0')
    $st = Wait-For 'P1 above P0' {
        param($s)
        $a = Find-Pane $p0h; $b = Find-Pane $p1h
        $a -and $b -and ([int]@($b.Surf.rect)[1] -lt [int]@($a.Surf.rect)[1]) -and (Test-Near @($b.Surf.rect)[0] @($a.Surf.rect)[0] 3)
    }
    Assert-Pids 'after the move within the tab'
    Assert-Oracle $p1h 'P1 after the move within the tab'
    Write-E2eInfo 'move within the tab ok'

    # 4. P1 250 px below A: a window of its own, the size of the pane.
    $p1 = Get-Pane $p1h
    $old = Get-Box $p1
    $oldDpi = [int]$p1.Win.dpi
    $rc = [GhosttyE2e.SplitDrag]::Rect($g.Hwnd)
    $hp = Get-HandlePoint $p1
    $sp0 = Convert-ClientToScreen (Get-Hwnd $p1.Win) $hp[0] $hp[1]
    Start-PaneDrag $p1
    try {
        if (-not (Wait-Until -TimeoutSec 3 -PollMs 50 -Condition { @(Get-Ghosts).Count -ge 1 })) { throw 'no drag ghost before the drag out' }
        Send-MouseMove -ScreenX ($sp0.X + 14) -ScreenY ($rc[3] + 250) -Steps 25
        Start-Sleep -Milliseconds 250
        $s = (Get-St).m8.split_drag
        if ($null -ne $s.zone -or $null -ne $s.marker) { throw "a zone or marker shows outside every window: $($s | ConvertTo-Json -Compress)" }
    } finally {
        Send-MouseUp
    }
    [void](Assert-NoDragLeft 'drop outside')
    $st = Wait-For 'a second window holding P1' { param($s) @($s.windows).Count -eq 2 }
    $np = Get-Pane $p1h
    if ([int]$np.Win.id -eq $aId) { throw 'P1 stayed in window A' }
    if (@($np.Win.tabs).Count -ne 1 -or @($np.Tab.surfaces).Count -ne 1) { throw "window B should hold one tab with one pane: $(Format-Short $st)" }
    $a = Get-Pane $p0h
    if ([int]$a.Win.id -ne $aId -or @($a.Tab.surfaces).Count -ne 1) { throw 'A does not keep only P0' }
    Assert-Pids 'after the drag out'
    $nb = Get-Box $np
    if ([int]$np.Win.dpi -eq $oldDpi -and ([Math]::Abs($nb.W - $old.W) -gt 2 -or [Math]::Abs($nb.H - $old.H) -gt 2)) {
        throw "window B's pane is $($nb.W)x$($nb.H), P1 was $($old.W)x$($old.H)"
    }
    $bId = [int]$np.Win.id
    Assert-Oracle $p1h 'P1 in its own window'
    Write-E2eInfo "drag out ok, B pane $($nb.W)x$($nb.H) (was $($old.W)x$($old.H))"

    # 5. B's only pane onto A's P0, right zone: B closes.
    $p0 = Get-Pane $p0h
    $b0 = Get-Box $p0
    $hwA = Get-Hwnd $p0.Win
    $zp = Get-ZonePoint $b0 'right'
    $np = Get-Pane $p1h
    [void](Set-ForegroundSafe -Hwnd (Get-Hwnd $np.Win))
    Start-PaneDrag $np
    try {
        Move-DragTo $hwA $zp[0] $zp[1]
        [void](Wait-For 'the zone over the right half of A.P0' { param($s) $null -ne $s.m8.split_drag.zone } 4)
    } finally {
        Send-MouseUp
    }
    [void](Assert-NoDragLeft 'drop into A')
    $st = Wait-For 'B closed, A = P0 | P1' {
        param($s)
        $x = Find-Pane $p0h; $y = Find-Pane $p1h
        @($s.windows).Count -eq 1 -and $x -and $y -and [int]$y.Win.id -eq $aId -and [int]@($y.Surf.rect)[0] -gt [int]@($x.Surf.rect)[0]
    } 10
    Assert-Pids 'after the drop into A'
    Assert-Oracle $p1h 'P1 back in A'
    Write-E2eInfo 'drag into another window ok'

    # 6. A new tab T1; P1 onto the strip right of it.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    [void](Wait-For 'T1' { param($s) @(@($s.windows)[0].tabs).Count -eq 2 })
    $script:Pids = @(Get-CmdPids)
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:1')
    [void](Wait-For 'T0 shown' { param($s) [int]@($s.windows)[0].active_tab -eq 0 })
    $p1 = Get-Pane $p1h
    $hwA = Get-Hwnd $p1.Win
    $strip = @($p1.Win.strip.tabs)
    $last = @($strip[$strip.Count - 1])
    $sx = [int]$last[2] + 20
    $sy = [int](([int]$last[1] + [int]$last[3]) / 2)
    Start-PaneDrag $p1
    try {
        Move-DragTo $hwA $sx $sy
        $st = Wait-For 'the insertion marker on the strip' { param($s) $null -ne $s.m8.split_drag.marker } 4
    } finally {
        Send-MouseUp
    }
    [void](Assert-NoDragLeft 'drop on the strip')
    $st = Wait-For 'T2 holds P1, T0 keeps P0' {
        param($s)
        $w = @($s.windows)[0]
        @($w.tabs).Count -eq 3 -and @(@($w.tabs)[0].surfaces).Count -eq 1 -and [string]@(@($w.tabs)[0].surfaces)[0].hwnd -eq $p0h -and [string]@(@($w.tabs)[2].surfaces)[0].hwnd -eq $p1h
    }
    Assert-Pids 'after the drop on the strip'
    Assert-Oracle $p1h 'P1 in its own tab'
    Write-E2eInfo 'drop on the strip ok'

    # 7. Spring-loading: hold P0 over T2's chip, then drop on P1's left zone.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'goto_tab:1')
    [void](Wait-For 'T0 shown again' { param($s) [int]@($s.windows)[0].active_tab -eq 0 })
    $p0 = Get-Pane $p0h
    $hwA = Get-Hwnd $p0.Win
    $chip = @(@($p0.Win.strip.tabs)[2])
    $cx = [int](([int]$chip[0] + [int]$chip[2]) / 2)
    $cy = [int](([int]$chip[1] + [int]$chip[3]) / 2)
    Start-PaneDrag $p0
    try {
        Move-DragTo $hwA $cx $cy
        Start-Sleep -Milliseconds 700
        Send-MouseMove -Hwnd $hwA -X ($cx + 2) -Y $cy
        [void](Wait-For 'T2 shown by spring-loading' { param($s) [int]@($s.windows)[0].active_tab -eq 2 -and $s.m8.split_drag.active } 4)
        $t = Get-Pane $p1h
        $tb = Get-Box $t
        $want = Get-ZoneRect (Get-ScreenBox $t) 'left'
        $zp = Get-ZonePoint $tb 'left'
        Move-DragTo $hwA $zp[0] $zp[1]
        [void](Wait-For 'the zone over the left half of P1' { param($s) $null -ne $s.m8.split_drag.zone -and (Test-Near $s.m8.split_drag.zone $want 3) } 4)
    } finally {
        Send-MouseUp
    }
    [void](Assert-NoDragLeft 'drop on P1 after the spring')
    $st = Wait-For 'T0 gone, the shown tab is P0 | P1' {
        param($s)
        $w = @($s.windows)[0]
        $x = Find-Pane $p0h; $y = Find-Pane $p1h
        @($w.tabs).Count -eq 2 -and $x -and $y -and $x.TabIndex -eq $y.TabIndex -and [int]@($x.Surf.rect)[0] -lt [int]@($y.Surf.rect)[0]
    }
    Assert-Pids 'after the spring-loaded drop'
    Assert-Oracle $p0h 'P0 after the spring-loaded drop'
    Write-E2eInfo 'spring-loading ok'

    # 8. Esc over a pane changes nothing.
    $before = Format-Short (Get-St)
    $p0 = Get-Pane $p0h
    $p1 = Get-Pane $p1h
    $hwA = Get-Hwnd $p0.Win
    $zp = Get-ZonePoint (Get-Box $p1) 'top'
    Start-PaneDrag $p0
    try {
        Move-DragTo $hwA $zp[0] $zp[1]
        [void](Wait-For 'a zone before Esc' { param($s) $null -ne $s.m8.split_drag.zone } 4)
        Invoke-SendInput -Hwnd $hwA -Keys 'esc'
        Start-Sleep -Milliseconds 300
    } finally {
        Send-MouseUp
    }
    [void](Assert-NoDragLeft 'Esc')
    $after = Format-Short (Get-St)
    if ($before -ne $after) { throw "Esc changed the layout: $before -> $after" }
    Write-E2eInfo 'Esc ok'

    # 9. A drop on the source pane itself changes nothing.
    $p0 = Get-Pane $p0h
    $zp = Get-ZonePoint (Get-Box $p0) 'centre'
    Start-PaneDrag $p0
    try {
        Move-DragTo $hwA $zp[0] $zp[1]
        $s = (Get-St).m8.split_drag
        if ($null -ne $s.zone) { throw "a zone shows over the source pane itself: $($s | ConvertTo-Json -Compress)" }
    } finally {
        Send-MouseUp
    }
    [void](Assert-NoDragLeft 'self drop')
    if ((Format-Short (Get-St)) -ne $before) { throw 'a drop on the source pane changed the layout' }
    Write-E2eInfo 'self drop ok'

    # 10. The quick terminal: no handle, and a drop on it is refused.
    $q = $null
    $p = Start-Launch $g.Class @('+toggle-quick-terminal')
    if (-not $p.WaitForExit(5000)) { throw 'the +toggle-quick-terminal launch did not finish in 5 s' }
    $q = Wait-Until -TimeoutSec 6 -PollMs 100 -Condition {
        $x = (Get-St).m3.quick
        if ($x -and $x.shown -and $x.visible -and -not $x.animating) { $x }
    }
    if (-not $q) { throw 'the quick terminal did not show' }
    $qh = [IntPtr][Convert]::ToInt64(([string]$q.hwnd), 16)
    $aw = @((Get-Wins) | Where-Object { [int]$_.id -eq $aId })[0]
    $aw_rect = @($aw.window)
    $qr = $q.rect
    $overlap = ([int]$qr.x -lt [int]$aw_rect[2]) -and ([int]$aw_rect[0] -lt ([int]$qr.x + [int]$qr.w)) -and ([int]$qr.y -lt [int]$aw_rect[3]) -and ([int]$aw_rect[1] -lt ([int]$qr.y + [int]$qr.h))
    if ($overlap) {
        Write-E2eInfo 'quick terminal overlaps window A on this screen: the drop part is skipped'
    } else {
        # No handle on the quick terminal's pane.
        $qw = @((Get-Wins) | Where-Object { ([string]$_.hwnd) -eq ([string]$q.hwnd) })
        if ($qw.Count -eq 1) {
            $qpane = @(@($qw[0].tabs)[0].surfaces)[0]
            $qb = @($qpane.rect)
            Send-MouseMove -Hwnd $qh -X ([int](([int]$qb[0] + [int]$qb[2]) / 2)) -Y ([int]$qb[1] + 6)
            Start-Sleep -Milliseconds 400
            if (@(Get-GrabRow ([int]$qpane.id)).Count -ne 0) { throw 'the quick terminal shows a grab handle' }
        } else {
            Write-E2eInfo 'the quick terminal is not listed among the windows: its handle was not checked'
        }
        # A pane of A dropped on the quick terminal: blocked, nothing changes.
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        $p1 = Get-Pane $p1h
        Start-PaneDrag $p1
        try {
            Move-DragTo $qh 60 40
            $s = (Get-St).m8.split_drag
            if ($null -ne $s.zone -or $null -ne $s.marker) { throw "the quick terminal shows a drop target: $($s | ConvertTo-Json -Compress)" }
        } finally {
            Send-MouseUp
        }
        [void](Assert-NoDragLeft 'drop on the quick terminal')
        $p0 = Find-Pane $p0h
        $p1 = Find-Pane $p1h
        if (-not $p0 -or -not $p1 -or [int]$p0.Win.id -ne $aId -or [int]$p1.Win.id -ne $aId -or $p0.TabIndex -ne $p1.TabIndex) { throw "a drop on the quick terminal moved a pane: $(Format-Short (Get-St))" }
        Write-E2eInfo 'quick terminal ok'
    }
    $null = Start-Launch $g.Class @('+toggle-quick-terminal')

    Save-Evidence -Tag 'split-drag' -G $g -Window
}
