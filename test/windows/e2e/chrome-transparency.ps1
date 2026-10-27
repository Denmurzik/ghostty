# e2e: milestone=M3 timeout=400 order=636
# chrome-transparency (Task 15b): in a translucent window the title row and the
# tab row are the terminal background at the terminal's alpha, with no seam
# against the terminal. Over a magenta backdrop window (blur off, so the
# composed colour is known) a pixel of the empty left margin of the strip and a
# pixel just below the strip are both bg * a + magenta * (1 - a) within 3
# levels, at opacity 0.6 and 0.9, dark and light. The title text stays opaque
# (its ink reaches the ink colour). With the default blur (Acrylic) the two
# pixels still match each other within 3 levels, active and inactive.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_backdrop.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

function Get-Expected([int[]]$Bg, [double]$A) {
    $mag = 255, 0, 255
    , @(0..2 | ForEach-Object { [int][Math]::Round($Bg[$_] * $A + $mag[$_] * (1 - $A)) })
}

# The pixel settles for a moment after a layout or an animation: poll for a match.
function Get-SettledPixel([int[]]$Pt, [int[]]$Want, [int]$Tol) {
    $script:lastPx = $null
    [void](Wait-Until -TimeoutSec 4 -PollMs 250 -Condition {
        $script:lastPx = Get-ScreenPixel $Pt[0] $Pt[1]
        if (Test-ColorNear $script:lastPx $Want $Tol) { $true }
    })
    $script:lastPx
}

function Get-Strip($G) {
    (Get-GhosttyState -Class $G.Class).windows[0].strip
}

Invoke-E2eScenario 'chrome-transparency' {
    Assert-TransparencyEffects
    $dir = Get-EvidenceDir
    $back = New-BackdropForm 60 60 1500 1000
    try {
        Show-BackdropForm $back
        $cases = @(
            @{ Tag = 'dark-06'; Bg = (0x10, 0x20, 0x30); Fg = '#e0e0e0'; Theme = 'dark'; A = 0.6 },
            @{ Tag = 'dark-09'; Bg = (0x10, 0x20, 0x30); Fg = '#e0e0e0'; Theme = 'dark'; A = 0.9 },
            @{ Tag = 'light-06'; Bg = (0xf0, 0xf0, 0xf0); Fg = '#101010'; Theme = 'light'; A = 0.6 },
            @{ Tag = 'light-09'; Bg = (0xf0, 0xf0, 0xf0); Fg = '#101010'; Theme = 'light'; A = 0.9 }
        )
        foreach ($c in $cases) {
            $hex = '#{0:x2}{1:x2}{2:x2}' -f $c.Bg[0], $c.Bg[1], $c.Bg[2]
            $cfg = "background = $hex`nforeground = $($c.Fg)`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-theme = $($c.Theme)`nwindow-show-tab-bar = always`nbackground-opacity = $($c.A)`nbackground-blur = false`n"
            $g = Start-E2eGhostty -ConfigText $cfg
            try {
                if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "$($c.Tag): no frame dump" }
                Move-Window $g.Hwnd 160 160 1000 700
                [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
                [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
                Start-Sleep -Milliseconds 2500
                $st = Get-Strip $g
                $b = $st.bounds
                $want = Get-Expected $c.Bg $c.A
                # The empty left margin of the strip, and the terminal just below it.
                $above = Get-ClientScreenPoint $g.Hwnd ($st.tab_row[0] + 4) ($st.tab_row[3] - 3)
                $title = Get-ClientScreenPoint $g.Hwnd ($st.title_row[0] + 24) ([int](($st.title_row[1] + $st.title_row[3]) / 2))
                $below = Get-ClientScreenPoint $g.Hwnd ($b[0] + 40) ($b[3] + 6)
                $pa = Get-SettledPixel $above $want 3
                $pt = Get-SettledPixel $title $want 3
                $pb = Get-SettledPixel $below $want 3
                if ($dir) { (Get-ScreenBitmap 60 60 1500 1000).Save((Join-Path $dir "chrome-transparency-$($c.Tag)-active.png"), [Drawing.Imaging.ImageFormat]::Png) }
                Write-E2eInfo "$($c.Tag): want $($want -join ','), title row $(Format-Color $pt), tab row $(Format-Color $pa), terminal $(Format-Color $pb)"
                foreach ($p in @(@('title row', $pt), @('tab row', $pa), @('terminal', $pb))) {
                    if (-not (Test-ColorNear $p[1] $want 3)) { throw ("$($c.Tag) $($p[0]) is $(Format-Color $p[1]), expected $($want -join ',') +-3") }
                }
                # The title text stays opaque: some pixel of the title row reaches the ink.
                $tr = $st.title_text
                if ($tr) {
                    $bmp = Get-ScreenBitmap ((Get-ClientScreenPoint $g.Hwnd $tr[0] $tr[1])[0]) ((Get-ClientScreenPoint $g.Hwnd $tr[0] $tr[1])[1]) ([Math]::Max(1, $tr[2] - $tr[0])) ([Math]::Max(1, $tr[3] - $tr[1]))
                    $best = 0
                    for ($y = 0; $y -lt $bmp.Height; $y++) { for ($x = 0; $x -lt $bmp.Width; $x++) { $px = $bmp.GetPixel($x, $y); $l = 0.2126 * $px.R + 0.7152 * $px.G + 0.0722 * $px.B; $d = [Math]::Abs($l - (0.2126 * $want[0] + 0.7152 * $want[1] + 0.0722 * $want[2])); if ($d -gt $best) { $best = $d } } }
                    $bmp.Dispose()
                    if ($best -lt 60) { throw "$($c.Tag): the title text is not opaque (best contrast $best)" }
                }
                # Inactive: the same pixels (the row dims its text, not its colour).
                $away = Switch-AwayFromGhostty $g
                try {
                    $ia = Get-SettledPixel $above $want 3
                    $ib = Get-SettledPixel $below $want 3
                    if ($dir) { (Get-ScreenBitmap 60 60 1500 1000).Save((Join-Path $dir "chrome-transparency-$($c.Tag)-inactive.png"), [Drawing.Imaging.ImageFormat]::Png) }
                    if (-not (Test-ColorNear $ia $want 3) -or -not (Test-ColorNear $ib $want 3)) { throw "$($c.Tag) inactive: tab row $(Format-Color $ia), terminal $(Format-Color $ib), expected $($want -join ',')" }
                } finally { $away.Close() }
            } finally {
                if (-not $g.Process.HasExited) { $g.Process.Kill(); [void]$g.Process.WaitForExit(5000) }
            }
        }

        # Default blur (Acrylic): no seam, active and inactive.
        $g = Start-E2eGhostty -ConfigText "background = #102030`nforeground = #e0e0e0`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`nbackground-opacity = 0.6`n"
        try {
            if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw 'acrylic: no frame dump' }
            Move-Window $g.Hwnd 160 160 1000 700
            [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
            [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
            Start-Sleep -Milliseconds 2500
            $st = Get-Strip $g
            $b = $st.bounds
            $above = Get-ClientScreenPoint $g.Hwnd ($st.tab_row[0] + 4) ($st.tab_row[3] - 3)
            $below = Get-ClientScreenPoint $g.Hwnd ($b[0] + 40) ($b[3] + 6)
            $measure = {
                param($Tag)
                $pa = Get-ScreenPixel $above[0] $above[1]
                $pb = Get-ScreenPixel $below[0] $below[1]
                if ($dir) { (Get-ScreenBitmap 60 60 1500 1000).Save((Join-Path $dir "chrome-transparency-acrylic-$Tag.png"), [Drawing.Imaging.ImageFormat]::Png) }
                Write-E2eInfo "acrylic $Tag : strip $(Format-Color $pa), terminal $(Format-Color $pb)"
                if (-not (Test-ColorNear $pa @($pb.R, $pb.G, $pb.B) 3)) { throw "acrylic $Tag : seam between the strip $(Format-Color $pa) and the terminal $(Format-Color $pb)" }
            }
            & $measure 'active'
            $away = Switch-AwayFromGhostty $g
            try { & $measure 'inactive' } finally { $away.Close() }
        } finally {
            if (-not $g.Process.HasExited) { $g.Process.Kill(); [void]$g.Process.WaitForExit(5000) }
        }
    } finally {
        $back.Close()
        $back.Dispose()
    }
}
