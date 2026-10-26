# e2e: milestone=M2 timeout=180 order=300
# chrome-paint: the strip is painted by the Chrome painter. Three tabs, the
# window in the foreground, then CopyFromScreen of the strip: the active tab
# has the configured background (+-6), the inactive tabs carry text pixels
# (luminance variance above a threshold), and with the pointer over the close
# caption button its rect is mostly #C42B1C (+-10). Run for a dark and a
# light configuration; the PNGs go to the evidence dir.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

# Pixels of a screen rect.
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
    for ($y = 0; $y -lt $Bmp.Height; $y += 2) {
        for ($x = 0; $x -lt $Bmp.Width; $x += 2) {
            $l = Get-Luma $Bmp.GetPixel($x, $y)
            $n++
            $sum += $l
            $sq += $l * $l
        }
    }
    $mean = $sum / $n
    [Math]::Sqrt([Math]::Max($sq / $n - $mean * $mean, 0))
}

function Get-Centre($R) { , @([int](($R[0] + $R[2]) / 2), [int](($R[1] + $R[3]) / 2)) }

function Test-Chrome([string]$Tag, [string]$Background, [string]$Foreground) {
    $g = Start-E2eGhostty -ConfigText "background = $Background`nforeground = $Foreground`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    try {
        if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "$Tag : no frame dump at $($g.Dump)" }
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        for ($i = 0; $i -lt 2; $i++) { [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab') }
        $st = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition {
            $w = @((Get-GhosttyState -Class $g.Class).windows)[0]
            if (@($w.tabs).Count -eq 3 -and @($w.strip.tabs).Count -eq 3) { $w }
        }
        if (-not $st) { throw "$Tag : three tabs did not appear" }
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        Start-Sleep -Milliseconds 500

        $origin = New-Object GhosttyE2e.Mouse+POINT
        [void][GhosttyE2e.Mouse]::ClientToScreen($g.Hwnd, [ref]$origin)
        # Park the pointer on the surface so no strip hover colours the tabs.
        $below = [int]$st.strip.bounds[3] + 60
        Send-MouseMove -Hwnd $g.Hwnd -X 200 -Y $below
        Start-Sleep -Milliseconds 400

        $b = $st.strip.bounds
        $strip = Get-ScreenShot ($origin.X + $b[0]) ($origin.Y + $b[1]) ($b[2] - $b[0]) ($b[3] - $b[1])
        $dir = Get-EvidenceDir
        if ($dir) { $strip.Save((Join-Path $dir "chrome-paint-$Tag-strip.png"), [Drawing.Imaging.ImageFormat]::Png) }

        # Active tab (the last one): the background, sampled below the title.
        $want = [Drawing.ColorTranslator]::FromHtml($Background)
        $a = @($st.strip.tabs)[$st.active_tab]
        $ax = $a[0] + 24
        $ay = $a[3] - 4
        $px = $strip.GetPixel($ax - $b[0], $ay - $b[1])
        if ([Math]::Abs($px.R - $want.R) -gt 6 -or [Math]::Abs($px.G - $want.G) -gt 6 -or [Math]::Abs($px.B - $want.B) -gt 6) {
            throw ("$Tag : active tab pixel ({0},{1}) is #{2:x2}{3:x2}{4:x2}, config background $Background" -f $ax, $ay, $px.R, $px.G, $px.B)
        }

        # Inactive tabs: text pixels in the title area.
        for ($i = 0; $i -lt 3; $i++) {
            if ($i -eq $st.active_tab) { continue }
            $r = @($st.strip.tabs)[$i]
            $rect = New-Object Drawing.Rectangle ($r[0] + 8), 8, ($r[2] - $r[0] - 48), ($r[3] - $r[1] - 16)
            $crop = $strip.Clone($rect, $strip.PixelFormat)
            try { $sd = Get-LumaStdDev $crop } finally { $crop.Dispose() }
            Write-E2eInfo "$Tag inactive tab $i luminance stddev $([Math]::Round($sd, 1))"
            if ($sd -lt 8) { throw "$Tag : inactive tab $i has no text pixels (luminance stddev $sd)" }
        }
        $strip.Dispose()

        # Pointer over the close caption button: the rect turns #C42B1C.
        $cc = Get-Centre $st.strip.close
        Send-MouseMove -Hwnd $g.Hwnd -X $cc[0] -Y $cc[1]
        Start-Sleep -Milliseconds 100
        Send-MouseMove -Hwnd $g.Hwnd -X ($cc[0] + 1) -Y $cc[1]
        Start-Sleep -Milliseconds 400
        $cr = $st.strip.close
        $btn = Get-ScreenShot ($origin.X + $cr[0]) ($origin.Y + $cr[1]) ($cr[2] - $cr[0]) ($cr[3] - $cr[1])
        if ($dir) { $btn.Save((Join-Path $dir "chrome-paint-$Tag-close.png"), [Drawing.Imaging.ImageFormat]::Png) }
        $hit = 0
        $total = $btn.Width * $btn.Height
        for ($y = 0; $y -lt $btn.Height; $y++) {
            for ($x = 0; $x -lt $btn.Width; $x++) {
                $p = $btn.GetPixel($x, $y)
                if ([Math]::Abs($p.R - 0xC4) -le 10 -and [Math]::Abs($p.G - 0x2B) -le 10 -and [Math]::Abs($p.B - 0x1C) -le 10) { $hit++ }
            }
        }
        $btn.Dispose()
        Write-E2eInfo "$Tag close button: $hit of $total pixels are #C42B1C"
        if ($hit -lt $total * 0.6) { throw "$Tag : only $hit of $total pixels of the close button are #C42B1C" }

        Save-Evidence -Tag "chrome-paint-$Tag" -G $g -Window
    } finally {
        if (-not $g.Process.HasExited) {
            $g.Process.Kill()
            [void]$g.Process.WaitForExit(5000)
        }
    }
}

Invoke-E2eScenario 'chrome-paint' {
    Test-Chrome 'dark' '#102030' '#e0e0e0'
    Test-Chrome 'light' '#f0f0f0' '#101010'
}
