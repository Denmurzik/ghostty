# e2e: milestone=M2 timeout=90 order=270
# config-reload: editing the config file and running `reload_config` applies
# the new background without a restart.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'config-reload' {
    $g = Start-E2eGhostty
    $ready = Wait-Dump $g { param($d) $d.Width -gt 100 -and $d.Height -gt 100 } 15
    if (-not $ready) { throw "no frame dump at $($g.Dump) within 15 s" }

    $px = Get-DumpPixel $ready ($ready.Width - 3) 2
    if (-not (Test-PixelNear $px (0x10, 0x20, 0x30) 2)) { throw "initial background is $(Format-Pixel $px), expected #102030" }

    # The sandbox config only: never the owner's.
    $path = Join-Path $script:Sbx.Home '.config\ghostty\config.ghostty'
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($text -notmatch '(?m)^background = #102030') { throw "sandbox config has no background line: $path" }
    $text = $text -replace '(?m)^background = #102030', 'background = #203040'
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))

    Invoke-GhosttyAction -Class $g.Class -Action 'reload_config' | Out-Null

    $d = Wait-Dump $g {
        param($d) Test-PixelNear (Get-DumpPixel $d ($d.Width - 3) 2) (0x20, 0x30, 0x40) 2
    } 15
    if (-not $d) {
        $last = Read-Dump $g.Dump
        throw "after reload_config the background is $(Format-Pixel (Get-DumpPixel $last ($last.Width - 3) 2)), expected #203040"
    }
    Write-E2eInfo 'reload_config applied background #203040'
}
