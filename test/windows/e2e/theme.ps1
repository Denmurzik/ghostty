# e2e: milestone=M2 timeout=120 order=260
# theme: `theme = light:...,dark:...` follows the system colour scheme, which
# is simulated through the test-only `color-scheme` IPC op (the owner's real
# theme is never touched), and the frame's immersive dark mode follows it.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.Dwm' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Dwm -MemberDefinition @"
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);
"@
}

function Set-Scheme($G, [string]$Scheme) {
    $r = Invoke-GhosttyIpc -Class $G.Class -Request @{ op = 'color-scheme'; scheme = $Scheme }
    if ($r.code -ne 0) { throw "color-scheme $Scheme answered code $($r.code): $($r.stderr)" }
}

function Test-DarkFrame($G) {
    $v = 0
    $hr = [GhosttyE2e.Dwm]::DwmGetWindowAttribute($G.Hwnd, 20, [ref]$v, 4)
    if ($hr -ne 0) { throw "DwmGetWindowAttribute failed: 0x$('{0:x}' -f $hr)" }
    $v -ne 0
}

function Wait-Background($G, [int[]]$Rgb, [string]$What) {
    $d = Wait-Dump $G {
        param($d)
        $d.Width -gt 100 -and (Test-PixelNear (Get-DumpPixel $d ($d.Width - 3) 2) $Rgb 2)
    } 15
    if (-not $d) {
        $last = Read-Dump $G.Dump
        throw "$What : dump corner is $(Format-Pixel (Get-DumpPixel $last ($last.Width - 3) 2)), expected #{0:x2}{1:x2}{2:x2}" -f $Rgb[0], $Rgb[1], $Rgb[2]
    }
}

Invoke-E2eScenario 'theme' {
    $dir = Join-Path $script:Sbx.Home '.config\ghostty'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $utf8 = New-Object Text.UTF8Encoding $false
    $light = Join-Path $dir 'gt-light'
    $dark = Join-Path $dir 'gt-dark'
    [IO.File]::WriteAllText($light, "background = #f0f0f0`nforeground = #101010`n", $utf8)
    [IO.File]::WriteAllText($dark, "background = #101010`nforeground = #e0e0e0`n", $utf8)
    $l = $light.Replace('\', '/')
    $d = $dark.Replace('\', '/')

    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`ntheme = light:$l,dark:$d`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }

    Set-Scheme $g 'light'
    Wait-Background $g (0xf0, 0xf0, 0xf0) 'scheme light'
    if (Test-DarkFrame $g) { throw 'light scheme: the frame is in immersive dark mode' }

    Set-Scheme $g 'dark'
    Wait-Background $g (0x10, 0x10, 0x10) 'scheme dark'
    if (-not (Test-DarkFrame $g)) { throw 'dark scheme: the frame is not in immersive dark mode' }

    Set-Scheme $g 'light'
    Wait-Background $g (0xf0, 0xf0, 0xf0) 'scheme light again'
    if (Test-DarkFrame $g) { throw 'light scheme again: the frame is in immersive dark mode' }
    Write-E2eInfo 'light/dark theme and frame dark mode follow the simulated colour scheme'
}
