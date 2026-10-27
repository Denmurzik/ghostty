# e2e: milestone=M3 timeout=120 order=660
# device-recover: GHOSTTY_D3D11_SIMULATE_DEVICE_LOST (Debug builds) loses the
# shared D3D11 device while four surfaces (two tabs, a split in each) show a
# background image, a truecolor cell block and a custom shader. Every window recovers
# on its own: the health bar shows within 1 s, within 3 s every surface draws
# its background and the cell block again and the bar is gone. The log has one
# "device lost", one "custom shaders disabled after device loss" and four
# "renderer recovered". GHOSTTY_E2E_VARIANT=opacity adds background-opacity =
# 0.9 (composition chain handed off again; run in W6).
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')

Invoke-E2eScenario 'device-recover' {
    $variant = $env:GHOSTTY_E2E_VARIANT
    $smoke = Join-Path (Split-Path -Parent $PSScriptRoot) 'vt-smoke'
    $bgImage = (Join-Path $smoke 'cases\bg.png').Replace([char]92, [char]47)
    $shader = (Join-Path $smoke 'shaders\invert.glsl').Replace([char]92, [char]47)
    $extra = "background-image = $bgImage`ncustom-shader = $shader"
    if ($variant -eq 'opacity') { $extra += "`nbackground-opacity = 0.9" }
    $text = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8).TrimEnd() + "`n" + $extra + "`n"

    # A block of truecolor background cells (SGR 48;2, which ConPTY passes through) plus a line of text,
    # drawn at the top-left. Magenta-ish (200,40,120); the custom shader shows it inverted (55,215,135).
    $blockFile = Join-Path $script:Sbx.Tmp 'block.txt'
    $esc = [char]27
    [IO.File]::WriteAllText($blockFile, "${esc}[H${esc}[2J" + (("${esc}[48;2;200;40;120m" + (' ' * 16) + "${esc}[0m`n") * 3) + "recover-marker`n", [Text.Encoding]::ASCII)
    $blockBash = $blockFile.Replace([char]92, [char]47)

    $g = Start-E2eGhostty -ConfigText $text -Env @{ GHOSTTY_D3D11_SIMULATE_DEVICE_LOST = '25000' }
    $modeLine = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition {
        if (Test-Path -LiteralPath $g.Log) { Select-String -LiteralPath $g.Log -Pattern 'ghostty build optimize=(\S+)' | Select-Object -First 1 }
    }
    if (-not $modeLine) { throw 'no "ghostty build optimize=" line in the log' }
    if ($modeLine.Matches[0].Groups[1].Value -ine 'debug') { throw "E2E-SKIP: build optimize=$($modeLine.Matches[0].Groups[1].Value) does not simulate device loss" }
    Wait-BashReady $g

    # Two tabs with a split each: four surfaces.
    Invoke-SplitAction $g 'new_split:right'
    [void](Wait-SurfaceCount $g 2)
    Invoke-SplitAction $g 'new_tab'
    Start-Sleep -Milliseconds 800
    Invoke-SplitAction $g 'new_split:right'
    [void](Wait-SurfaceCount $g 2)
    Invoke-SplitAction $g 'goto_tab:1'
    Start-Sleep -Milliseconds 500

    # The first pixel near $Rgb in the top-left corner of a dump, or $null.
    function Find-Color($D, [int[]]$Rgb) {
        for ($y = 0; $y -lt [Math]::Min($D.Height, 160); $y += 2) {
            for ($x = 0; $x -lt [Math]::Min($D.Width, 320); $x += 2) {
                if (Test-PixelNear (Get-DumpPixel $D $x $y) $Rgb 12) { return "$x,$y" }
            }
        }
        $null
    }
    function Get-VisibleIds {
        @((Get-GhosttyState -Class $g.Class).windows | ForEach-Object { $_.tabs } | ForEach-Object { $_.surfaces } |
            Where-Object { $_.visible } | ForEach-Object { [int]$_.id })
    }

    # Before the loss: the visible surfaces show the inverted background image and the
    # inverted (55,215,135) cell block in one of them.
    $pre = @{}
    $blockBefore = $false
    # The first keystrokes after a tab switch can be lost: resend the cat until the block shows.
    $deadline = (Get-Date).AddSeconds(14)
    $sentAt = [datetime]::MinValue
    do {
        if (((Get-Date) - $sentAt).TotalSeconds -gt 3) {
            [void](Invoke-GhosttyAction -Class $g.Class -Action "text:cat '$blockBash'\r")
            $sentAt = Get-Date
            Start-Sleep -Milliseconds 900
        }
        $pre = @{}
        foreach ($id in (Get-VisibleIds)) {
            $d = Read-Dump (Get-DumpPath $g $id)
            if (-not $d) { throw "no dump of surface $id before the loss" }
            $pre[$id] = Get-DumpPixel $d ($d.Width - 40) ($d.Height - 40)
            if (Find-Color $d @(55, 215, 135)) { $blockBefore = $true }
        }
        if (-not $blockBefore) { Start-Sleep -Milliseconds 300 }
    } until ($blockBefore -or (Get-Date) -gt $deadline)
    if ($pre.Count -eq 0) { throw 'no visible surface before the loss' }
    if (Select-String -LiteralPath $g.Log -Pattern 'simulating a device loss' -Quiet) { throw 'the device loss fired before the pre-loss check (setup too slow)' }
    if (-not $blockBefore) { throw 'the truecolor cell block (inverted) is not on screen before the loss' }
    # The loss is noticed by the next frame: keep the terminal drawing (a letter, not Enter: the block must not scroll away).
    $lostAt = Get-Date
    $lost = Wait-Until -TimeoutSec 40 -PollMs 250 -Condition {
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:a')
        Select-String -LiteralPath $g.Log -Pattern 'simulating a device loss' -Quiet
    }
    if (-not $lost) { throw 'the armed device loss simulation never fired' }

    # The health bar shows (or recovery already ran) within 1 s.
    $bar = Wait-Until -TimeoutSec 1 -PollMs 50 -Condition {
        $s = Get-GhosttyState -Class $g.Class
        if ([int]$s.m3.health.bars -gt 0) { $s }
    }
    if (-not $bar) { throw 'no health bar within 1 s of the device loss' }

    # Recovered within 3 s: every surface recovered once and the bars of the visible
    # surfaces are gone. The surfaces of the hidden tab draw no frame, so their bar
    # clears once that tab is shown.
    $hiddenN = @((Get-GhosttyState -Class $g.Class).windows | ForEach-Object { $_.tabs } | ForEach-Object { $_.surfaces } |
        Where-Object { -not $_.visible }).Count
    $done = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:a')
        $h = (Get-GhosttyState -Class $g.Class).m3.health
        if ([int]$h.bars -le $hiddenN -and [int]$h.recovered -ge 4) { $h }
    }
    if (-not $done) { throw ('not recovered within 3 s: ' + ((Get-GhosttyState -Class $g.Class).m3.health | ConvertTo-Json -Compress)) }
    Invoke-SplitAction $g 'goto_tab:2'
    $clear = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:a')
        if ([int](Get-GhosttyState -Class $g.Class).m3.health.bars -eq 0) { $true }
    }
    if (-not $clear) { throw ('health bars remain after the second tab was shown: ' + ((Get-GhosttyState -Class $g.Class).m3.health | ConvertTo-Json -Compress)) }
    Invoke-SplitAction $g 'goto_tab:1'
    Start-Sleep -Milliseconds 500

    # Every visible surface draws again: a fresh dump with the background image (the
    # custom shader is off now, so the inverse of the earlier pixel) and the plain cell block.
    $blockAfter = $false
    foreach ($id in $pre.Keys) {
        $path = Get-DumpPath $g $id
        $fresh = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
            [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:a')
            (Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).LastWriteTime -gt $lostAt)
        }
        if (-not $fresh) { throw "visible surface $id has no fresh dump after the loss" }
        $d = Read-Dump $path
        # The shader is off now: the image pixel is dark again (it was inverted before),
        # and it is the image, not the plain background (#102030) of a lost image.
        $px = Get-DumpPixel $d ($d.Width - 40) ($d.Height - 40)
        $lumPre = $pre[$id].R + $pre[$id].G + $pre[$id].B
        $lumPost = $px.R + $px.G + $px.B
        if (Test-PixelNear $px @(16, 32, 48) 6) { throw ("surface {0}: the background image is gone after the recovery ({1})" -f $id, (Format-Pixel $px)) }
        if ($lumPost -ge $lumPre) { throw ("surface {0}: still inverted after the recovery: before {1}, after {2}" -f $id, (Format-Pixel $pre[$id]), (Format-Pixel $px)) }
        if (Find-Color $d @(200, 40, 120)) { $blockAfter = $true }
    }
    if (-not $blockAfter) { throw 'the truecolor cell block (200,40,120) is not on screen after the recovery' }
    $log = Get-Content -LiteralPath $g.Log -Raw
    $nLost = ([regex]::Matches($log, 'd3d11 device lost')).Count
    $nShader = ([regex]::Matches($log, 'custom shaders disabled after device loss')).Count
    $nRecovered = ([regex]::Matches($log, 'renderer recovered')).Count
    if ($nLost -ne 1) { throw "expected one 'd3d11 device lost', found $nLost" }
    if ($nShader -ne 1) { throw "expected one 'custom shaders disabled after device loss', found $nShader" }
    if ($nRecovered -ne 4) { throw "expected four 'renderer recovered', found $nRecovered" }
}

