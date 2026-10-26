# e2e: milestone=M2 timeout=90 order=480
# device-lost: GHOSTTY_D3D11_SIMULATE_DEVICE_LOST (Debug builds) marks the
# shared D3D11 device lost a while after start. The log reports it once; a
# window opened afterwards gets a fresh device and shows the background.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'device-lost' {
    $bg = 0x10, 0x20, 0x30
    $g = Start-E2eGhostty -Env @{ GHOSTTY_D3D11_SIMULATE_DEVICE_LOST = '3000' }

    # Only Debug builds simulate the loss; the startup line names the mode.
    $modeLine = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition {
        if (Test-Path -LiteralPath $g.Log) { Select-String -LiteralPath $g.Log -Pattern 'ghostty build optimize=(\S+)' | Select-Object -First 1 }
    }
    if (-not $modeLine) { throw 'no "ghostty build optimize=" line in the log' }
    $mode = $modeLine.Matches[0].Groups[1].Value
    if ($mode -ine 'debug') { throw "E2E-SKIP: build optimize=$mode does not simulate device loss" }
    $armed = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition {
        Select-String -LiteralPath $g.Log -Pattern 'device loss simulation armed' -Quiet
    }
    if (-not $armed) { throw 'Debug build did not arm the device loss simulation' }
    $lost = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition {
        # The loss is noticed by the next frame; an idle terminal draws none, so keep it drawing.
        [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:\r')
        Select-String -LiteralPath $g.Log -Pattern 'simulating a device loss' -Quiet
    }
    if (-not $lost) { throw 'the armed device loss simulation never fired' }

    $r = Invoke-GhosttyIpc -Class $g.Class -Request @{ v = 1; op = 'new-window'; args = @() }
    if ($r.PSObject.Properties['code'] -and $r.code -ne 0) { throw "new-window failed: $($r.stderr)" }
    $second = Wait-Until -TimeoutSec 10 -PollMs 100 -Condition {
        @(Find-GhosttyWindows $g.Pid | Where-Object { $_ -ne $g.Hwnd }) | Select-Object -First 1
    }
    if (-not $second) { throw 'the window opened after the device loss never appeared' }

    $fresh = [pscustomobject]@{ Dump = (Get-DumpPath $g 2) }
    $d = Wait-Dump $fresh { param($d) $d.Width -gt 100 -and $d.Height -gt 100 } 15
    if (-not $d) { throw "no frame dump of the new window at $($fresh.Dump)" }
    $px = Get-DumpPixel $d ($d.Width - 3) ($d.Height - 3)
    if (-not (Test-PixelNear $px $bg 2)) { throw ("new window pixel is {0}, expected background #102030" -f (Format-Pixel $px)) }

    $count = @(Select-String -LiteralPath $g.Log -Pattern 'd3d11 device lost').Count
    if ($count -ne 1) { throw "expected one 'd3d11 device lost' log line, found $count" }
    if (-not (Select-String -LiteralPath $g.Log -Pattern 'created after a device loss' -Quiet)) { throw 'no fresh device was created after the loss' }
}
