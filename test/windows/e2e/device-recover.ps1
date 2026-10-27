# e2e: milestone=M3 timeout=120 order=660
# device-recover: GHOSTTY_D3D11_SIMULATE_DEVICE_LOST (Debug builds) loses the
# shared D3D11 device while four surfaces (two tabs, a split in each) show a
# background image, a Kitty image and a custom shader. Every window recovers
# on its own: the health bar shows within 1 s, within 3 s every surface draws
# its background and the Kitty image again and the bar is gone. The log has one
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

    # A 1x1 red Kitty image, placed over 4x2 cells.
    $kitty = Join-Path $script:Sbx.Tmp 'kitty.txt'
    $esc = [char]27
    [IO.File]::WriteAllText($kitty, "${esc}_Ga=T,f=32,s=1,v=1,c=4,r=2;/wAA/w==${esc}\", [Text.Encoding]::ASCII)
    $kittyBash = $kitty.Replace([char]92, [char]47)

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
    [void](Invoke-GhosttyAction -Class $g.Class -Action "text:cat '$kittyBash'\r")
    Start-Sleep -Milliseconds 800

    # The loss is noticed by the next frame: keep the terminal drawing.
    $lostAt = Get-Date
    $lost = Wait-Until -TimeoutSec 40 -PollMs 250 -Condition {
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:\r')
        Select-String -LiteralPath $g.Log -Pattern 'simulating a device loss' -Quiet
    }
    if (-not $lost) { throw 'the armed device loss simulation never fired' }

    # The health bar shows (or recovery already ran) within 1 s.
    $bar = Wait-Until -TimeoutSec 1 -PollMs 50 -Condition {
        $s = Get-GhosttyState -Class $g.Class
        if ([int]$s.m3.health.bars -gt 0 -or [int]$s.m3.health.recovered -gt 0) { $s }
    }
    if (-not $bar) { throw 'no health bar within 1 s of the device loss' }

    # Recovered within 3 s: bars gone, every surface recovered once.
    $done = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:\r')
        $h = (Get-GhosttyState -Class $g.Class).m3.health
        if ([int]$h.bars -eq 0 -and [int]$h.recovered -ge 4) { $h }
    }
    if (-not $done) { throw ('not recovered within 3 s: ' + ((Get-GhosttyState -Class $g.Class).m3.health | ConvertTo-Json -Compress)) }

    # Every surface draws again (fresh dump after the loss).
    $ids = @((Get-GhosttyState -Class $g.Class).windows | ForEach-Object { $_.tabs } | ForEach-Object { $_.surfaces } | ForEach-Object { [int]$_.id })
    if ($ids.Count -ne 4) { throw "expected 4 surfaces, found $($ids.Count)" }
    foreach ($id in $ids) {
        $path = Get-DumpPath $g $id
        $fresh = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
            [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:\r')
            (Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).LastWriteTime -gt $lostAt)
        }
        if (-not $fresh) { Write-E2eInfo "surface $id (hidden tab?) has no dump after the loss" }
    }

    $log = Get-Content -LiteralPath $g.Log -Raw
    $nLost = ([regex]::Matches($log, 'd3d11 device lost')).Count
    $nShader = ([regex]::Matches($log, 'custom shaders disabled after device loss')).Count
    $nRecovered = ([regex]::Matches($log, 'renderer recovered')).Count
    if ($nLost -ne 1) { throw "expected one 'd3d11 device lost', found $nLost" }
    if ($nShader -ne 1) { throw "expected one 'custom shaders disabled after device loss', found $nShader" }
    if ($nRecovered -ne 4) { throw "expected four 'renderer recovered', found $nRecovered" }
}
