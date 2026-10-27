# e2e: milestone=M3 timeout=240 order=635
# opacity-blur: background-blur = true with background-opacity = 0.5 over a
# red/green striped backdrop window of our own. The stripes are blurred
# (luminance spread near 0, mean olive) while Ghostty is active AND while it
# is inactive (another window of ours has the foreground): the owner wants
# the blur to persist, which the system Acrylic alone does not (it goes solid
# on deactivation; composition.windowMessage swallows that). The backdrop
# type is DWMSBT_TRANSIENTWINDOW (3). Without background-blur the stripes stay
# sharp.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_backdrop.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

function Get-SystemBackdrop([IntPtr]$Hwnd) {
    $v = 0
    $hr = [GhosttyE2e.BackdropNative]::DwmGetWindowAttribute($Hwnd, 38, [ref]$v, 4)
    if ($hr -ne 0) { throw "DwmGetWindowAttribute(SYSTEMBACKDROP_TYPE) failed: 0x$('{0:x}' -f $hr)" }
    $v
}

Invoke-E2eScenario 'opacity-blur' {
    $dir = Get-EvidenceDir
    $back = New-BackdropForm 60 60 1500 1000 -Stripes
    try {
        Show-BackdropForm $back
        $g = Start-E2eGhostty -ConfigText "background = #000000`nforeground = #e0e0e0`nconfirm-close-surface = false`nbackground-opacity = 0.5`nbackground-blur = true`nwindow-decoration = client`n"
        if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
        Move-Window $g.Hwnd 160 160 1000 700
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        Start-Sleep -Milliseconds 1200

        $comp = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition {
            $c = (Get-GhosttyState -Class $g.Class).m3.composition
            if ($c.mode -eq 'composition' -and @(@($c.windows)[0].surfaces)[0].attached -ge 1) { $c }
        }
        if (-not $comp) { throw 'no composition chain attached' }
        if (@($comp.windows)[0].backdrop -ne 'acrylic') { throw "backdrop is $(@($comp.windows)[0].backdrop), expected acrylic" }
        $sbt = Get-SystemBackdrop $g.Hwnd
        if ($sbt -ne 3) { throw "DWMWA_SYSTEMBACKDROP_TYPE is $sbt, expected 3 (TRANSIENTWINDOW)" }

        # A 200 x 120 patch of empty cells in the middle of the terminal.
        $cs = Get-ClientSize $g.Hwnd
        $pt = Get-ClientScreenPoint $g.Hwnd ([int]($cs.Width / 2) - 100) ([int]($cs.Height / 2) - 60)
        $measure = {
            param($Tag)
            $bmp = Get-ScreenBitmap $pt[0] $pt[1] 200 120
            try {
                $spread = Get-LumaSpread $bmp
                $c = $bmp.GetPixel(100, 60)
            } finally { $bmp.Dispose() }
            if ($dir) { (Get-ScreenBitmap 60 60 1500 1000).Save((Join-Path $dir "opacity-blur-$Tag-screen.png"), [Drawing.Imaging.ImageFormat]::Png) }
            Write-E2eInfo "$Tag : stripe spread $([Math]::Round($spread, 1)), centre $(Format-Color $c)"
            [pscustomobject]@{ Spread = $spread; Color = $c }
        }

        $act = & $measure 'active'
        # Unblurred 50% stripes measure ~32; blurred ones ~0.
        if ($act.Spread -gt 8) { throw "active: the stripes are not blurred (spread $($act.Spread))" }

        $away = Switch-AwayFromGhostty $g
        try {
            $ina = & $measure 'inactive'
        } finally { $away.Close() }
        if ($ina.Spread -gt 8) { throw "inactive: the blur is gone (spread $($ina.Spread))" }
        # The same blurred colour in both states: the backdrop did not go solid.
        $d = [Math]::Abs($ina.Color.R - $act.Color.R) + [Math]::Abs($ina.Color.G - $act.Color.G) + [Math]::Abs($ina.Color.B - $act.Color.B)
        if ($d -gt 40) { throw "inactive colour $(Format-Color $ina.Color) differs from active $(Format-Color $act.Color)" }

        # Without background-blur the stripes are sharp (translucent only).
        $path = Join-Path $script:Sbx.Home '.config\ghostty\config.ghostty'
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $text = $text -replace '(?m)^background-blur = true', 'background-blur = false'
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'reload_config')
        Start-Sleep -Milliseconds 1500
        $sharp = & $measure 'noblur'
        if ($sharp.Spread -lt 20) { throw "without blur the stripes should stay sharp (spread $($sharp.Spread))" }
    } finally {
        $back.Close()
        $back.Dispose()
    }
}
