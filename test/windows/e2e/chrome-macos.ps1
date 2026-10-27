# e2e: milestone=M3 timeout=420 order=395
# chrome-macos: the window chrome after Ghostty for macOS (DECISIONS 2026-10-27).
# One tab: only the title row (30 px), no tab row, no "+", the title centred on
# the window, the title row and the terminal one colour. Three tabs: the tab
# row below the title row, equal tabs that tile the track, the round "+" at the
# far right, the key label ("Ctrl+N" of goto_tab:N) at the right of every tab,
# the "x" instead of it under the pointer. Run for a dark and a light
# configuration at 96 and 144 dpi; the PNGs go to the evidence dir.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

function Get-ScreenShot([int]$X, [int]$Y, [int]$W, [int]$H) {
    $bmp = New-Object Drawing.Bitmap $W, $H
    $gfx = [Drawing.Graphics]::FromImage($bmp)
    try { $gfx.CopyFromScreen($X, $Y, 0, 0, (New-Object Drawing.Size $W, $H)) } finally { $gfx.Dispose() }
    $bmp
}

function Get-Luma([Drawing.Color]$C) { 0.2126 * $C.R + 0.7152 * $C.G + 0.0722 * $C.B }

# Standard deviation of the luminance over the bitmap.
function Get-LumaStdDev([Drawing.Bitmap]$Bmp) {
    $n = 0
    $sum = 0.0
    $sq = 0.0
    for ($y = 0; $y -lt $Bmp.Height; $y++) {
        for ($x = 0; $x -lt $Bmp.Width; $x++) {
            $l = Get-Luma $Bmp.GetPixel($x, $y)
            $n++
            $sum += $l
            $sq += $l * $l
        }
    }
    $mean = $sum / $n
    [Math]::Sqrt([Math]::Max($sq / $n - $mean * $mean, 0))
}

function Test-Near($Px, [Drawing.Color]$Want, [int]$Tol = 4) {
    [Math]::Abs($Px.R - $Want.R) -le $Tol -and [Math]::Abs($Px.G - $Want.G) -le $Tol -and [Math]::Abs($Px.B - $Want.B) -le $Tol
}

function Test-Look([string]$Tag, [string]$Background, [string]$Foreground) {
    $keys = "keybind = ctrl+1=goto_tab:1`nkeybind = ctrl+2=goto_tab:2`nkeybind = ctrl+3=goto_tab:3`n"
    $g = Start-E2eGhostty -ConfigText "background = $Background`nforeground = $Foreground`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = auto`n$keys"
    try {
        if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "$Tag : no frame dump at $($g.Dump)" }
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        $want = [Drawing.ColorTranslator]::FromHtml($Background)

        function Get-Win { @((Get-GhosttyState -Class $g.Class).windows)[0] }
        function Get-Origin {
            $o = New-Object GhosttyE2e.Mouse+POINT
            [void][GhosttyE2e.Mouse]::ClientToScreen($g.Hwnd, [ref]$o)
            $o
        }
        function Save-Shot([string]$Name) {
            $dir = Get-EvidenceDir
            if (-not $dir) { return }
            $ErrorActionPreference = 'Continue'
            & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:CaptureWindow `
                -Hwnd ('0x{0:X}' -f $g.Hwnd.ToInt64()) -Out (Join-Path $dir "chrome-macos-$Tag-$Name.png") 2>&1 | Out-Null
        }

        # One tab: the title row only.
        $w = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and @($w.tabs).Count -eq 1 -and $w.strip.bounds[3] -gt 0) { $w }
        }
        if (-not $w) { throw "$Tag : no window state" }
        $s = $w.strip
        Write-E2eInfo "$Tag 1 tab: strip bounds $($s.bounds -join ',') title_row $($s.title_row -join ',') tab_row $($s.tab_row -join ',')"
        $scale = ($s.bounds[3] - $s.bounds[1]) / 30.0
        if ($s.tab_row[3] -ne $s.tab_row[1]) { throw "$Tag : one tab shows a tab row $($s.tab_row -join ',')" }
        if ($null -ne $s.new_tab) { throw "$Tag : one tab shows a new-tab button" }
        if ($s.title_row[3] - $s.title_row[1] -ne $s.bounds[3]) { throw "$Tag : title row is not the whole strip" }

        Start-Sleep -Milliseconds 700
        $o = Get-Origin
        $w = Get-Win
        $s = $w.strip
        $b = $s.bounds
        # The title row and the terminal are one colour: no seam.
        $row = Get-ScreenShot ($o.X + 40) ($o.Y + 4) 8 8
        $px = $row.GetPixel(2, 2)
        $row.Dispose()
        if (-not (Test-Near $px $want)) { throw ("$Tag : title row pixel is #{0:x2}{1:x2}{2:x2}, background $Background" -f $px.R, $px.G, $px.B) }
        $tm = Get-ScreenShot ($o.X + 40) ($o.Y + $b[3] + 4) 8 8
        $px = $tm.GetPixel(2, 2)
        $tm.Dispose()
        if (-not (Test-Near $px $want)) { throw ("$Tag : terminal pixel under the strip is #{0:x2}{1:x2}{2:x2}, background $Background" -f $px.R, $px.G, $px.B) }
        # The title text is centred on the window (the icon, when there is one, is part of it).
        $tt = $s.title_text
        $cw = $b[2] - $b[0]
        if ($tt[2] -gt $tt[0]) {
            $left = if ($null -ne $s.proxy_icon) { $s.proxy_icon[0] } else { $tt[0] }
            $mid = ($left + $tt[2]) / 2
            Write-E2eInfo "$Tag title centre $mid of width $cw (icon: $($null -ne $s.proxy_icon))"
            if ([Math]::Abs($mid - $cw / 2) -gt 8 * $scale) { throw "$Tag : title is not centred: centre $mid of $cw" }
        }
        Save-Shot '1tab'

        # Three tabs: the tab row slides in, then rests.
        for ($i = 0; $i -lt 2; $i++) { [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab') }
        $w = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and @($w.tabs).Count -eq 3 -and @($w.strip.tabs).Count -eq 3) { $w }
        }
        if (-not $w) { throw "$Tag : three tabs did not appear" }
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        Start-Sleep -Milliseconds 700
        $w = Get-Win
        $s = $w.strip
        $b = $s.bounds
        Write-E2eInfo "$Tag 3 tabs: bounds $($b -join ',') tab_row $($s.tab_row -join ',') track $($s.track -join ',') new_tab $($s.new_tab -join ',')"
        if ($b[3] -ne [int][Math]::Round(66 * $scale)) { throw "$Tag : strip height $($b[3]), expected $([Math]::Round(66 * $scale))" }
        if ($s.tab_row[1] -ne $s.title_row[3]) { throw "$Tag : tab row does not start under the title row" }
        $tabs = @($s.tabs)
        $widths = $tabs | ForEach-Object { $_[2] - $_[0] }
        if (($widths | Measure-Object -Maximum).Maximum - ($widths | Measure-Object -Minimum).Minimum -gt 1) { throw "$Tag : tabs are not equal: $($widths -join ',')" }
        if ($tabs[0][0] -ne $s.track[0] -or $tabs[2][2] -ne $s.track[2]) { throw "$Tag : tabs do not fill the track $($s.track -join ',')" }
        $nt = $s.new_tab
        if ($nt[2] -ne $b[2] - [int][Math]::Round(8 * $scale)) { throw "$Tag : new-tab button is not at the far right: $($nt -join ',')" }
        if (($nt[2] - $nt[0]) -ne ($nt[3] - $nt[1])) { throw "$Tag : new-tab button is not round (square rect expected)" }

        # Park the pointer on the terminal: no hover. Key labels: ink at the right of every tab.
        $o = Get-Origin
        Send-MouseMove -Hwnd $g.Hwnd -X 200 -Y ($b[3] + 80)
        Start-Sleep -Milliseconds 400
        $shot = Get-ScreenShot ($o.X + $b[0]) ($o.Y + $b[1]) ($b[2] - $b[0]) ($b[3] - $b[1])
        $dir = Get-EvidenceDir
        if ($dir) { $shot.Save((Join-Path $dir "chrome-macos-$Tag-strip.png"), [Drawing.Imaging.ImageFormat]::Png) }
        for ($i = 0; $i -lt 3; $i++) {
            $t = $tabs[$i]
            $rect = New-Object Drawing.Rectangle ([int]($t[2] - 40 * $scale - $b[0])), ([int]($t[1] - $b[1] + 6 * $scale)), ([int](30 * $scale)), ([int]($t[3] - $t[1] - 12 * $scale))
            $crop = $shot.Clone($rect, $shot.PixelFormat)
            try { $sd = Get-LumaStdDev $crop } finally { $crop.Dispose() }
            Write-E2eInfo "$Tag key label zone of tab $i : luminance stddev $([Math]::Round($sd, 1))"
            if ($sd -lt 5) { throw "$Tag : tab $i shows no key label (stddev $sd)" }
        }
        # The selected tab is lighter than the track (dark) or distinct from it.
        $a = $tabs[$w.active_tab]
        $inner = $shot.GetPixel([int](($a[0] + $a[2]) / 2 - $b[0]), [int]($a[1] - $b[1] + 4 * $scale))
        $track = $shot.GetPixel([int]($s.track[0] + 4 - $b[0]), [int](($a[1] + $a[3]) / 2 - $b[1]))
        Write-E2eInfo ("$Tag selected pill #{0:x2}{1:x2}{2:x2}, track #{3:x2}{4:x2}{5:x2}" -f $inner.R, $inner.G, $inner.B, $track.R, $track.G, $track.B)
        if ($inner.R -eq $track.R -and $inner.G -eq $track.G -and $inner.B -eq $track.B) { throw "$Tag : the selected tab does not differ from the track" }
        $shot.Dispose()
        Save-Shot '3tabs'

        # Pointer over a tab: the key label gives way to the close "x" (the zone's pixels change).
        $t = $tabs[0]
        $zone = New-Object Drawing.Rectangle ([int]($o.X + $t[2] - 30 * $scale)), ([int]($o.Y + $t[1] + 4 * $scale)), ([int](24 * $scale)), ([int]($t[3] - $t[1] - 8 * $scale))
        $before = Get-ScreenShot $zone.X $zone.Y $zone.Width $zone.Height
        $cx = [int](($t[0] + $t[2]) / 2)
        $cy = [int](($t[1] + $t[3]) / 2)
        Send-MouseMove -Hwnd $g.Hwnd -X ($cx - 5) -Y $cy
        Start-Sleep -Milliseconds 100
        Send-MouseMove -Hwnd $g.Hwnd -X $cx -Y $cy
        Start-Sleep -Milliseconds 400
        $after = Get-ScreenShot $zone.X $zone.Y $zone.Width $zone.Height
        $diff = 0
        for ($y = 0; $y -lt $before.Height; $y++) { for ($x = 0; $x -lt $before.Width; $x++) { if ((Get-Luma $before.GetPixel($x, $y)) -ne (Get-Luma $after.GetPixel($x, $y))) { $diff++ } } }
        $before.Dispose(); $after.Dispose()
        Write-E2eInfo "$Tag hover: $diff pixels of the key zone changed"
        if ($diff -lt 12) { throw "$Tag : hovering a tab did not show the close button ($diff pixels changed)" }
        Save-Shot '3tabs-hover'

        # 144 dpi: the rows scale.
        $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'dpi'; dpi = 144 }
        if ($r.code -ne 0) { throw "$Tag : ipc dpi 144: code $($r.code): $($r.stderr)" }
        $w = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and $w.strip.bounds[3] -eq 99) { $w }
        }
        if (-not $w) { throw "$Tag : the strip is not 99 px high at 144 dpi: $((Get-Win).strip.bounds -join ',')" }
        Start-Sleep -Milliseconds 400
        Save-Shot '3tabs-144'
        [void](Invoke-GhosttyIpc -Class $g.Class -Request @{ op = 'dpi'; dpi = 96 })
    } finally {
        if (-not $g.Process.HasExited) {
            $g.Process.Kill()
            [void]$g.Process.WaitForExit(5000)
        }
    }
}


# Pixels of two shots that differ (luminance), counted over the whole strip.
function Get-ShotDiff([Drawing.Bitmap]$A, [Drawing.Bitmap]$B) {
    $n = 0
    $h = [Math]::Min($A.Height, $B.Height)
    for ($y = 0; $y -lt $h; $y += 2) {
        for ($x = 0; $x -lt $A.Width; $x += 2) {
            if ([Math]::Abs((Get-Luma $A.GetPixel($x, $y)) - (Get-Luma $B.GetPixel($x, $y))) -gt 6) { $n++ }
        }
    }
    $n
}

# The animations: a second tab slides the tab row in, a closed tab slides it
# out, and the terminal's grid resizes once each time (not per frame). Frames
# of the strip are taken while it moves; at least one of them differs from the
# resting end state, and the surface's rect takes at most two values.
function Test-Animation([string]$Background, [string]$Foreground) {
    $g = Start-E2eGhostty -ConfigText "background = $Background`nforeground = $Foreground`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = auto`n"
    try {
        if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "anim : no frame dump" }
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        Start-Sleep -Milliseconds 800
        function Get-Win { @((Get-GhosttyState -Class $g.Class).windows)[0] }
        function Get-SurfaceRect { $w = Get-Win; (@($w.tabs)[$w.active_tab].surfaces[0].rect) -join ',' }
        $o = New-Object GhosttyE2e.Mouse+POINT
        [void][GhosttyE2e.Mouse]::ClientToScreen($g.Hwnd, [ref]$o)
        $width = (Get-Win).strip.bounds[2]
        Send-MouseMove -Hwnd $g.Hwnd -X 300 -Y 300

        # The action returns once the tab is made and the animation has started:
        # the strip is then captured in a tight loop (no IPC), then the end state.
        function Watch-Strip([string]$Action, [int]$Frames) {
            $before = Get-SurfaceRect
            $sw = [Diagnostics.Stopwatch]::StartNew()
            [void](Invoke-GhosttyAction -Class $g.Class -Action $Action)
            $t0 = $sw.ElapsedMilliseconds
            $shots = New-Object System.Collections.ArrayList
            $times = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $Frames; $i++) {
                [void]$shots.Add((Get-ScreenShot $o.X $o.Y $width 66))
                [void]$times.Add($sw.ElapsedMilliseconds - $t0)
            }
            $mid = Get-SurfaceRect
            Start-Sleep -Milliseconds 600
            $final = Get-ScreenShot $o.X $o.Y $width 66
            $after = Get-SurfaceRect
            $dir = Get-EvidenceDir
            if ($dir) { foreach ($k in 1, 4, 7) { $shots[$k].Save((Join-Path $dir "chrome-macos-anim-$Action-$k.png"), [Drawing.Imaging.ImageFormat]::Png) } }
            $diffs = @($shots | ForEach-Object { Get-ShotDiff $_ $final })
            foreach ($s in $shots) { $s.Dispose() }
            $final.Dispose()
            Write-E2eInfo "anim $Action : frames at ms $($times -join ','), action took $t0 ms, diffs to the end state $($diffs -join ',')"
            Write-E2eInfo "anim $Action : surface rect $before -> $mid -> $after"
            [pscustomobject]@{ Diffs = $diffs; Rects = @(@($before, $mid, $after) | Select-Object -Unique) }
        }

        # The second tab: the row slides in.
        $r = Watch-Strip 'new_tab' 10
        if (@($r.Diffs | Where-Object { $_ -gt 150 }).Count -lt 1) { throw "anim: no frame of the new tab differs from its end state ($($r.Diffs -join ','))" }
        if ($r.Rects.Count -gt 2) { throw "anim: the terminal resized $($r.Rects.Count - 1) times while the row slid in: $($r.Rects -join ' | ')" }
        # A third tab slides in too (tabs animate, the terminal does not resize).
        $r = Watch-Strip 'new_tab' 10
        if (@($r.Diffs | Where-Object { $_ -gt 150 }).Count -lt 1) { throw "anim: no frame of the third tab differs from its end state ($($r.Diffs -join ','))" }
        if ($r.Rects.Count -gt 1) { throw "anim: the terminal resized with a third tab: $($r.Rects -join ' | ')" }
        # Closing back to one tab: the row slides out, the terminal grows once, at the end.
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'close_tab')
        Start-Sleep -Milliseconds 600
        $r = Watch-Strip 'close_tab' 10
        if (@($r.Diffs | Where-Object { $_ -gt 150 }).Count -lt 1) { throw "anim: no frame of the closing tab differs from its end state ($($r.Diffs -join ','))" }
        if ($r.Rects.Count -gt 2) { throw "anim: the terminal resized $($r.Rects.Count - 1) times while the row slid out: $($r.Rects -join ' | ')" }
        $w = Get-Win
        if (@($w.tabs).Count -ne 1 -or $w.strip.bounds[3] -ne 30) { throw "anim: the end state is not one tab with the title row only: strip $($w.strip.bounds -join ',')" }
    } finally {
        if (-not $g.Process.HasExited) {
            $g.Process.Kill()
            [void]$g.Process.WaitForExit(5000)
        }
    }
}

Invoke-E2eScenario 'chrome-macos' {
    Test-Look 'dark' '#1b1c26' '#e0e0e0'
    Test-Look 'light' '#f4f4f4' '#101010'
    Test-Animation '#1b1c26' '#e0e0e0'
}
