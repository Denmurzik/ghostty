# e2e: milestone=M3 timeout=300 order=630
# transparency: background-opacity = 0.5 over a magenta backdrop window of our
# own, terminal background #102030. The screen-rect capture of an empty cell
# is the 50% blend (135, 16, 151) +-12 (the renderer premultiplies in linear
# space, DWM blends in sRGB: up to ~9 levels off, see the report) and the frame
# dump alpha is ~128
# (premultiplied composition chain), also while the window is inactive;
# toggle_background_opacity makes the same pixel the solid background; a
# reload with background-opacity = 1 shows the solid background (the window
# keeps its composition chain, backdrop `opaque`) and a reload back to 0.5
# translucent again. A window created opaque stays opaque on a reload to a
# translucent config (solid, restart required like macOS; its surfaces still
# switch to composition and back), while a window
# created afterwards is translucent.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_backdrop.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

function Get-Comp($G) {
    (Get-GhosttyState -Class $G.Class).m3.composition
}

function Set-Opacity($G, [string]$Value) {
    $path = Join-Path $script:Sbx.Home '.config\ghostty\config.ghostty'
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $text = $text -replace '(?m)^background-opacity = .*$', "background-opacity = $Value"
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
    [void](Invoke-GhosttyAction -Class $G.Class -Action 'reload_config')
}

Invoke-E2eScenario 'transparency' {
    Assert-TransparencyEffects
    $dir = Get-EvidenceDir
    $shot = {
        param($Tag)
        if ($dir) { (Get-ScreenBitmap 60 60 1500 1000).Save((Join-Path $dir "transparency-$Tag-screen.png"), [Drawing.Imaging.ImageFormat]::Png) }
    }
    $translucent = 135, 16, 151
    $solid = 16, 32, 48
    $cfg = "background = #102030`nforeground = #e0e0e0`nconfirm-close-surface = false`nwindow-decoration = client`nbackground-blur = false`n"

    $back = New-BackdropForm 60 60 1500 1000
    try {
        Show-BackdropForm $back
        $g = Start-E2eGhostty -ConfigText ($cfg + "background-opacity = 0.5`n")
        if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
        Move-Window $g.Hwnd 160 160 1000 700
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        Start-Sleep -Milliseconds 800

        $comp = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition {
            $c = Get-Comp $g
            if ($c.mode -eq 'composition' -and @(@($c.windows)[0].surfaces)[0].attached -ge 1) { $c }
        }
        if (-not $comp) { throw "no composition chain attached: $((Get-Comp $g) | ConvertTo-Json -Depth 6 -Compress)" }
        $w = @($comp.windows)[0]
        if ($w.backdrop -ne 'transparent') { throw "backdrop is $($w.backdrop), expected transparent" }

        $cs = Get-ClientSize $g.Hwnd
        $pt = Get-ClientScreenPoint $g.Hwnd ($cs.Width - 80) ($cs.Height - 80)
        $sample = { Get-ScreenPixel $pt[0] $pt[1] }
        function Check([string]$What, [int[]]$Want, [int]$Tol) {
            # DWM and the desktop settle for a moment after a change.
            $c = $null
            $ok = Wait-Until -TimeoutSec 4 -PollMs 200 -Condition {
                $script:lastC = & $sample
                if (Test-ColorNear $script:lastC $Want $Tol) { $true }
            }
            if (-not $ok) { throw ("$What : empty cell is $(Format-Color $script:lastC), expected ~#{0:x2}{1:x2}{2:x2}" -f $Want[0], $Want[1], $Want[2]) }
            $script:lastC
        }

        $c1 = Check 'translucent' $translucent 12
        & $shot 'translucent'
        $d = Read-Dump $g.Dump
        $p = Get-DumpPixel $d ($d.Width - 80) ($d.Height - 80)
        if ([Math]::Abs($p.A - 128) -gt 8) { throw "dump alpha is $($p.A), expected ~128" }

        # Inactive: another window of ours has the foreground.
        $away = Switch-AwayFromGhostty $g
        try {
            $c2 = Check 'inactive' $translucent 12
            & $shot 'inactive'
        } finally { $away.Close() }

        # Toggle: the solid background.
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        if (-not (Invoke-GhosttyAction -Class $g.Class -Action 'toggle_background_opacity')) { throw 'toggle_background_opacity was not performed' }
        Start-Sleep -Milliseconds 700
        $c3 = Check 'toggled' $solid 12
        & $shot 'toggled'
        if (-not @((Get-Comp $g).windows)[0].toggled_opaque) { throw 'state does not show toggled_opaque' }

        # And back.
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_background_opacity')
        Start-Sleep -Milliseconds 700
        $c4 = Check 'toggled back' $translucent 12

        # Reload with opacity 1: solid, the window keeps its chain.
        Set-Opacity $g '1'
        $c = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition {
            $c = Get-Comp $g
            if (@($c.windows)[0].backdrop -eq 'opaque') { $c }
        }
        if (-not $c) { throw "after background-opacity = 1 the backdrop is not opaque: $((Get-Comp $g) | ConvertTo-Json -Depth 6 -Compress)" }
        Start-Sleep -Milliseconds 700
        $c5 = Check 'opacity 1' $solid 12
        & $shot 'opacity-1'

        # And translucent again, without a restart.
        Set-Opacity $g '0.5'
        $c = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition {
            $c = Get-Comp $g
            if (@($c.windows)[0].backdrop -eq 'transparent') { $c }
        }
        if (-not $c) { throw "after background-opacity = 0.5 the backdrop is not transparent: $((Get-Comp $g) | ConvertTo-Json -Depth 6 -Compress)" }
        Start-Sleep -Milliseconds 700
        $c6 = Check 'translucent again' $translucent 12
        & $shot 'translucent-again'
        Write-E2eInfo "translucent $(Format-Color $c1), inactive $(Format-Color $c2), toggled $(Format-Color $c3), back $(Format-Color $c4), opacity 1 $(Format-Color $c5), again $(Format-Color $c6)"

        # A window created opaque stays opaque; a window created later is translucent.
        $g.Process.Kill()
        [void]$g.Process.WaitForExit(5000)
        $g2 = Start-E2eGhostty -ConfigText ($cfg + "background-opacity = 1`n")
        if (-not (Wait-Dump $g2 { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g2.Dump)" }
        Move-Window $g2.Hwnd 160 160 1000 700
        [void](Set-ForegroundSafe -Hwnd $g2.Hwnd)
        Start-Sleep -Milliseconds 800
        Set-Opacity $g2 '0.5'
        Start-Sleep -Milliseconds 1200
        $w = @((Get-Comp $g2).windows)[0]
        if ($w.glass -or $w.surfaces[0].mode -ne 'composition') { throw "a window created opaque did not follow the config: $((Get-Comp $g2) | ConvertTo-Json -Depth 6 -Compress)" }
        $cs = Get-ClientSize $g2.Hwnd
        $pt = Get-ClientScreenPoint $g2.Hwnd ($cs.Width - 80) ($cs.Height - 80)
        $c7 = Check 'created opaque, reloaded 0.5' $solid 12
        Set-Opacity $g2 '1'
        $back1 = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition {
            $c = Get-Comp $g2
            if (@(@($c.windows)[0].surfaces)[0].mode -eq 'hwnd') { $c }
        }
        if (-not $back1) { throw "a window created opaque did not return to hwnd mode: $((Get-Comp $g2) | ConvertTo-Json -Depth 6 -Compress)" }
        Start-Sleep -Milliseconds 700
        $c8 = Check 'created opaque, back to opacity 1' $solid 6

        Set-Opacity $g2 '0.5'
        Start-Sleep -Milliseconds 800
        [void](Invoke-GhosttyAction -Class $g2.Class -Action 'new_window')
        $two = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition {
            $c = Get-Comp $g2
            if (@($c.windows).Count -eq 2) { $c }
        }
        if (-not $two) { throw 'the second window did not open' }
        $nw = @($two.windows | Where-Object { $_.glass })
        if ($nw.Count -ne 1 -or $nw[0].surfaces[0].mode -ne 'composition') { throw "the new window is not translucent: $($two | ConvertTo-Json -Depth 6 -Compress)" }
        Write-E2eInfo "window created opaque stays solid ($(Format-Color $c7), back to hwnd $(Format-Color $c8)); the new window is translucent (glass, composition)"
    } finally {
        $back.Close()
        $back.Dispose()
    }
}
